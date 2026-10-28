#!/usr/bin/env bash
# Local-only checks for the gp3 monitoring StorageClass and isolated smoke fixture.
# Set PYTHON to an interpreter with PyYAML installed if needed.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python="${PYTHON:-python3}"
for dependency in kubectl "$python"; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    echo "ERROR: required dependency not found: $dependency" >&2
    exit 1
  fi
done
if ! "$python" -c 'import yaml' >/dev/null 2>&1; then
  echo "ERROR: PyYAML is required by $python (install with: $python -m pip install PyYAML)" >&2
  exit 1
fi

"$python" - "$repo_root" <<'PY'
from pathlib import Path
import subprocess
import sys

import yaml

root = Path(sys.argv[1]).resolve()


def check(condition, message):
    if not condition:
        raise SystemExit(f"FAIL: {message}")


def load_documents(path):
    return [document for document in yaml.safe_load_all(path.read_text()) if document]


def render_storage():
    command = ["kubectl", "kustomize", "cluster/storage"]
    print("+ " + " ".join(command), flush=True)
    result = subprocess.run(command, cwd=root, capture_output=True, text=True)
    if result.stderr:
        print(result.stderr, file=sys.stderr, end="")
    check(result.returncode == 0, f"storage render exited {result.returncode}")
    return [document for document in yaml.safe_load_all(result.stdout) if document]


rendered = render_storage()
check(len(rendered) == 1, f"expected one rendered resource, found {len(rendered)}")
storage_class = rendered[0]
check(storage_class.get("apiVersion") == "storage.k8s.io/v1"
      and storage_class.get("kind") == "StorageClass",
      "render must contain only a storage.k8s.io/v1 StorageClass")
check(storage_class.get("metadata", {}) == {"name": "gp3-monitoring"},
      "StorageClass metadata changed or contains unexpected annotations")
check(storage_class.get("provisioner") == "ebs.csi.aws.com",
      "unexpected EBS CSI provisioner")
expected_parameters = {
    "type": "gp3",
    "encrypted": "true",
    "tagSpecification_1": "Project=opentelemetry-devops-demo",
    "tagSpecification_2": "Owner=felixngwhuk",
    "tagSpecification_3": "Environment=shared",
    "tagSpecification_4": "ManagedBy=ebs-csi-driver",
}
expected_tag_parameters = [
    "tagSpecification_1",
    "tagSpecification_2",
    "tagSpecification_3",
    "tagSpecification_4",
]
parameters = storage_class.get("parameters", {})
check(parameters == expected_parameters,
      f"StorageClass parameters differ from the approved contract: {parameters}")
check([key for key in parameters if key.startswith("tagSpecification_")]
      == expected_tag_parameters,
      "custom tag parameters must remain in tagSpecification_1 through _4 order")
check(storage_class.get("reclaimPolicy") == "Delete",
      "expected reclaimPolicy Delete")
check(storage_class.get("allowVolumeExpansion") is True,
      "expected allowVolumeExpansion true")
check(storage_class.get("volumeBindingMode") == "WaitForFirstConsumer",
      "expected WaitForFirstConsumer binding")
print("PASS: rendered StorageClass contract", flush=True)

application_path = root / "argocd/storage-application.yaml"
application = load_documents(application_path)
check(len(application) == 1, "storage Application file must contain one document")
application = application[0]
check(application.get("apiVersion") == "argoproj.io/v1alpha1"
      and application.get("kind") == "Application",
      "storage Application API or kind changed")
check(application.get("metadata", {}).get("name") == "storage"
      and application["metadata"].get("namespace") == "argocd"
      and application["metadata"].get("annotations", {}).get(
          "argocd.argoproj.io/sync-wave") == "0"
      and application["metadata"].get("finalizers") == [
          "resources-finalizer.argocd.argoproj.io"],
      "storage Application metadata, sync wave, or finalizer changed")
spec = application.get("spec", {})
check(spec.get("project") == "default", "storage Application project changed")
check(spec.get("source") == {
    "repoURL": "https://github.com/felixngwhuk/opentelemetry-devops-demo-gitops.git",
    "targetRevision": "main",
    "path": "cluster/storage",
}, "storage Application source changed")
check(spec.get("destination") == {"server": "https://kubernetes.default.svc"},
      "storage Application must target the in-cluster cluster scope")
check(spec.get("syncPolicy", {}).get("automated") == {
    "prune": True,
    "selfHeal": True,
}, "storage Application automated sync policy changed")

root_application = load_documents(root / "bootstrap/root-application.yaml")
check(len(root_application) == 1
      and root_application[0].get("spec", {}).get("source", {}).get("path") == "argocd",
      "root Application must continue discovering Applications from argocd/")
print("PASS: Argo CD source, destination, discovery, and sync policy", flush=True)

fixture_root = root / "tests/fixtures/storage"
fixture_files = sorted(path.name for path in fixture_root.glob("*.yaml"))
check(fixture_files == ["namespace.yaml", "pod.yaml", "pvc.yaml"],
      f"unexpected storage fixture files: {fixture_files}")
fixture_documents = [document for path in sorted(fixture_root.glob("*.yaml"))
                     for document in load_documents(path)]
check(len(fixture_documents) == 3, "expected exactly three storage fixture documents")
by_kind = {document.get("kind"): document for document in fixture_documents}
check(set(by_kind) == {"Namespace", "PersistentVolumeClaim", "Pod"},
      f"unexpected fixture resource kinds: {set(by_kind)}")
namespace = by_kind["Namespace"]
check(namespace.get("metadata", {}).get("name") == "otel-storage-test",
      "fixture namespace changed")

pvc = by_kind["PersistentVolumeClaim"]
check(pvc.get("metadata", {}) == {
    "name": "gp3-monitoring-smoke",
    "namespace": "otel-storage-test",
}, "fixture PVC identity changed")
pvc_spec = pvc.get("spec", {})
check(pvc_spec.get("accessModes") == ["ReadWriteOnce"]
      and pvc_spec.get("volumeMode") == "Filesystem"
      and pvc_spec.get("storageClassName") == "gp3-monitoring"
      and pvc_spec.get("resources", {}).get("requests", {}).get("storage") == "1Gi",
      "fixture PVC must request a 1Gi filesystem volume from gp3-monitoring")

pod = by_kind["Pod"]
check(pod.get("metadata", {}) == {
    "name": "gp3-monitoring-smoke",
    "namespace": "otel-storage-test",
}, "fixture Pod identity changed")
pod_spec = pod.get("spec", {})
check(pod_spec.get("restartPolicy") == "Never", "fixture Pod must use restartPolicy Never")
containers = pod_spec.get("containers", [])
check(len(containers) == 1, "fixture Pod must have exactly one container")
container = containers[0]
check(container.get("image") == "busybox:1.37.0"
      and container.get("command") == ["sh", "-c", "sleep 3600"],
      "fixture Pod image or sleep command changed")
check(container.get("volumeMounts") == [{"name": "storage", "mountPath": "/data"}],
      "fixture Pod must mount its PVC at /data")
check(pod_spec.get("volumes") == [{
    "name": "storage",
    "persistentVolumeClaim": {"claimName": "gp3-monitoring-smoke"},
}], "fixture Pod must consume the uniquely named PVC")

argocd_source_paths = []
for directory in (root / "argocd", root / "bootstrap"):
    for path in sorted([*directory.rglob("*.yaml"), *directory.rglob("*.yml")]):
        for document in load_documents(path):
            kind = document.get("kind")
            spec = document.get("spec", {})
            if kind == "Application":
                source = spec.get("source", {})
                if source.get("path"):
                    argocd_source_paths.append(source["path"])
            elif kind == "ApplicationSet":
                source = spec.get("template", {}).get("spec", {}).get("source", {})
                if source.get("path") and "{{" not in source["path"]:
                    argocd_source_paths.append(source["path"])
check("cluster/storage" in argocd_source_paths,
      "Argo CD source paths do not include cluster/storage")
for source_path in argocd_source_paths:
    resolved_source = (root / source_path).resolve()
    try:
        fixture_root.resolve().relative_to(resolved_source)
    except ValueError:
        continue
    raise SystemExit(f"FAIL: smoke fixtures fall under Argo CD source {source_path}")
print("PASS: isolated namespace, 1Gi PVC, consuming Pod, and fixture isolation", flush=True)
print("PASS: gp3 monitoring storage manifests and Argo CD configuration", flush=True)
PY
