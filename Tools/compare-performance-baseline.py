#!/usr/bin/env python3
import json
import sys
from pathlib import Path

if len(sys.argv) != 3:
    raise SystemExit("usage: compare-performance-baseline.py <metrics.json> <baseline.json>")

metrics = json.loads(Path(sys.argv[1]).read_text())
baseline = json.loads(Path(sys.argv[2]).read_text())
failures: list[str] = []

for key in ("hardware_model", "physical_memory_bytes", "architecture"):
    if metrics.get(key) != baseline["environment"].get(key):
        failures.append(f"incomparable environment: {key}")
if metrics.get("corpus_sha256") != baseline.get("corpus_sha256"):
    failures.append("incomparable corpus_sha256")
if metrics.get("build_configuration") != "Release":
    failures.append("candidate was not measured in Release")

model_id = metrics.get("model_id")
model = baseline.get("models", {}).get(model_id)
if model is None:
    failures.append(f"no approved baseline for model {model_id}")
else:
    if metrics.get("model_version") != model.get("model_version"):
        failures.append("incomparable model_version")
    thresholds = baseline["regression_thresholds"]
    for metric_name, threshold in thresholds.items():
        approved = model.get(metric_name, baseline.get(metric_name))
        candidate = metrics.get(metric_name)
        if approved is None:
            failures.append(f"baseline is incomplete: {metric_name}")
        elif candidate is None:
            failures.append(f"candidate is incomplete: {metric_name}")
        elif candidate > approved * (1.0 + threshold):
            failures.append(
                f"{metric_name} regressed: candidate={candidate} baseline={approved} "
                f"threshold={threshold:.0%}"
            )

if failures:
    print("Performance gate failed:", file=sys.stderr)
    for failure in failures:
        print(f"- {failure}", file=sys.stderr)
    raise SystemExit(1)

print(f"Performance gate passed for {model_id}")
