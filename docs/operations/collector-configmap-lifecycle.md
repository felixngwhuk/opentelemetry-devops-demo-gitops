# Collector ConfigMap lifecycle with Argo CD RollingSync

This runbook describes the P1-04A pruning policy for the namespace-local OpenTelemetry Collector in dev, staging, and prod. The policy change enables pruning for each generated Application during a RollingSync operation. It does not narrow pruning to ConfigMaps; review the full deletion set before any live test.

## How the rollout works

The base Kustomization reads `otel-collector-relay.yaml` through `configMapGenerator`. Kustomize adds a content hash to the generated `otel-collector` ConfigMap name and rewrites the Collector Deployment's ConfigMap volume reference to that name.

When relay content changes, Kustomize renders a new ConfigMap name. The rewritten volume reference changes the Deployment Pod template, so Kubernetes creates a new ReplicaSet and rolls out Collector Pods using the new ConfigMap. The previous generated ConfigMap is no longer in the desired manifests. Argo CD must prune it after the replacement is ready; otherwise it remains live and can keep the Application OutOfSync.

## Why the ApplicationSet policy works on Argo CD v3.4.4

The ApplicationSet template sets `automated.prune: true` and `automated.selfHeal: true`, and leaves `automated.enabled` absent. In Argo CD v3.4.4, `IsAutomatedSyncEnabled()` returns true when `automated` exists and `enabled` is nil or true. For RollingSync, `syncDesiredApplications` reads `automated.prune`, then forces `automated.enabled` false on the generated Application so the ApplicationSet controller, rather than independent per-Application auto-sync, controls the rollout. The `selfHeal` field remains in the generated policy, but with `enabled` false it does not start independent self-healing syncs. `syncApplication` writes the prune value into the sync operation and copies the Application's `syncOptions` into the operation. This is why the template must not set `automated.enabled: false`.

The template also sets `PruneLast=true`. Argo CD v3.4.4 passes this sync option into the RollingSync operation; it schedules pruning as the final implicit wave after other resources have been deployed and become healthy. The root Application's separate auto-sync policy remains unchanged.

Pinned source references:

- [ApplicationSet controller: RollingSync prune handling and operation construction](https://github.com/argoproj/argo-cd/blob/v3.4.4/applicationset/controllers/applicationset_controller.go#L1471-L1526)
- [Application sync-policy defaults and `IsAutomatedSyncEnabled`](https://github.com/argoproj/argo-cd/blob/v3.4.4/pkg/apis/application/v1alpha1/types.go#L1373-L1391)
- [Argo CD v3.4.4 `PruneLast` behavior](https://github.com/argoproj/argo-cd/blob/v3.4.4/docs/user-guide/sync-options.md#prune-last)

## Pruning risks

`automated.prune: true` applies to all resources tracked by each generated Application, not only the Collector ConfigMap. Any tracked resource removed from that environment's desired manifests can be deleted during a successful sync. `PruneLast=true` delays those deletions until the final sync wave, but it does not make an unexpected deletion safe. Namespaces, persistent data resources, and other long-lived objects need particular care.

Before a live pruning test, inspect every resource Argo CD proposes to prune. Stop if the set includes anything beyond the previously managed, obsolete Collector ConfigMaps expected for that test. Do not use a blanket sync or manually delete a ConfigMap as a substitute for reviewing the operation. Check that no active or terminating Collector Pod still references an obsolete ConfigMap before considering any manual recovery action.

## Static checks

Run the local regression tests from the repository root:

```bash
bash tests/phase1/test_collector_configmap.sh
bash tests/phase1/test_release_selection.sh
```

The Collector test renders the base and dev, staging, and prod overlays. It checks the ApplicationSet RollingSync environments and policy, confirms that the root Application policy remains separate, verifies the generated ConfigMap and Deployment reference, rejects the old fixed-name ConfigMap in desired renders, and edits relay content in a temporary fixture to confirm that the hash and reference change together.

These checks validate manifests and Kustomize output only. They do not prove that a live ApplicationSet controller created a sync operation with pruning enabled, that the live cluster pruned the old ConfigMap, or that Collector Pods started successfully.

## Live verification after approval

Run Kubernetes checks through the approved bastion, not local Kubernetes. First record the baseline and inspect all resources in Argo CD's proposed deletion set:

```bash
kubectl -n argocd get applicationset opentelemetry-demo

kubectl -n argocd get applications \
  opentelemetry-demo-dev \
  opentelemetry-demo-staging \
  opentelemetry-demo-prod

for env in dev staging prod; do
  ns="otel-demo-$env"
  kubectl -n "$ns" get configmaps | grep otel-collector
  kubectl -n "$ns" get deployment otel-collector
done
```

After the policy change has been approved and merged:

1. Check each generated Application. Independent auto-sync should be disabled by the ApplicationSet controller, while the generated policy retains `prune: true` and `PruneLast=true`.
2. In a separate approved Git change, add a harmless YAML comment to the relay file. Do not change the Collector's functional configuration in the policy change. Preview each environment's diff and enumerate every proposed prune before merging the test change.
3. Confirm adequate Pod capacity and memory for a rolling Collector restart. Monitor the Applications, Deployments, ReplicaSets, Pods, and Collector startup logs.
4. Search ApplicationSet controller logs for `triggering sync for application: ... prune enabled: true`. Inspect each recorded Application sync operation and confirm its `sync.prune` value is true and its sync options include `PruneLast=true`.
5. Verify that the new hashed ConfigMap exists, the Deployment references it, replacement Collector Pods become Ready, and obsolete generated ConfigMaps are removed only after the new resources are healthy.
6. Confirm all three Applications return to Synced and Healthy. Record the actual execution order and timestamps.

The manifest defines dev, staging, and prod RollingSync steps with `maxUpdate: 1`, but the known RollingSync environment-order race is accepted for this portfolio project. Do not assume the observed execution order is strictly serialized; record what actually happened and stop if an unexpected environment starts or an unexpected resource is proposed for pruning.

## Troubleshooting

- If an Application remains OutOfSync, inspect its diff and identify every extra or missing resource before retrying a sync.
- If an old ConfigMap remains, inspect the recorded operation's `sync.prune`, the `PruneLast=true` sync option, and the ApplicationSet controller log. Do not delete it while an active or terminating Pod may still mount it.
- If the new Collector Deployment does not become Healthy, stop further rollout changes and inspect Pod events and startup logs before proceeding to another environment.
- If the controller reports `prune enabled: false`, verify that the ApplicationSet template contains `automated.prune: true` and does not explicitly set `automated.enabled: false`.
- Static Kustomize rendering cannot diagnose controller permissions or prove live pruning. Use the bastion and Argo CD operation status for those checks.

## Rollback

If pruning or rollout behavior is unexpected, stop further rollout changes and inspect Application and controller status through the bastion. Revert the P1-04A policy change in Git after reviewing the effects. A sync operation that has already started may continue after a Git revert; inspect and safely terminate it through the approved Argo CD workflow before assuming the revert stopped it.

If pruning removed a resource needed by a running workload, restore it from a reviewed, known-good Git revision and verify the Collector Deployment and Application health. Reverting the policy change alone does not restore deleted resources or data. Do not manually delete a Collector ConfigMap that an active Pod still references. Keep the P1-04A policy change as a separate rollback unit from P1-04.
