#!/usr/bin/env bash
# Local-only rendered wiring checks. Set OTELCOL to a Contrib 0.135.0 binary
# to validate full configs and test HTTP metrics plus the real spanmetrics connector.
# Requires kubectl and a PYTHON interpreter with PyYAML; no cluster access.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
"${PYTHON:-python3}" - "$repo_root" <<'PY'
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

import yaml

root = Path(sys.argv[1])
collector = os.environ.get("OTELCOL")
expected_statements = [
    'set(attributes["environment"], resource.attributes["deployment.environment.name"]) '
    'where resource.attributes["deployment.environment.name"] != nil',
    'set(cache["existing_service_name_aliases"], attributes)',
    'keep_matching_keys(cache["existing_service_name_aliases"], "^service[^a-zA-Z0-9]name$")',
    'set(attributes["service_name"], resource.attributes["service.name"]) '
    'where IsString(resource.attributes["service.name"]) '
    'and IsMatch(resource.attributes["service.name"], "[^[:space:]]") '
    'and Len(cache["existing_service_name_aliases"]) == 0',
]
common = ["k8sattributes", "memory_limiter", "resourcedetection", "resource"]
expected_pipelines = {
    "logs": {"receivers": ["otlp"], "exporters": ["debug"],
             "processors": common + ["resource/environment", "batch"]},
    "metrics": {"receivers": ["httpcheck/frontend-proxy", "nginx", "otlp",
                              "postgresql", "redis", "spanmetrics"],
                "exporters": ["debug", "prometheus"],
                "processors": common + ["resource/environment", "transform/metric-labels", "batch"]},
    "traces": {"receivers": ["otlp", "zipkin"], "exporters": ["debug", "spanmetrics"],
               "processors": common + ["transform", "resource/environment", "batch"]},
}
expected_receivers = {"httpcheck/frontend-proxy", "nginx", "otlp", "postgresql",
                      "prometheus", "redis", "zipkin"}


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def run(command, **kwargs):
    print("+ " + " ".join(map(str, command)), flush=True)
    result = subprocess.run(command, capture_output=True, text=True, **kwargs)
    print(f"exit {result.returncode}", flush=True)
    if result.stderr:
        print(result.stderr, file=sys.stderr, end="")
    check(result.returncode == 0, f"command failed: {command}")
    return result.stdout


def only(items, message):
    check(len(items) == 1, message)
    return items[0]


def verify(documents, environment):
    configmap = only([d for d in documents if d.get("kind") == "ConfigMap"
                      and "relay" in d.get("data", {})], "expected one relay ConfigMap")
    config = yaml.safe_load(configmap["data"]["relay"])
    check(config["exporters"]["prometheus"] == {"endpoint": "0.0.0.0:8889"},
          "incorrect exporter endpoint or unexpected options")
    check("resource_to_telemetry_conversion" not in yaml.safe_dump(config),
          "blanket resource conversion must not be configured")
    check(config["processors"]["transform/metric-labels"] == {
        "error_mode": "ignore",
        "metric_statements": [{"context": "datapoint", "statements": expected_statements}],
    }, "expected authoritative environment and collision-safe service fallback only")
    check(config["service"]["pipelines"] == expected_pipelines,
          "pipeline receivers, exporters, or processor ordering changed")
    check(set(config["receivers"]) == expected_receivers, "receiver definitions changed")

    deployment = only([d for d in documents if d.get("kind") == "Deployment"
                       and d["metadata"]["name"] == "otel-collector"], "Collector Deployment missing")
    container = only([c for c in deployment["spec"]["template"]["spec"]["containers"]
                      if c["name"] == "opentelemetry-collector"], "Collector container missing")
    service = only([d for d in documents if d.get("kind") == "Service"
                   and d["metadata"]["name"] == "otel-collector"], "Collector Service missing")
    container_ports = container["ports"]
    service_ports = service["spec"]["ports"]
    check(len(container_ports) == 5 and len(service_ports) == 5, "unexpected port count")
    check(len({p["name"] for p in container_ports}) == 5, "duplicate container port name")
    check(len({p["name"] for p in service_ports}) == 5, "duplicate Service port name")
    for port in container_ports:
        name = port["name"]
        check(len(name) <= 15 and re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", name)
              and re.search(r"[a-z]", name), f"invalid container port name: {name}")
    for name, number in {"metrics": 8888, "otlp": 4317, "otlp-http": 4318, "zipkin": 9411}.items():
        check({"name": name, "containerPort": number, "protocol": "TCP"} in container_ports,
              f"existing container port {name} changed")
        existing = only([p for p in service_ports if p["name"] == name], f"missing port {name}")
        check(existing["port"] == existing["targetPort"] == number and existing["protocol"] == "TCP",
              f"existing Service port {name} changed")
    check({"name": "prom-exporter", "containerPort": 8889, "protocol": "TCP"} in container_ports,
          "missing exporter container port")
    check({"name": "prometheus-exporter", "port": 8889, "targetPort": "prom-exporter",
           "protocol": "TCP"} in service_ports, "missing named exporter Service wiring")
    check(service["spec"]["type"] == "ClusterIP", "Collector must remain private")
    print(f"PASS: {environment}: selective labels, pipelines, and ports", flush=True)
    return config

try:
    if collector:
        check("version 0.135.0" in run([collector, "--version"]), "requires Collector Contrib 0.135.0")
    with tempfile.TemporaryDirectory(prefix="prometheus-exporter-") as temporary:
        directory = Path(temporary)
        configs = {}
        for environment in ("dev", "staging", "prod"):
            output = run(["kubectl", "kustomize", str(root / "apps/opentelemetry-demo/overlays" / environment)])
            config = verify([d for d in yaml.safe_load_all(output) if d], environment)
            configs[environment] = config
            if collector:
                path = directory / f"{environment}-relay.yaml"
                path.write_text(yaml.safe_dump(config))
                run([collector, "validate", "--config", str(path)], env={
                    **os.environ, "MY_POD_IP": "127.0.0.1", "DEPLOYMENT_ENVIRONMENT": environment})
        if collector:
            sys.dont_write_bytecode = True
            sys.path.insert(0, str(root / "tests/phase1"))
            from prometheus_exporter_fixture import run_fixtures
            run_fixtures(configs, directory, collector)
        else:
            print("SKIP: Collector validation and metric fixture (set OTELCOL to Contrib 0.135.0)")
except (AssertionError, KeyError, TypeError, OSError, ValueError) as error:
    raise SystemExit(f"FAIL: {error}")
PY
