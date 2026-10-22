#!/usr/bin/env bash
# Local-only checks for environment identity on all Collector signals.
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
environments = {"dev": "otel-demo-dev", "staging": "otel-demo-staging", "prod": "otel-demo-prod"}
pipeline_processors = {
    "logs": ["k8sattributes", "memory_limiter", "resourcedetection", "resource",
              "resource/environment", "batch"],
    "metrics": ["k8sattributes", "memory_limiter", "resourcedetection", "resource",
                 "resource/environment", "batch"],
    "traces": ["k8sattributes", "memory_limiter", "resourcedetection", "resource",
                "transform", "resource/environment", "batch"],
}
expected_resource_processor = {
    "attributes": [{
        "action": "upsert",
        "key": "deployment.environment.name",
        "value": "${env:DEPLOYMENT_ENVIRONMENT}",
    }]
}


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def load_documents(text):
    return [doc for doc in yaml.safe_load_all(text) if doc]


def render(environment, path):
    command = ["kubectl", "kustomize", str(path)]
    print("+ " + " ".join(command), flush=True)
    result = subprocess.run(command, capture_output=True, text=True)
    if result.stderr:
        print(result.stderr, file=sys.stderr, end="")
    check(result.returncode == 0, f"{environment}: render exit {result.returncode}")
    return load_documents(result.stdout)


def collector_deployment(documents, environment):
    matches = [doc for doc in documents
               if doc.get("apiVersion") == "apps/v1"
               and doc.get("kind") == "Deployment"
               and doc.get("metadata", {}).get("name") == "otel-collector"]
    check(len(matches) == 1,
          f"{environment}: expected one otel-collector Deployment, found {len(matches)}")
    return matches[0]


def pod_templates(document):
    kind = document.get("kind")
    api_version = document.get("apiVersion")
    spec = document.get("spec", {})
    if api_version == "batch/v1" and kind == "CronJob":
        template = spec.get("jobTemplate", {}).get("spec", {}).get("template", {})
    elif (api_version in {"apps/v1", "batch/v1"}
          and kind in {"Deployment", "StatefulSet", "DaemonSet", "Job"}):
        template = spec.get("template", {})
    else:
        return []
    return [template.get("spec", {})] if isinstance(template, dict) else []


def verify_relay(config, environment):
    processors = config.get("processors", {})
    check(processors.get("resource/environment") == expected_resource_processor,
          f"{environment}: incorrect resource/environment processor configuration")
    pipelines = config.get("service", {}).get("pipelines", {})
    check(set(pipelines) >= set(pipeline_processors),
          f"{environment}: missing signal pipelines")
    for signal, expected in pipeline_processors.items():
        actual = pipelines[signal].get("processors", [])
        check(actual == expected,
              f"{environment}/{signal}: processors changed: {actual}")


try:
    for environment, namespace in environments.items():
        overlay = root / f"apps/opentelemetry-demo/overlays/{environment}"
        documents = render(environment, overlay)
        check(any(doc.get("kind") == "Namespace"
                  and doc.get("metadata", {}).get("name") == namespace
                  for doc in documents),
              f"{environment}: expected namespace {namespace}")

        deployment = collector_deployment(documents, environment)
        containers = deployment["spec"]["template"]["spec"].get("containers", [])
        collector_containers = [container for container in containers
                                if container.get("name") == "opentelemetry-collector"]
        check(len(collector_containers) == 1,
              f"{environment}: expected one opentelemetry-collector container")
        collector_env = [item for item in collector_containers[0].get("env", [])
                         if item.get("name") == "DEPLOYMENT_ENVIRONMENT"]
        check(collector_env == [{"name": "DEPLOYMENT_ENVIRONMENT", "value": environment}],
              f"{environment}: expected exactly one DEPLOYMENT_ENVIRONMENT={environment}")

        all_environment_vars = []
        for doc in documents:
            for pod_spec in pod_templates(doc):
                for container in (pod_spec.get("initContainers", [])
                                  + pod_spec.get("containers", [])):
                    for item in container.get("env", []):
                        if item.get("name") == "DEPLOYMENT_ENVIRONMENT":
                            all_environment_vars.append((
                                doc.get("metadata", {}).get("name"),
                                container.get("name"), item))
        check(len(all_environment_vars) == 1,
              f"{environment}: DEPLOYMENT_ENVIRONMENT must occur once in workload pod specs")
        check(all_environment_vars[0] == (
            "otel-collector", "opentelemetry-collector",
            {"name": "DEPLOYMENT_ENVIRONMENT", "value": environment}),
            f"{environment}: DEPLOYMENT_ENVIRONMENT must belong to the Collector container")

        relay_configmaps = [doc for doc in documents
                            if doc.get("apiVersion") == "v1"
                            and doc.get("kind") == "ConfigMap"
                            and doc.get("data", {}).get("relay") is not None]
        check(len(relay_configmaps) == 1,
              f"{environment}: expected one generated Collector relay ConfigMap")
        relay = yaml.safe_load(relay_configmaps[0]["data"]["relay"])
        verify_relay(relay, environment)
        print(f"PASS: {environment}: one environment value and all 3 signal pipelines", flush=True)

    print("PASS: Collector environment identity in dev, staging, and prod")
except (AssertionError, KeyError, TypeError) as error:
    raise SystemExit(f"FAIL: {error}")
PY
