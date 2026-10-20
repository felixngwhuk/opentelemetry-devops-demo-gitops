#!/usr/bin/env bash
# Local-only checks. Requires kubectl, Python 3 and PyYAML; no cluster access.
# Set PYTHON to a virtualenv interpreter if PyYAML is installed there.
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

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/release-selection.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

"$python" - "$repo_root" "$work_dir" <<'PY'
import copy
from pathlib import Path
import shutil
import subprocess
import sys

import yaml

root, work = map(Path, sys.argv[1:])
managed = "platform.devopsbyfelix.shop/release-managed"
version = "app.kubernetes.io/version"
version_path = "/spec/template/metadata/labels/app.kubernetes.io~1version"
prefix = "ghcr.io/felixngwhuk/opentelemetry-devops-demo/"
eligible = set("""accounting ad cart checkout currency email fraud-detection
frontend frontend-proxy image-provider kafka payment product-catalog quote
recommendation shipping""".split())
excluded = {"flagd", "postgresql", "valkey-cart", "otel-collector"}


def check(condition, message):
    if not condition:
        raise SystemExit(f"FAIL: {message}")


def load(path):
    return yaml.safe_load(path.read_text())


def documents(text):
    return [doc for doc in yaml.safe_load_all(text) if doc]


def deployments(docs):
    return {doc["metadata"]["name"]: doc for doc in docs
            if doc.get("apiVersion") == "apps/v1" and doc.get("kind") == "Deployment"}


def render(path, output):
    print(f"+ kubectl kustomize {path}", flush=True)
    result = subprocess.run(["kubectl", "kustomize", str(path)],
                            capture_output=True, text=True)
    if result.stderr:
        print(result.stderr, file=sys.stderr, end="")
    check(result.returncode == 0, f"render {path}: exit {result.returncode}")
    output.write_text(result.stdout)
    return documents(result.stdout)


base = documents((root / "apps/opentelemetry-demo/base/opentelemetry-demo.yaml").read_text())
base_deployments = deployments(base)
check(set(base_deployments) == eligible | excluded, "unexpected base Deployment set")
selected = {name for name, doc in base_deployments.items()
            if doc["metadata"].get("labels", {}).get(managed) == "true"}
check(selected == eligible, f"base selection: missing={sorted(eligible - selected)}, "
      f"unexpected={sorted(selected - eligible)}")
for doc in base:
    labels = doc.get("metadata", {}).get("labels", {})
    if managed in labels:
        check(doc.get("kind") == "Deployment" and doc["metadata"]["name"] in eligible,
              "release-managed label on an ineligible resource")
        check(labels[managed] == "true", "release-managed label must be string true")
for name, doc in base_deployments.items():
    check(managed not in doc["spec"]["template"]["metadata"].get("labels", {}),
          f"{name}: release-managed marker belongs only on Deployment metadata")

# Render a control with only the new Pod-version patch removed. This preserves
# existing environment image/resource patches, including the flagd-ui image.
control_root = work / "control"
shutil.copytree(root / "apps", control_root / "apps")
for env in ("dev", "staging", "prod"):
    relative = Path(f"apps/opentelemetry-demo/overlays/{env}")
    config = load(root / relative / "kustomization.yaml")
    tags = {str(image["newTag"]) for image in config["images"]
            if image["name"].startswith(prefix)}
    check(len(tags) == 1, f"{env}: expected one first-party release tag, got {tags}")
    expected_tag = tags.pop()
    patches = [patch for patch in config.get("patches", [])
               if patch.get("target", {}).get("labelSelector") == f"{managed}=true"]
    check(len(patches) == 1, f"{env}: expected exactly one release selection patch")
    patch = patches[0]
    check(patch["target"] == {"group": "apps", "version": "v1", "kind": "Deployment",
                              "labelSelector": f"{managed}=true"},
          f"{env}: patch must target only selected apps/v1 Deployments")
    check(yaml.safe_load(patch["patch"]) == [
        {"op": "add", "path": version_path, "value": expected_tag}],
        f"{env}: patch must set only the Pod version to {expected_tag}")
    control_config = copy.deepcopy(config)
    control_config["patches"].remove(patch)
    (control_root / relative / "kustomization.yaml").write_text(
        yaml.safe_dump(control_config, sort_keys=False))
    rendered = render(root / relative, work / f"{env}.yaml")
    control = render(control_root / relative, work / f"{env}-control.yaml")
    current = deployments(rendered)
    check(set(current) == eligible | excluded, f"{env}: unexpected Deployment set")
    actual_selected = {name for name, doc in current.items()
                       if doc["metadata"].get("labels", {}).get(managed) == "true"}
    check(actual_selected == eligible, f"{env}: incorrect release selection")
    images = {image["name"]: str(image["newTag"]) for image in config["images"]}
    normalized = copy.deepcopy(rendered)
    for name, doc in deployments(normalized).items():
        pod_labels = doc["spec"]["template"]["metadata"].get("labels", {})
        check(managed not in pod_labels, f"{env}/{name}: marker leaked to Pod labels")
        if name in eligible:
            check(pod_labels.get(version) == expected_tag,
                  f"{env}/{name}: incorrect or missing Pod version")
            for container in doc["spec"]["template"]["spec"]["containers"]:
                image_name, separator, tag = container["image"].rpartition(":")
                check(separator and image_name.startswith(prefix)
                      and images.get(image_name) == tag == expected_tag,
                      f"{env}/{name}: application image does not match Pod version")
            del pod_labels[version]
    check(normalized == control,
          f"{env}: excluded workloads or other rendered fields changed")
    print(f"PASS: {env}: {len(eligible)} selected Pod versions = {expected_tag}; "
          f"{len(excluded)} excluded Pod templates unchanged", flush=True)
print("PASS: release selection in all overlays")
PY
