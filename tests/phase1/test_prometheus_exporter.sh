#!/usr/bin/env bash
# Local-only rendered wiring checks. Set OTELCOL to a Contrib 0.135.0 binary
# to also validate full configs and run an isolated localhost OTLP fixture.
# Requires kubectl and a PYTHON interpreter with PyYAML; no cluster access.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
"${PYTHON:-python3}" - "$repo_root" <<'PY'
import copy
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

import yaml

root = Path(sys.argv[1])
collector = os.environ.get("OTELCOL")
mappings = {
    "deployment.environment.name": "environment",
    "service.name": "service_name",
    "service.version": "service_version",
    "k8s.namespace.name": "k8s_namespace_name",
}
expected_statements = [
    f'set(attributes["{label}"], resource.attributes["{key}"]) '
    f'where resource.attributes["{key}"] != nil'
    for key, label in mappings.items()
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
    }, "expected exactly four guarded datapoint label mappings")
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


def fixture(config, directory):
    # Isolate the actual label processors/exporter from Kubernetes discovery,
    # infrastructure polling, and the production Collector's telemetry readers.
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 8889))
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        otlp_port = probe.getsockname()[1]
    isolated = {
        "receivers": {"otlp": {"protocols": {"http": {"endpoint": f"127.0.0.1:{otlp_port}"}}}},
        "processors": {key: copy.deepcopy(config["processors"][key])
                       for key in ("resource/environment", "transform/metric-labels")},
        "exporters": {"prometheus": {**config["exporters"]["prometheus"],
                                      "endpoint": "127.0.0.1:8889"}},
        "service": {"telemetry": {"metrics": {"level": "none"}}, "pipelines": {
            "metrics": {"receivers": ["otlp"],
                        "processors": ["resource/environment", "transform/metric-labels"],
                        "exporters": ["prometheus"]}}},
    }
    path = directory / "fixture.yaml"
    path.write_text(yaml.safe_dump(isolated))
    env = {**os.environ, "DEPLOYMENT_ENVIRONMENT": "dev"}
    command = [collector, "--config", str(path)]
    print("+ " + " ".join(command), flush=True)
    with (directory / "collector.log").open("w+") as log:
        process = subprocess.Popen(command, env=env, stdout=log, stderr=log)
        try:
            resources = []
            for case, attributes in {
                "full": {"deployment.environment.name": "wrong", "service.name": "fixture-service",
                         "service.version": "v1", "k8s.namespace.name": "otel-demo-dev",
                         "unrelated.resource": "must-not-copy"},
                "missing_version": {"service.name": "fixture-infra",
                                    "k8s.namespace.name": "otel-demo-dev"},
                "missing_optional": {},
            }.items():
                resources.append({
                    "resource": {"attributes": [{"key": key, "value": {"stringValue": value}}
                                                 for key, value in attributes.items()]},
                    "scopeMetrics": [{"metrics": [{"name": "p106_fixture", "gauge": {
                        "dataPoints": [{"asDouble": 7, "timeUnixNano": str(time.time_ns()),
                                        "attributes": [{"key": "fixture_case", "value": {"stringValue": case}},
                                                       {"key": "existing_label", "value": {"stringValue": "kept"}}]}]
                    }}]}],
                })
            request = urllib.request.Request(f"http://127.0.0.1:{otlp_port}/v1/metrics",
                data=json.dumps({"resourceMetrics": resources}).encode(),
                headers={"Content-Type": "application/json"})
            deadline = time.monotonic() + 15
            while True:
                check(process.poll() is None, "fixture Collector exited during startup")
                try:
                    with urllib.request.urlopen(request, timeout=2) as response:
                        result = json.load(response)
                    check(not result.get("partialSuccess"), f"OTLP partial rejection: {result}")
                    break
                except urllib.error.URLError:
                    check(time.monotonic() < deadline, "fixture OTLP startup timed out")
                    time.sleep(0.1)
            with urllib.request.urlopen("http://127.0.0.1:8889/metrics", timeout=3) as response:
                metrics = response.read().decode()
            samples = [line for line in metrics.splitlines() if line.startswith("p106_fixture{")]
            check(len(samples) == 3, f"expected three metric samples: {metrics}")
            for line in samples:
                labels = dict(re.findall(r'(\w+)="([^"]*)"', line))
                check(labels.get("environment") == "dev", f"environment upsert lost: {line}")
                check(labels.get("existing_label") == "kept", f"datapoint attribute lost: {line}")
                check("unrelated_resource" not in labels and "must-not-copy" not in line,
                      f"unselected resource copied onto sample: {line}")
                case = labels["fixture_case"]
                if case == "full":
                    check(all(labels.get(k) == v for k, v in {
                        "service_name": "fixture-service", "service_version": "v1",
                        "k8s_namespace_name": "otel-demo-dev"}.items()), f"selected labels missing: {line}")
                else:
                    check("service_version" not in labels, f"missing version fabricated: {line}")
                    if case == "missing_optional":
                        check(not any(k in labels for k in ("service_name", "k8s_namespace_name")),
                              f"missing optional labels fabricated: {line}")
                    else:
                        check(labels.get("service_name") == "fixture-infra"
                              and labels.get("k8s_namespace_name") == "otel-demo-dev",
                              f"infrastructure labels missing: {line}")
            print("PASS: real OTLP → :8889 samples: selected labels, existing attributes, missing attributes", flush=True)
        except Exception:
            log.flush()
            log.seek(0)
            print(log.read(), file=sys.stderr)
            raise
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


try:
    if collector:
        check("version 0.135.0" in run([collector, "--version"]), "requires Collector Contrib 0.135.0")
    with tempfile.TemporaryDirectory(prefix="prometheus-exporter-") as temporary:
        directory = Path(temporary)
        for environment in ("dev", "staging", "prod"):
            output = run(["kubectl", "kustomize", str(root / "apps/opentelemetry-demo/overlays" / environment)])
            config = verify([d for d in yaml.safe_load_all(output) if d], environment)
            if collector:
                path = directory / f"{environment}-relay.yaml"
                path.write_text(yaml.safe_dump(config))
                run([collector, "validate", "--config", str(path)], env={
                    **os.environ, "MY_POD_IP": "127.0.0.1", "DEPLOYMENT_ENVIRONMENT": environment})
        if collector:
            fixture(config, directory)
        else:
            print("SKIP: Collector validation and metric fixture (set OTELCOL to Contrib 0.135.0)")
except (AssertionError, KeyError, TypeError, OSError, ValueError) as error:
    raise SystemExit(f"FAIL: {error}")
PY
