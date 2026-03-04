#!/usr/bin/env -S uv run --python 3.14 --script

import argparse
import json
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

CORE_METRICS = [
    "chat.timeline_apply_ms",
    "chat.timeline_layout_ms",
    "chat.cell_configure_ms",
    "chat.inbound_queue_depth",
    "chat.coalescer_flush_events",
    "chat.coalescer_flush_bytes",
]
TIMELINE_SIZE_BUCKET_ORDER = ["0-20", "21-50", "51-80", "81-120", "121+", "unknown"]


def percentile(values: list[float], p: int) -> float | None:
    if not values:
        return None
    sorted_values = sorted(values)
    idx = int((len(sorted_values) - 1) * (p / 100))
    return sorted_values[idx]


def fmt(value: float | int | None) -> str:
    if value is None:
        return "-"
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return f"{value:.2f}" if isinstance(value, float) else str(value)


def load_samples(path: Path) -> list[dict[str, Any]]:
    samples: list[dict[str, Any]] = []
    with path.open(encoding="utf-8") as f:
        for line in f:
            payload = json.loads(line)
            for sample in payload.get("samples", []):
                samples.append(sample)
    return samples


def parse_int_tag(value: Any) -> int | None:
    text = str(value)
    if text.lstrip("-").isdigit():
        return int(text)
    return None


def bucket_for_item_count(items: int | None) -> str:
    if items is None or items < 0:
        return "unknown"
    if items <= 20:
        return "0-20"
    if items <= 50:
        return "21-50"
    if items <= 80:
        return "51-80"
    if items <= 120:
        return "81-120"
    return "121+"


def scorecard(samples: list[dict[str, Any]]) -> str:
    metric_values: dict[str, list[float]] = defaultdict(list)
    metric_tags: dict[str, dict[str, Counter[str]]] = defaultdict(
        lambda: defaultdict(Counter)
    )

    for sample in samples:
        metric = sample.get("metric")
        if not isinstance(metric, str):
            continue

        value = sample.get("value")
        if isinstance(value, (int, float)):
            metric_values[metric].append(float(value))

        tags = sample.get("tags")
        if not isinstance(tags, dict):
            continue

        for key, tag_value in tags.items():
            metric_tags[metric][str(key)][str(tag_value)] += 1

    lines: list[str] = []
    lines.append("Chat render performance scorecard")
    lines.append("=" * 34)

    lines.append("\nCore render metrics")
    lines.append("metric                       n      p50    p95    max")
    lines.append("------------------------------------------------------")
    for metric in CORE_METRICS:
        values = metric_values.get(metric, [])
        lines.append(
            f"{metric:27s} {len(values):6d} {fmt(percentile(values, 50)):>6s} {fmt(percentile(values, 95)):>6s} {fmt(max(values) if values else None):>6s}"
        )

    apply_values = metric_values.get("chat.timeline_apply_ms", [])
    layout_values = metric_values.get("chat.timeline_layout_ms", [])
    pair_count = min(len(apply_values), len(layout_values))
    over_16 = 0
    over_33 = 0
    for idx in range(pair_count):
        total = apply_values[idx] + layout_values[idx]
        if total > 16:
            over_16 += 1
        if total > 33:
            over_33 += 1

    lines.append("\nFrame budget pressure")
    lines.append(f"paired apply+layout samples: {pair_count}")
    if pair_count > 0:
        lines.append(f">16ms: {over_16} ({(over_16 / pair_count) * 100:.2f}%)")
        lines.append(f">33ms: {over_33} ({(over_33 / pair_count) * 100:.2f}%)")

    changed_groups: dict[str, list[float]] = defaultdict(list)
    items_groups: dict[str, list[float]] = defaultdict(list)
    for sample in samples:
        if sample.get("metric") != "chat.timeline_apply_ms":
            continue

        value = sample.get("value")
        if not isinstance(value, (int, float)):
            continue

        tags = sample.get("tags")
        if not isinstance(tags, dict):
            tags = {}

        changed_groups[str(tags.get("changed", "?"))].append(float(value))
        item_count = parse_int_tag(tags.get("items", -1))
        items_groups[bucket_for_item_count(item_count)].append(float(value))

    lines.append("\nApply cost by changed rows")
    lines.append("changed    n      p95    max")
    lines.append("----------------------------")
    for changed, values in sorted(
        changed_groups.items(), key=lambda kv: int(kv[0]) if kv[0].isdigit() else 999
    ):
        lines.append(
            f"{changed:7s} {len(values):6d} {fmt(percentile(values, 95)):>7s} {fmt(max(values) if values else None):>6s}"
        )

    lines.append("\nApply cost by timeline size")
    lines.append("items      n      p95    max")
    lines.append("----------------------------")
    for bucket in TIMELINE_SIZE_BUCKET_ORDER:
        values = items_groups.get(bucket, [])
        if not values:
            continue
        lines.append(
            f"{bucket:7s} {len(values):6d} {fmt(percentile(values, 95)):>7s} {fmt(max(values)):>6s}"
        )

    # Cell configure breakdown by content type
    cell_configure_groups: dict[str, list[float]] = defaultdict(list)
    for sample in samples:
        if sample.get("metric") != "chat.cell_configure_ms":
            continue
        value = sample.get("value")
        if not isinstance(value, (int, float)):
            continue
        tags = sample.get("tags")
        if not isinstance(tags, dict):
            tags = {}
        content_type = tags.get("content_type", "collapsed")
        expanded = tags.get("expanded", "0")
        key = f"{content_type}({'expanded' if expanded == '1' else 'collapsed'})"
        cell_configure_groups[key].append(float(value))

    if cell_configure_groups:
        lines.append("\nCell configure cost by content type")
        lines.append("content_type             n      p50    p95    max")
        lines.append("--------------------------------------------------")
        for key, values in sorted(
            cell_configure_groups.items(), key=lambda kv: max(kv[1]), reverse=True
        ):
            lines.append(
                f"{key:23s} {len(values):6d} {fmt(percentile(values, 50)):>6s} {fmt(percentile(values, 95)):>6s} {fmt(max(values)):>6s}"
            )

    lines.append("\nTop ws_decode types")
    decode_types = metric_tags.get("chat.ws_decode_ms", {}).get("type", Counter())
    if decode_types:
        for decode_type, count in decode_types.most_common(8):
            lines.append(f"{decode_type:16s} {count}")
    else:
        lines.append("-")

    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Analyze Oppi chat timeline render metrics"
    )
    parser.add_argument(
        "file",
        nargs="?",
        default="/Users/chenda/.config/oppi/diagnostics/telemetry/chat-metrics-2026-03-02.jsonl",
        help="Path to chat-metrics-YYYY-MM-DD.jsonl",
    )
    args = parser.parse_args()

    path = Path(args.file)
    if not path.exists():
        raise SystemExit(f"File not found: {path}")

    samples = load_samples(path)
    print(f"File: {path}")
    print(f"Samples: {len(samples)}")
    print()
    print(scorecard(samples))


if __name__ == "__main__":
    main()
