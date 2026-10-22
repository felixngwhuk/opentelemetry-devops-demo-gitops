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

"$python" - "$repo_root" <<'PY'
import copy
from pathlib import Path
import subprocess
import sys

import yaml

root = Path(sys.argv[1])
managed = "platform.devopsbyfelix.shop/release-managed"
version = "app.kubernetes.io/version"
prefix = "ghcr.io/felixngwhuk/opentelemetry-devops-demo/"
eligible = set("""accounting ad cart checkout currency email fraud-detection
frontend frontend-proxy image-provider kafka payment product-catalog quote
recommendation shipping""".split())
excluded = {"flagd", "postgresql", "valkey-cart", "otel-collector"}
expected_release = {
    "name": "RELEASE_VERSION",
    "valueFrom": {"fieldRef": {
        "apiVersion": "v1",
        "fieldPath": "metadata.labels['app.kubernetes.io/version']",
    }},
}
expected_attributes = (
    "service.name=$(OTEL_SERVICE_NAME),service.namespace=opentelemetry-demo,"
    "service.version=$(RELEASE_VERSION)"
)


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def deployments(text):
    docs = [doc for doc in yaml.safe_load_all(text) if doc]
    result = {doc["metadata"]["name"]: doc for doc in docs
              if doc.get("apiVersion") == "apps/v1" and doc.get("kind") == "Deployment"}
    check(set(result) == eligible | excluded, "unexpected Deployment set")
    return result


def validate(current, context, rendered):
    selected = {name for name, doc in current.items()
                if doc["metadata"].get("labels", {}).get(managed) == "true"}
    check(selected == eligible, f"{context}: incorrect release selection")
    for name, doc in current.items():
        pod = doc["spec"]["template"]
        spec = pod["spec"]
        for container in spec.get("initContainers", []):
            check(not any(env["name"] == "RELEASE_VERSION"
                          for env in container.get("env", [])),
                  f"{context}/{name}: init container must not derive release version")
        if name in excluded:
            for container in spec["containers"]:
                env = container.get("env", [])
                check(not any(item["name"] == "RELEASE_VERSION" for item in env),
                      f"{context}/{name}/{container['name']}: excluded container changed")
                if name == "otel-collector" and rendered:
                    deployment_environment = [item for item in env
                                              if item["name"] == "DEPLOYMENT_ENVIRONMENT"]
                    check(len(deployment_environment) == 1,
                          f"{context}/{name}/{container['name']}: expected one DEPLOYMENT_ENVIRONMENT")
                    check(deployment_environment[0].get("value") == context,
                          f"{context}/{name}/{container['name']}: incorrect DEPLOYMENT_ENVIRONMENT")
            continue
        check(len(spec["containers"]) == 1, f"{context}/{name}: unexpected app containers")
        container = spec["containers"][0]
        check(container["name"] == name and container["image"].startswith(prefix + name + ":"),
              f"{context}/{name}: unexpected app container or image")
        env = container.get("env", [])
        names = [item["name"] for item in env]
        check(names.count("RELEASE_VERSION") == 1,
              f"{context}/{name}: expected exactly one RELEASE_VERSION")
        check(names.count("OTEL_RESOURCE_ATTRIBUTES") == 1,
              f"{context}/{name}: expected exactly one OTEL_RESOURCE_ATTRIBUTES")
        release_index = names.index("RELEASE_VERSION")
        attributes_index = names.index("OTEL_RESOURCE_ATTRIBUTES")
        check(env[release_index] == expected_release,
              f"{context}/{name}: incorrect Pod-label field reference")
        check(release_index + 1 == attributes_index,
              f"{context}/{name}: RELEASE_VERSION must immediately precede attributes")
        check(env[attributes_index] == {"name": "OTEL_RESOURCE_ATTRIBUTES",
                                        "value": expected_attributes},
              f"{context}/{name}: incorrect service.version or other resource attributes")
        if rendered:
            label = pod["metadata"].get("labels", {}).get(version)
            check(isinstance(label, str) and bool(label),
                  f"{context}/{name}: missing Pod version label")
            check(label == container["image"].rpartition(":")[2],
                  f"{context}/{name}: Pod version does not match image tag")


try:
    base = deployments((root / "apps/opentelemetry-demo/base/opentelemetry-demo.yaml").read_text())
    validate(base, "base", rendered=False)
    for environment in ("dev", "staging", "prod"):
        path = root / f"apps/opentelemetry-demo/overlays/{environment}"
        print(f"+ kubectl kustomize {path}", flush=True)
        result = subprocess.run(["kubectl", "kustomize", str(path)],
                                capture_output=True, text=True)
        if result.stderr:
            print(result.stderr, file=sys.stderr, end="")
        check(result.returncode == 0, f"{environment}: render exit {result.returncode}")
        current = deployments(result.stdout)
        validate(current, environment, rendered=True)
        for name, doc in current.items():
            spec = doc["spec"]["template"]["spec"]
            baseline = base[name]["spec"]["template"]["spec"]
            check(spec.get("initContainers") == baseline.get("initContainers"),
                  f"{environment}/{name}: init containers changed")
            if name in excluded:
                current_containers = []
                for container in spec["containers"]:
                    env = container.get("env", [])
                    if name == "otel-collector":
                        env = [item for item in env if item["name"] != "DEPLOYMENT_ENVIRONMENT"]
                    current_containers.append((container["name"], env))
                check(current_containers ==
                      [(c["name"], c.get("env", [])) for c in baseline["containers"]],
                      f"{environment}/{name}: excluded container env changed")
        print(f"PASS: {environment}: 16 Pod-label versions, env order, image tags; "
              "excluded env and init containers unchanged", flush=True)

        # Mutate only in-memory fixtures; prove the validator rejects regressions.
        for defect, expected_error in (
            ("field-reference", "incorrect Pod-label field reference"),
            ("env-order", "must immediately precede"),
            ("fixed-version", "incorrect service.version"),
            ("missing-label", "missing Pod version label"),
        ):
            fixture = copy.deepcopy(current)
            pod = fixture["checkout"]["spec"]["template"]
            env = pod["spec"]["containers"][0]["env"]
            release_index = next(i for i, item in enumerate(env)
                                 if item["name"] == "RELEASE_VERSION")
            attributes_index = release_index + 1
            if defect == "field-reference":
                env[release_index]["valueFrom"]["fieldRef"]["fieldPath"] = "metadata.name"
            elif defect == "env-order":
                env[release_index], env[attributes_index] = env[attributes_index], env[release_index]
            elif defect == "fixed-version":
                env[attributes_index]["value"] = expected_attributes.replace("$(RELEASE_VERSION)", "2.1.3")
            else:
                del pod["metadata"]["labels"][version]
            try:
                validate(fixture, f"{environment}/{defect}", rendered=True)
            except AssertionError as error:
                check(expected_error in str(error), f"{defect}: unexpected failure: {error}")
                print(f"PASS: {environment}: rejected {defect} fixture", flush=True)
            else:
                raise AssertionError(f"{environment}: accepted broken {defect} fixture")
    print("PASS: OpenTelemetry service.version in all overlays")
except AssertionError as error:
    raise SystemExit(f"FAIL: {error}")
PY
