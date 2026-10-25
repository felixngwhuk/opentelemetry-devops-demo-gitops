#!/usr/bin/env bash
# Local-only checks for the Collector relay ConfigMap generator. No cluster access.
# Set PYTHON to an interpreter with PyYAML installed if needed.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python="${PYTHON:-python3}"
for dependency in kubectl "$python" git; do
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
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from io import BytesIO

import yaml

root = Path(sys.argv[1]).resolve()
baseline_revision = "79b998f4a6a633f76000de68fbfd424c29f1e95a"
collector_name = "otel-collector"
collector_version = "0.135.0"
checksum_value = "b23c30f9b89a34910edbfdafc7072ff305d9e8bb93ca26ffaed9ac1a8872cefb"
expected_labels = {
    "app.kubernetes.io/name": "opentelemetry-collector",
    "app.kubernetes.io/instance": "opentelemetry-demo",
    "app.kubernetes.io/version": collector_version,
    "app.kubernetes.io/part-of": "opentelemetry-collector",
    "app.kubernetes.io/component": "standalone-collector",
}
targets = {
    "base": Path("apps/opentelemetry-demo/base"),
    "dev": Path("apps/opentelemetry-demo/overlays/dev"),
    "staging": Path("apps/opentelemetry-demo/overlays/staging"),
    "prod": Path("apps/opentelemetry-demo/overlays/prod"),
}


def check(condition, message):
    if not condition:
        raise SystemExit(f"FAIL: {message}")


def documents(text):
    return [doc for doc in yaml.safe_load_all(text) if doc]


def render(path):
    command = ["kubectl", "kustomize", str(path)]
    print("+ " + " ".join(command), flush=True)
    result = subprocess.run(command, capture_output=True, text=True)
    if result.stderr:
        print(result.stderr, file=sys.stderr, end="")
    check(result.returncode == 0, f"render {path}: exit {result.returncode}")
    return documents(result.stdout)


def collector_configmap(docs, description):
    matches = [doc for doc in docs
               if doc.get("apiVersion") == "v1"
               and doc.get("kind") == "ConfigMap"
               and doc.get("data", {}).get("relay") is not None]
    check(len(matches) == 1,
          f"{description}: expected one Collector relay ConfigMap, found {len(matches)}")
    return matches[0]


def collector_deployment(docs, description):
    matches = [doc for doc in docs
               if doc.get("apiVersion") == "apps/v1"
               and doc.get("kind") == "Deployment"
               and doc.get("metadata", {}).get("name") == collector_name]
    check(len(matches) == 1,
          f"{description}: expected one Collector Deployment, found {len(matches)}")
    return matches[0]


def collector_volume(deployment, description):
    volumes = deployment["spec"]["template"]["spec"].get("volumes", [])
    matches = [volume for volume in volumes
               if volume.get("configMap", {}).get("items") == [
                   {"key": "relay", "path": "relay.yaml"}]]
    check(len(matches) == 1,
          f"{description}: expected one relay ConfigMap volume, found {len(matches)}")
    volume = matches[0]
    mount_names = [mount.get("name")
                   for container in deployment["spec"]["template"]["spec"].get("containers", [])
                   for mount in container.get("volumeMounts", [])
                   if mount.get("mountPath") == "/conf"]
    check(mount_names == [volume["name"]],
          f"{description}: Collector /conf mount no longer points at the relay volume")
    return volume


def verify_generated_render(docs, description, expected_relay):
    configmap = collector_configmap(docs, description)
    generated_name = configmap["metadata"]["name"]
    check(re.fullmatch(r"otel-collector-[a-z0-9]{5,}", generated_name) is not None,
          f"{description}: ConfigMap name is not hash-suffixed: {generated_name}")
    fixed_configmaps = [doc for doc in docs
                        if doc.get("apiVersion") == "v1"
                        and doc.get("kind") == "ConfigMap"
                        and doc.get("metadata", {}).get("name") == collector_name]
    check(not fixed_configmaps,
          f"{description}: old fixed-name Collector ConfigMap is present in rendered manifests")
    labels = configmap["metadata"].get("labels", {})
    check(all(labels.get(key) == value for key, value in expected_labels.items()),
          f"{description}: generated ConfigMap labels changed: {labels}")
    check(yaml.safe_load(configmap["data"]["relay"]) == expected_relay,
          f"{description}: generated relay config differs from extracted source")

    deployment = collector_deployment(docs, description)
    volume = collector_volume(deployment, description)
    check(volume["configMap"]["name"] == generated_name,
          f"{description}: volume references {volume['configMap']['name']}, expected {generated_name}")
    annotations = deployment["spec"]["template"]["metadata"].get("annotations", {})
    check("checksum/config" not in annotations,
          f"{description}: fixed checksum/config annotation remains")
    return configmap, deployment, volume


def baseline_collector_config(docs):
    configmap = collector_configmap(docs, "baseline source")
    check(configmap["metadata"]["name"] == collector_name,
          "baseline source: original ConfigMap name changed")
    return yaml.safe_load(configmap["data"]["relay"])


def without_phase1_additions(config, description):
    normalized = copy.deepcopy(config)
    processors = normalized.get("processors", {})
    if "resource/environment" in processors:
        expected = {"attributes": [{
            "action": "upsert", "key": "deployment.environment.name",
            "value": "${env:DEPLOYMENT_ENVIRONMENT}",
        }]}
        check(processors.pop("resource/environment") == expected,
              f"{description}: unexpected environment processor configuration")
        for signal in ("logs", "metrics", "traces"):
            pipeline = normalized["service"]["pipelines"][signal]["processors"]
            check(pipeline.count("resource/environment") == 1,
                  f"{description}/{signal}: expected one environment processor")
            pipeline.remove("resource/environment")
    if "prometheus" in normalized.get("exporters", {}):
        check(normalized["exporters"].pop("prometheus") == {"endpoint": "0.0.0.0:8889"},
              f"{description}: unexpected Prometheus exporter")
        statements = [
            'set(attributes["environment"], resource.attributes["deployment.environment.name"]) '
            'where resource.attributes["deployment.environment.name"] != nil',
            'set(cache["existing_service_name_aliases"], attributes)',
            'keep_matching_keys(cache["existing_service_name_aliases"], "^service[^a-zA-Z0-9]name$")',
            'set(attributes["service_name"], resource.attributes["service.name"]) '
            'where IsString(resource.attributes["service.name"]) '
            'and IsMatch(resource.attributes["service.name"], "[^[:space:]]") '
            'and Len(cache["existing_service_name_aliases"]) == 0',
        ]
        check(processors.pop("transform/metric-labels", None) == {
            "error_mode": "ignore",
            "metric_statements": [{"context": "datapoint", "statements": statements}],
        }, f"{description}: unexpected metric label transformation")
        pipeline = normalized["service"]["pipelines"]["metrics"]
        check(pipeline["exporters"].count("prometheus") == 1
              and pipeline["processors"].count("transform/metric-labels") == 1,
              f"{description}: expected one Prometheus exporter and metric label processor")
        pipeline["exporters"].remove("prometheus")
        pipeline["processors"].remove("transform/metric-labels")
    return normalized


def normalized_render(docs, description):
    normalized = copy.deepcopy(docs)
    for doc in normalized:
        metadata = doc.get("metadata", {})
        data = doc.get("data", {})
        if doc.get("kind") == "ConfigMap" and data.get("relay") is not None:
            # Compare the embedded YAML semantically so comments or formatting
            # edits can exercise Kustomize hashing without appearing as config changes.
            data["relay"] = without_phase1_additions(
                yaml.safe_load(data["relay"]), description)
        if doc.get("kind") == "Service" and metadata.get("name") == collector_name:
            ports = doc["spec"]["ports"]
            additions = [p for p in ports if p.get("name") == "prometheus-exporter"]
            if additions:
                check(additions == [{"name": "prometheus-exporter", "port": 8889,
                                     "targetPort": "prom-exporter", "protocol": "TCP"}],
                      f"{description}: unexpected exporter Service port")
                ports.remove(additions[0])
        if doc.get("kind") == "ConfigMap" and doc.get("data", {}).get("relay") is not None:
            metadata["name"] = collector_name
        if (doc.get("apiVersion") == "apps/v1"
                and doc.get("kind") == "Deployment"
                and metadata.get("name") == collector_name):
            pod_metadata = doc["spec"]["template"].setdefault("metadata", {})
            annotations = pod_metadata.setdefault("annotations", {})
            if description == "baseline":
                check(annotations.get("checksum/config") == checksum_value,
                      "baseline render: expected original fixed checksum annotation")
            annotations.pop("checksum/config", None)
            for container in doc["spec"]["template"]["spec"].get("containers", []):
                ports = container.get("ports", [])
                additions = [p for p in ports if p.get("name") == "prom-exporter"]
                if additions:
                    check(container.get("name") == "opentelemetry-collector"
                          and additions == [{"name": "prom-exporter", "containerPort": 8889,
                                             "protocol": "TCP"}],
                          f"{description}: unexpected exporter container port")
                    ports.remove(additions[0])
                env = container.get("env", [])
                environment_vars = [item for item in env
                                    if item.get("name") == "DEPLOYMENT_ENVIRONMENT"]
                if environment_vars:
                    check(description in {"dev", "staging", "prod"}
                          and container.get("name") == "opentelemetry-collector"
                          and environment_vars == [{"name": "DEPLOYMENT_ENVIRONMENT",
                                                    "value": description}],
                          f"{description}: unexpected Collector environment variable")
                    container["env"] = [item for item in env
                                        if item.get("name") != "DEPLOYMENT_ENVIRONMENT"]
            for volume in doc["spec"]["template"]["spec"].get("volumes", []):
                config_map = volume.get("configMap", {})
                config_map_name = config_map.get("name", "")
                if (config_map_name == collector_name
                        or re.fullmatch(r"otel-collector-[a-z0-9]+", config_map_name)):
                    config_map["name"] = collector_name

    keyed = {}
    for doc in normalized:
        metadata = doc.get("metadata", {})
        key = (doc.get("apiVersion"), doc.get("kind"),
               metadata.get("namespace", ""), metadata.get("name", ""))
        check(key not in keyed, f"{description}: duplicate rendered resource {key}")
        keyed[key] = doc
    return keyed


def verify_rolling_sync_policy():
    path = root / "argocd/opentelemetry-demo-applicationset.yaml"
    appset = yaml.safe_load(path.read_text())
    spec = appset.get("spec", {})
    strategy = spec.get("strategy", {})
    check(strategy.get("type") == "RollingSync",
          "ApplicationSet must retain the RollingSync strategy")

    expected_environments = ["dev", "staging", "prod"]
    steps = strategy.get("rollingSync", {}).get("steps", [])
    actual_environments = []
    for step in steps:
        expressions = step.get("matchExpressions", [])
        check(len(expressions) == 1,
              "each RollingSync step must have one rollout-environment expression")
        expression = expressions[0]
        check(expression.get("key") == "rollout-environment"
              and expression.get("operator") == "In"
              and len(expression.get("values", [])) == 1,
              "RollingSync step must match one rollout-environment value")
        check(step.get("maxUpdate") == 1,
              "each RollingSync step must retain maxUpdate: 1")
        actual_environments.append(expression["values"][0])
    check(actual_environments == expected_environments,
          f"RollingSync steps changed: {actual_environments}")

    expected_elements = [
        {"env": "dev", "namespace": "otel-demo-dev"},
        {"env": "staging", "namespace": "otel-demo-staging"},
        {"env": "prod", "namespace": "otel-demo-prod"},
    ]
    elements = spec.get("generators", [{}])[0].get("list", {}).get("elements", [])
    check(elements == expected_elements,
          f"ApplicationSet environment generator changed: {elements}")

    template_policy = spec.get("template", {}).get("spec", {}).get("syncPolicy", {})
    automated = template_policy.get("automated", {})
    check(automated.get("prune") is True,
          "ApplicationSet template must request automated pruning")
    check(automated.get("selfHeal") is True,
          "ApplicationSet template must request automated self-healing")
    check("enabled" not in automated,
          "ApplicationSet template must omit automated.enabled so RollingSync reads prune")
    check(automated.get("allowEmpty") is not True,
          "ApplicationSet template must not enable allowEmpty")
    sync_options = template_policy.get("syncOptions", [])
    check(set(sync_options) == {"CreateNamespace=true", "PruneLast=true"},
          f"ApplicationSet sync options changed unexpectedly: {sync_options}")

    root_application = yaml.safe_load(
        (root / "bootstrap/root-application.yaml").read_text())
    root_automated = root_application.get("spec", {}).get("syncPolicy", {}).get("automated", {})
    check(root_automated == {"prune": True, "selfHeal": True},
          "separate root Application auto-sync policy changed")
    print("PASS: RollingSync pruning policy, environment order, and root policy", flush=True)


work = Path(tempfile.mkdtemp(prefix="collector-configmap."))
try:
    verify_rolling_sync_policy()

    archive_result = subprocess.run(
        ["git", "archive", baseline_revision], cwd=root,
        capture_output=True, check=True)
    baseline_root = work / "baseline"
    baseline_root.mkdir()
    with tarfile.open(fileobj=BytesIO(archive_result.stdout), mode="r:") as archive:
        root_resolved = baseline_root.resolve()
        for member in archive.getmembers():
            destination = (baseline_root / member.name).resolve()
            check(destination == root_resolved or root_resolved in destination.parents,
                  f"baseline archive contains an unsafe path: {member.name}")
        archive.extractall(baseline_root)

    baseline_base_file = baseline_root / targets["base"] / "opentelemetry-demo.yaml"
    baseline_source_docs = documents(baseline_base_file.read_text())
    original_relay = baseline_collector_config(baseline_source_docs)
    relay_file = root / targets["base"] / "otel-collector-relay.yaml"
    extracted_relay = yaml.safe_load(relay_file.read_text())
    check(without_phase1_additions(extracted_relay, "extracted relay") == original_relay,
          "relay changed beyond the explicitly verified environment and Prometheus additions")

    for name, relative in targets.items():
        baseline_path = baseline_root / relative
        current_path = root / relative
        baseline_docs = render(baseline_path)
        current_docs = render(current_path)
        baseline_cm = collector_configmap(baseline_docs, f"baseline {name}")
        check(baseline_cm["metadata"]["labels"] == expected_labels,
              f"baseline {name}: expected five original Collector ConfigMap labels")
        check(yaml.safe_load(baseline_cm["data"]["relay"]) == original_relay,
              f"baseline {name}: original relay config changed")
        baseline_deployment = collector_deployment(baseline_docs, f"baseline {name}")
        baseline_volume = collector_volume(baseline_deployment, f"baseline {name}")
        check(baseline_volume["configMap"]["name"] == collector_name,
              f"baseline {name}: original Deployment volume reference changed")

        current_cm, _, _ = verify_generated_render(current_docs, name, extracted_relay)
        baseline_normalized = normalized_render(baseline_docs, "baseline")
        current_normalized = normalized_render(current_docs, name)
        check(current_normalized == baseline_normalized,
              f"{name}: rendered resources changed beyond ConfigMap hashing, checksum removal, "
              "and the verified environment and Prometheus additions")
        print(f"PASS: {name}: {current_cm['metadata']['name']} and Deployment reference agree",
              flush=True)

    fixture_root = work / "fixture"
    shutil.copytree(root / "apps", fixture_root / "apps")
    fixture_relay = fixture_root / targets["base"] / "otel-collector-relay.yaml"
    relay_text = fixture_relay.read_text()
    old_batch = "  batch: {}"
    check(relay_text.count(old_batch) == 1,
          "fixture: expected one batch processor to edit")
    edited_relay_text = relay_text.replace(
        old_batch, "  batch:\n    send_batch_size: 1024", 1)
    fixture_relay.write_text(edited_relay_text)
    edited_relay = yaml.safe_load(edited_relay_text)
    for name, relative in targets.items():
        original_docs = render(root / relative)
        fixture_docs = render(fixture_root / relative)
        original_cm = collector_configmap(original_docs, f"original fixture control {name}")
        changed_cm, _, changed_volume = verify_generated_render(
            fixture_docs, f"fixture {name}", edited_relay)
        original_name = original_cm["metadata"]["name"]
        changed_name = changed_cm["metadata"]["name"]
        check(changed_name != original_name,
              f"fixture {name}: relay edit did not change the generated ConfigMap name")
        check(changed_volume["configMap"]["name"] == changed_name,
              f"fixture {name}: Deployment reference did not follow the changed ConfigMap name")
        print(f"PASS: fixture {name}: relay edit changed name and Deployment reference together",
              flush=True)

    runtime = shutil.which("docker") or shutil.which("podman")
    if runtime is None:
        print("SKIP: Collector container validation unavailable (docker/podman not installed)",
              flush=True)
    else:
        runtime_info = subprocess.run([runtime, "info"], capture_output=True, text=True)
        if runtime_info.returncode != 0:
            print(f"SKIP: Collector container validation unavailable ({Path(runtime).name} daemon not ready)",
                  flush=True)
        else:
            command = [
                runtime, "run", "--rm", "-e", "MY_POD_IP=127.0.0.1",
                "-e", "DEPLOYMENT_ENVIRONMENT=dev",
                "-v", f"{relay_file}:/conf/relay.yaml:ro",
                f"otel/opentelemetry-collector-contrib:{collector_version}",
                "validate", "--config=/conf/relay.yaml",
            ]
            print("+ " + " ".join(command), flush=True)
            result = subprocess.run(command, capture_output=True, text=True)
            if result.stdout:
                print(result.stdout, end="", flush=True)
            if result.stderr:
                print(result.stderr, file=sys.stderr, end="", flush=True)
            check(result.returncode == 0,
                  f"Collector config validation failed: exit {result.returncode}")
            print("PASS: pinned Collector config validation", flush=True)

    print("PASS: Collector ConfigMap extraction, renders, and hash rollout behavior", flush=True)
finally:
    shutil.rmtree(work, ignore_errors=True)
PY
