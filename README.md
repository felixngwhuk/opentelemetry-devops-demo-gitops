# opentelemetry-devops-demo-gitops

GitOps repository for deploying the OpenTelemetry demo application to an AWS EKS cluster with Argo CD and Kustomize.

This repository is the CD side of a three-repository setup:

- **Infra** – AWS networking, EKS, and cluster bootstrap  
  <https://github.com/felixngwhuk/opentelemetry-devops-demo-infra>
- **Web app** – application source code and container image build logic  
  <https://github.com/felixngwhuk/opentelemetry-devops-demo>
- **GitOps** – Argo CD application definitions and deployment manifests  
  <https://github.com/felixngwhuk/opentelemetry-devops-demo-gitops>

## Skills demonstrated by this repository

This repository mainly demonstrates:

- GitOps deployment flow with Argo CD
- Kustomize base and overlay design
- multi-environment Kubernetes manifest management
- separation of CI image build from CD deployment intent
- ingress and domain-based routing with Traefik
- platform-aware handling of TLS termination and forwarded headers
- namespace and cluster-scope RBAC design
- declarative rollback path through Git history

## What I implemented in this GitOps project

From the current repository contents and commit history, the main changes are:

1. **Added a bootstrap entry point**  
   Introduced a root Argo CD application so the repository can manage itself through the app-of-apps pattern.

2. **Introduced Argo CD application definitions as code**  
   Added Argo CD `Application` and `ApplicationSet` manifests instead of relying on manual setup in the UI.

3. **Structured the repository by responsibility**  
   Split manifests into `bootstrap/`, `argocd/`, `apps/`, and `cluster/` so cluster-scoped, application-scoped, and bootstrap resources are easier to reason about.

4. **Added multi-environment Kustomize overlays**  
   Created `dev`, `staging`, and `prod` overlays to separate environment-specific changes from the shared base.

5. **Changed image sources to GHCR-hosted project images**  
   The overlays pin images under `ghcr.io/felixngwhuk/opentelemetry-devops-demo/...`, which makes this repository the deployment handoff point for images built by the web app repository.

6. **Added environment-specific ingress host routing**  
   Each overlay patches the Traefik host rule to route traffic by domain name.

7. **Adjusted browser telemetry export configuration**  
   The frontend trace export endpoint is patched per environment to use a public hostname rather than localhost.

7. **Exposed Argo CD through the same ingress layer**  
   Added a separate application for internet-facing Argo CD access through Traefik.

8. **Separated cluster-level collector RBAC from namespaced workloads**  
   Added a dedicated cluster-scoped RBAC folder and patched bindings per environment.

## What this repository is responsible for

This repository stores the desired Kubernetes state for the demo environments.

The main idea is to keep **build** and **deployment** concerns separate:

- the **web app** repository builds and publishes container images
- the **gitops** repository records which image tags should run in each environment
- **Argo CD** watches this repository and applies the declared state to the EKS cluster

I chose this split so that a deployment is driven by a Git change rather than by a CI job pushing directly into the cluster. For a portfolio project, that makes the deployment path easier to inspect and reason about.

## Deployment model

The applications are deployed to an EKS cluster provisioned by the infrastructure project.

Traffic flow is:

`User -> Route 53 -> AWS load balancer -> Traefik -> application service`

TLS certificates are issued by **AWS ACM**. TLS is terminated on the AWS load balancer, and traffic is then forwarded to Traefik over HTTP inside the platform boundary. Traefik applies host-based routing and sends the request to the correct Kubernetes service.

Example hostnames used by the overlays:

- `dev.devopsbyfelix.shop`
- `staging.devopsbyfelix.shop`
- `www.devopsbyfelix.shop`
- `argocd.devopsbyfelix.shop`

## Why Argo CD and Kustomize

### Argo CD

Argo CD is used as the deployment controller because it continuously compares the cluster state with what is stored in Git.

That fits this project for two reasons:

1. it keeps the deployment workflow declarative
2. it gives a clear handoff point from CI to CD

This repository uses automated sync with:

- `prune: true` to remove objects that no longer exist in Git
- `selfHeal: true` to restore drift when live state differs from the declared state

### Kustomize

Kustomize is used to keep one base application definition and apply environment-specific changes through overlays.

I chose Kustomize here because the differences between environments are mostly patch-based:

- namespace
- image tags
- hostnames
- frontend OTLP endpoint
- resource requests and limits
- replica count
- cluster role binding namespace override

For this shape of problem, Kustomize keeps the environment changes readable without needing a Helm values hierarchy.

## Repository structure

```text
bootstrap/
  root-application.yaml          # app-of-apps entry point

argocd/
  *.yaml                         # Argo CD Application and ApplicationSet definitions

apps/
  opentelemetry-demo/
    base/                        # shared application manifests
    overlays/
      dev/
      staging/
      prod/
  argocd-internet-facing/        # ingress resources for exposing Argo CD

cluster/
  otel-collector-rbac/           # cluster-scoped RBAC shared by app environments
```

## How the GitOps bootstrap works

The starting point is `bootstrap/root-application.yaml`.

This follows the app-of-apps pattern:

1. apply one Argo CD `Application`
2. Argo CD then reads the `argocd/` directory in this repository
3. that directory defines the child applications and ApplicationSet
4. Argo CD reconciles the application resources under `apps/` and `cluster/`

I used this pattern so the cluster only needs a small initial bootstrap action. After that, the rest of the deployment configuration is managed from Git.

## Environment layout

### Base

`apps/opentelemetry-demo/base/` contains the shared Kubernetes manifests for the application.

This includes:

- the main OpenTelemetry demo manifest
- a base `ClusterRoleBinding` for the collector service account

The base keeps the common application definition in one place and avoids repeating the generated manifests across environments.

### Overlays

Each environment overlay adjusts the base for a specific target:

- `dev`
- `staging`
- `prod`

The overlays currently define:

- a dedicated namespace per environment
- image tags per service using the `images:` transformer
- frontend replica count and resource settings
- environment-specific Traefik host rules
- environment-specific browser trace export endpoint
- a patched collector `ClusterRoleBinding` pointing to the correct namespace
- an application version label added through a JSON patch

## GitOps handoff from the web app repository

The build and release handoff happens through image tags.

The **web app** repository builds and publishes images to GHCR, for example:

- `ghcr.io/felixngwhuk/opentelemetry-devops-demo/frontend`
- `ghcr.io/felixngwhuk/opentelemetry-devops-demo/checkout`
- `ghcr.io/felixngwhuk/opentelemetry-devops-demo/payment`

This repository then decides which tag each environment should run.

For example, the `dev` overlay currently pins services to a tag such as `dev-62ee39e`.

I chose this approach so that:

- image creation stays in the application repository
- deployment intent stays in the GitOps repository
- environment promotion can be reviewed as a Git change

## ApplicationSet usage

`argocd/opentelemetry-demo-applicationset.yaml` uses an Argo CD `ApplicationSet` with a list generator.

That gives one template for multiple environments while still letting each environment point to its own overlay path and namespace.

I used an `ApplicationSet` here because it keeps the environment application definitions consistent and reduces repetition compared with writing a separate Argo CD `Application` per environment.

## Ordering and safety choices

Several small Argo CD choices in this repository are there to make reconciliation more predictable:

- **sync waves** are used so supporting resources are applied before dependent applications
- **finalizers** are added so Argo CD can clean up managed resources on deletion
- **CreateNamespace=true** is enabled for the environment applications so namespace creation stays in the same workflow
- **cluster-scoped RBAC** is separated from namespaced application resources so the collector permissions can be managed explicitly

## Internet-facing Argo CD access

This repository also includes `apps/argocd-internet-facing/`.

That application publishes Argo CD through Traefik using:

- an `IngressRoute` for `argocd.devopsbyfelix.shop`
- a middleware that adds forwarded HTTPS headers

I added the forwarded header middleware so Argo CD can sit behind a TLS-terminating AWS load balancer while still receiving the headers it expects from an HTTPS-facing route.

## Cluster-scoped RBAC for the collector

`cluster/otel-collector-rbac/` defines the collector `ClusterRole` separately from the application overlays.

The overlays then patch the `ClusterRoleBinding` so each environment binds the collector service account in the correct namespace.

I split the role and binding this way because the **role** is cluster-scoped and reusable, while the **binding target** changes by environment.

## Local review commands

Render an environment locally before applying changes:

```bash
kubectl kustomize apps/opentelemetry-demo/overlays/dev
kubectl kustomize apps/opentelemetry-demo/overlays/staging
kubectl kustomize apps/opentelemetry-demo/overlays/prod
```

Apply the bootstrap application once Argo CD is installed:

```bash
kubectl apply -n argocd -f bootstrap/root-application.yaml
```

## Demo compromises vs production

### 1) Only the dev environment is active in the ApplicationSet

- **What is simplified:** staging and prod overlays exist, but only dev is currently generated by Argo CD
- **Why:** keeps the demo cheaper and easier to operate while still showing the promotion structure
- **Risk introduced:** the full promotion path is defined but not exercised continuously
- **Production version:** all required environments would be active, with promotion rules and release controls applied consistently

### 2) Environment scaling and resource tuning are minimal

- **What is simplified:** only the frontend deployment has explicit replica and resource patches in the overlays
- **Why:** keeps the demo readable and avoids spending time tuning every service in a non-production workload
- **Risk introduced:** resource behaviour for the rest of the stack is less controlled than it would be in a real service platform
- **Production version:** resource requests, limits, autoscaling, disruption budgets, and workload-specific tuning would be defined more broadly

### 3) TLS is terminated before Traefik rather than end-to-end through the cluster

- **What is simplified:** the AWS load balancer handles TLS termination and forwards HTTP to Traefik
- **Why:** reduces certificate and ingress complexity in the demo while still reflecting a common edge-routing pattern
- **Risk introduced:** traffic between the load balancer and in-cluster ingress is not encrypted
- **Production version:** depending on requirements, this could move to re-encryption, full end-to-end TLS, stricter network controls, or service mesh-based traffic security

### 4) Image promotion is tag-driven and repository-driven, not policy-driven

- **What is simplified:** the environment overlay is updated directly with the image tag to deploy
- **Why:** it makes the CD handoff easy to understand in a portfolio project
- **Risk introduced:** promotion controls such as approvals, policy checks, and signed artifact verification are not yet built into the flow
- **Production version:** promotion would usually include stronger controls such as protected branches, approval gates, provenance/signature checks, and automated verification steps

