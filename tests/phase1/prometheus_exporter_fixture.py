"""Synthetic, localhost-only OTLP fixtures for the pinned Collector exporter.

HTTP inputs exercise representative attribute shapes, not captured production
telemetry. Spanmetrics inputs are real spans processed by the actual connector.
"""

import copy
import json
import math
import os
import re
import socket
import subprocess
import time
import urllib.error
import urllib.request

import yaml


HTTP_FAMILIES = {
    "http.server.request.duration": ("http_server_request_duration_seconds", "s", 0.25),
    "http.server.active_requests": ("http_server_active_requests", "", None),
    "http.server.response.body.size": ("http_server_response_body_size_bytes", "By", 250),
}
CALLS = "traces_span_metrics_calls_total"
DURATION = "traces_span_metrics_duration_milliseconds"
LABEL = re.compile(r'([a-zA-Z_][a-zA-Z0-9_]*)="((?:[^"\\]|\\.)*)"')


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def attributes(values):
    return [{"key": key, "value": {"intValue": str(value)} if isinstance(value, int)
             else {"stringValue": value}} for key, value in values.items()]


def metric(name, point_attributes, unit="", total=None):
    now = time.time_ns()
    point = {"attributes": attributes(point_attributes), "timeUnixNano": str(now)}
    result = {"name": name, "unit": unit, "description": "P1-06A synthetic fixture"}
    if total is None:
        point["asDouble"] = 3
        result["gauge"] = {"dataPoints": [point]}
    else:
        point.update({"startTimeUnixNano": str(now - 1_000_000_000), "count": "2",
                      "sum": total, "explicitBounds": [0.1 if unit == "s" else 100],
                      "bucketCounts": ["1", "1"]})
        result["histogram"] = {"aggregationTemporality": 2, "dataPoints": [point]}
    return result


def resource_metrics(resource, metrics):
    return {"resource": {"attributes": attributes(resource)}, "scopeMetrics": [{
        "scope": {"name": "p106a.synthetic", "version": "1"}, "metrics": metrics}]}


def base_resource(environment):
    return {"service.name": "resource-service", "service.namespace": "fixture",
            "service.instance.id": "synthetic-instance", "service.version": "resource-v1",
            "k8s.namespace.name": f"otel-demo-{environment}",
            "deployment.environment.name": "wrong-resource-environment",
            "unrelated.resource": "must-not-promote"}


def positive_payload(environment):
    # Existing datapoint service identity wins, including when resource values differ.
    cases = [
        ("resource_only", {}, "resource-service", "resource-service"),
        ("dotted", {"service.name": "point-dot"}, "resource-service", "point-dot"),
        ("underscore", {"service_name": "point-underscore"}, "resource-service", "point-underscore"),
        ("dotted_equal", {"service.name": "resource-service"}, "resource-service", "resource-service"),
        ("underscore_equal", {"service_name": "resource-service"}, "resource-service", "resource-service"),
        ("hyphen", {"service-name": "point-hyphen"}, "resource-service", "point-hyphen"),
        ("space", {"service name": "point-space"}, "resource-service", "point-space"),
        ("slash", {"service/name": "point-slash"}, "resource-service", "point-slash"),
        ("colon", {"service:name": "point-colon"}, "resource-service", "point-colon"),
        ("unicode", {"service💡name": "point-unicode"}, "resource-service", "point-unicode"),
        ("two_separators", {"service..name": "distinct-label"}, "resource-service", "resource-service"),
        ("missing", {}, None, None),
        ("empty", {}, "", None),
        ("blank", {}, " \t ", None),
        ("non_string", {}, 42, None),
        ("point_without_resource", {"service.name": "point-only"}, None, "point-only"),
        ("optional_dotted", {"service.version": "point-v1", "k8s.namespace.name": "point-ns"},
         "resource-service", "resource-service"),
        ("optional_underscore", {"service_version": "point-v2", "k8s_namespace_name": "point-ns2"},
         "resource-service", "resource-service"),
    ]
    resources, expected, preserved = [], {}, set()
    for case, incoming, resource_service, service in cases:
        for env_case, incoming_env in (("missing", None), ("matching", environment),
                                       ("conflicting", "wrong-point-environment")):
            identity = f"{case}_{env_case}"
            resource = base_resource(environment)
            if resource_service is None:
                resource.pop("service.name")
            else:
                resource["service.name"] = resource_service
            point = {"fixture_case": identity, "existing_label": "kept",
                     "http.request.method": "GET", "url.scheme": "http", **incoming}
            if incoming_env is not None:
                point["environment"] = incoming_env
            expected[identity] = (service, incoming)
            preserved.update((key, value) for key, value in incoming.items())
            resources.append(resource_metrics(resource, [
                metric(name, point, unit, total)
                for name, (_, unit, total) in HTTP_FAMILIES.items()]))
    return {"resourceMetrics": resources}, expected, preserved


def trace_payload(environment):
    resource = {**base_resource(environment), "service.name": "trace-service"}
    end = time.time_ns()
    return {"resourceSpans": [{"resource": {"attributes": attributes(resource)},
        "scopeSpans": [{"scope": {"name": "p106a.trace"}, "spans": [{
            "traceId": "0123456789abcdef0123456789abcdef", "spanId": "0123456789abcdef",
            "name": "GET /api/products/123?synthetic=true", "kind": 2,
            "startTimeUnixNano": str(end - 50_000_000), "endTimeUnixNano": str(end),
            "status": {"code": 1}}]}]}]}


def parse_samples(body):
    samples = []
    for line in body.splitlines():
        if not line or line.startswith("#"):
            continue
        match = re.fullmatch(r'([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{(.*)\})?\s+(\S+)(?:\s+\S+)?', line)
        check(match is not None, f"unparseable sample: {line}")
        name, encoded, value = match.groups()
        pairs = LABEL.findall(encoded or "")
        check(len({key for key, _ in pairs}) == len(pairs), f"duplicate labels: {line}")
        # Prometheus label values may contain literal tabs (the blank resource
        # identity fixture exercises this in target_info); JSON's default parser
        # rejects them even though the exposition's quoting is valid.
        labels = {key: json.loads('"' + value + '"', strict=False) for key, value in pairs}
        samples.append((name, labels, float(value)))
    return samples


def select(samples, name, **labels):
    return [sample for sample in samples if sample[0] == name
            and all(sample[1].get(key) == value for key, value in labels.items())]


def one_value(samples, name, value, **labels):
    found = select(samples, name, **labels)
    check(len(found) == 1 and math.isclose(found[0][2], value, abs_tol=1e-9),
          f"expected one {name}{labels} = {value}, found {found}")
    return found[0][1]


def verify_positive(samples, environment, expected):
    application = [sample for sample in samples if sample[0] != "target_info"]
    # Each of 54 cases emits two four-series histograms and one gauge. The
    # connector emits one calls counter and its default duration histogram.
    http_samples = [s for s in application if "fixture_case" in s[1]]
    check(len(http_samples) == len(expected) * 9, "missing or extra HTTP samples")
    for _, labels, _ in application:
        check(labels.get("environment") == environment, f"wrong environment: {labels}")
        check(not any("existing_service_name_aliases" in key for key in labels), "OTTL cache leaked")
        check("unrelated_resource" not in labels, "unselected resource promoted")
    for identity, (service, incoming) in expected.items():
        for name, (_, _, total) in HTTP_FAMILIES.items():
            family = HTTP_FAMILIES[name][0]
            selector = {"fixture_case": identity}
            if total is None:
                labels = one_value(samples, family, 3, **selector)
            else:
                labels = one_value(samples, family + "_count", 2, **selector)
                one_value(samples, family + "_sum", total, **selector)
                one_value(samples, family + "_bucket", 2, le="+Inf", **selector)
                one_value(samples, family + "_bucket", 1,
                          le="0.1" if name.endswith("duration") else "100", **selector)
            check(labels.get("service_name") == service, f"service identity changed: {labels}")
            check(labels.get("existing_label") == "kept" and labels.get("http_request_method") == "GET"
                  and labels.get("url_scheme") == "http", f"original attributes lost: {labels}")
            for dotted, normalized in (("service.version", "service_version"),
                                       ("k8s.namespace.name", "k8s_namespace_name")):
                check(labels.get(normalized) == incoming.get(dotted, incoming.get(normalized)),
                      f"optional attribute changed/promoted: {labels}")
            if "service..name" in incoming:
                check(labels.get("service__name") == "distinct-label", "distinct alias lost")
    span_labels = one_value(samples, CALLS, 1, service_name="trace-service")
    check(span_labels.get("span_name") == "GET /api/products/{productId}", "trace transform changed")
    one_value(samples, DURATION + "_count", 1, service_name="trace-service")
    one_value(samples, DURATION + "_sum", 50, service_name="trace-service")
    buckets = select(samples, DURATION + "_bucket", service_name="trace-service")
    bounds = ("2", "4", "6", "8", "10", "50", "100", "200", "400", "800", "1000",
              "1400", "2000", "5000", "10000", "15000", "+Inf")
    check(len(buckets) == len(bounds), "spanmetrics duration buckets missing/duplicated")
    for bound in bounds:
        one_value(samples, DURATION + "_bucket", int(float(bound) >= 50),
                  service_name="trace-service", le=bound)
    check(len(application) == len(expected) * 9 + 20, "unexpected application series count")
    check(not any("service_version" in labels or "k8s_namespace_name" in labels
                  for _, labels, _ in application if "fixture_case" not in labels),
          "spanmetrics optional resource labels promoted")
    metadata = select(samples, "target_info", job="fixture/resource-service",
                      instance="synthetic-instance")
    check(metadata and all(s[1].get("service_version") == "resource-v1"
                           and s[1].get("k8s_namespace_name") == f"otel-demo-{environment}"
                           and s[1].get("deployment_environment_name") == environment
                           for s in metadata), "resource metadata missing from target_info")


def negative_payload():
    # Deliberately invalid upstream inputs. Never mix with positive runs: the
    # exporter rejects these despite HTTP 200, independently of enrichment.
    metrics, names, preserved = [], [], set()
    for tag, dotted, underscored in (("service", "service.name", "service_name"),
                                    ("version", "service.version", "service_version"),
                                    ("namespace", "k8s.namespace.name", "k8s_namespace_name")):
        for mode in ("equal", "different"):
            name = f"p106a_upstream_{tag}_{mode}"
            incoming = {dotted: f"{tag}-dot", underscored: f"{tag}-dot" if mode == "equal"
                        else f"{tag}-underscore"}
            metrics.append(metric(name, incoming))
            names.append(name)
            preserved.update(incoming.items())
    metrics.append(metric("p106a_negative_control", {}))
    return {"resourceMetrics": [resource_metrics(base_resource("dev"), metrics)]}, names, preserved


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def post(port, path, payload):
    request = urllib.request.Request(f"http://127.0.0.1:{port}{path}",
        data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=2) as response:
        result = json.load(response)
    check(not result.get("partialSuccess"), f"OTLP partial rejection: {result}")


def run_fixture(config, directory, collector, environment, negative=False):
    otlp_port, prom_port = free_port(), free_port()
    while prom_port == otlp_port:
        prom_port = free_port()
    mode = "upstream-negative" if negative else environment
    isolated = {
        "connectors": {"spanmetrics": {**copy.deepcopy(config["connectors"]["spanmetrics"]),
                                       "metrics_flush_interval": "500ms"}},
        "receivers": {"otlp": {"protocols": {"http": {"endpoint": f"127.0.0.1:{otlp_port}"}}}},
        "processors": {key: copy.deepcopy(config["processors"][key])
                       for key in ("resource/environment", "transform/metric-labels", "transform")},
        "exporters": {"debug": {"verbosity": "detailed", "sampling_initial": 1000},
                      "prometheus": {**config["exporters"]["prometheus"],
                                     "endpoint": f"127.0.0.1:{prom_port}"}},
        "service": {"telemetry": {"metrics": {"level": "none"}}, "pipelines": {
            "traces": {"receivers": ["otlp"], "processors": ["transform", "resource/environment"],
                       "exporters": ["spanmetrics"]},
            "metrics": {"receivers": ["otlp", "spanmetrics"],
                        "processors": ["resource/environment", "transform/metric-labels"],
                        "exporters": ["debug", "prometheus"]}}},
    }
    path, logfile = directory / f"{mode}-fixture.yaml", directory / f"{mode}-collector.log"
    path.write_text(yaml.safe_dump(isolated))
    command = [collector, "--config", str(path)]
    print("+ " + " ".join(command), flush=True)
    with logfile.open("w+") as log:
        process = subprocess.Popen(command, env={**os.environ, "DEPLOYMENT_ENVIRONMENT": environment},
                                   stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 15
            while True:
                check(process.poll() is None, f"{mode}: Collector exited during startup")
                try:
                    post(otlp_port, "/v1/metrics", {"resourceMetrics": []})
                    break
                except urllib.error.URLError:
                    check(time.monotonic() < deadline, f"{mode}: startup timeout")
                    time.sleep(0.1)
            payload, expected, preserved = negative_payload() if negative else positive_payload(environment)
            post(otlp_port, "/v1/metrics", payload)
            if not negative:
                post(otlp_port, "/v1/traces", trace_payload(environment))
            deadline = time.monotonic() + 15
            while True:
                check(process.poll() is None, f"{mode}: Collector exited before scrape")
                try:
                    with urllib.request.urlopen(f"http://127.0.0.1:{prom_port}/metrics", timeout=2) as response:
                        check(response.status == 200, "scrape failed")
                        samples = parse_samples(response.read().decode())
                    if negative:
                        one_value(samples, "p106a_negative_control", 3)
                        check(not any(select(samples, name) for name in expected),
                              "upstream collisions unexpectedly exported; review pinned behavior")
                    else:
                        verify_positive(samples, environment, expected)
                    break
                except (AssertionError, urllib.error.URLError) as error:
                    if time.monotonic() >= deadline:
                        raise AssertionError(f"{mode}: samples incomplete/incorrect: {error}") from error
                    time.sleep(0.1)
        except Exception:
            log.flush()
            log.seek(0)
            print(log.read()[-12000:], flush=True)
            raise
        finally:
            process.terminate()
            try:
                code = process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
                raise AssertionError(f"{mode}: Collector did not shut down gracefully")
            print(f"{mode}: Collector exit {code}", flush=True)
        check(code == 0, f"{mode}: Collector shutdown failed")
        log.seek(0)
        output = log.read()
    # Debug export contains only generated fixtures, never real application data.
    for key, value in preserved:
        check(f"-> {key}: Str({value})" in output, f"incoming key/value changed: {key}={value}")
    if negative:
        for name in expected:
            check(f"failed to convert metric {name}: duplicate label names in constant and variable labels"
                  in output, f"missing explicit upstream rejection: {name}")
        print(f"PASS: upstream-only negative control: HTTP 200, {len(expected)} rejected families, "
              "exact duplicate-label errors, original attributes preserved", flush=True)
    else:
        check(not re.search(r"\t(?:error|fatal)\t|failed to (?:convert|execute)|duplicate label", output, re.I),
              f"{mode}: unexpected exporter/transform error: {output[-12000:]}")
        print(f"PASS: {environment}: {len(expected)} cases × 3 HTTP families = "
              f"{len(expected) * 9} HTTP samples + 20 real spanmetrics samples; "
              "values, labels, target_info and zero conversion errors", flush=True)
        for family in (CALLS, DURATION, *(value[0] for value in HTTP_FAMILIES.values())):
            print(f"  observed family: {family}", flush=True)


def run_fixtures(configs, directory, collector):
    for environment, config in configs.items():
        run_fixture(config, directory, collector, environment)
    run_fixture(configs["dev"], directory, collector, "dev", negative=True)
