#!/usr/bin/env -S uv run --python 3.14 --script
# /// script
# requires-python = ">=3.14"
# dependencies = ["matplotlib", "numpy"]
# ///
"""
Autoresearch + Telemetry Dashboard
===================================
Generates a multi-panel PNG correlating autoresearch experiment results with
production telemetry from the Grafana SQLite DB.

Top row: autoresearch experiment results.
Second row: Vitals Scorecard — the 5 unified metrics per build.
Bottom rows: production telemetry drill-downs.

Usage:
    ./scripts/autoresearch-dashboard.py
    ./scripts/autoresearch-dashboard.py --output /tmp/dashboard.png
    ./scripts/autoresearch-dashboard.py --telemetry-db /path/to/telemetry.db
    ./scripts/autoresearch-dashboard.py --open  # open in Preview after generating
"""

import argparse
import json
import sqlite3
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import matplotlib.pyplot as plt
import matplotlib.dates as mdates
import numpy as np

# ── Paths ──
REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_TELEMETRY_DB = Path.home() / "OrbStack/docker/containers/oppi-telemetry-grafana/var/lib/oppi-telemetry/telemetry.db"
AUTORESEARCH_JSONL = REPO_ROOT / "autoresearch.jsonl"
TIMELINE_JSONL = REPO_ROOT.parent / "oppi-autoresearch/autoresearch/timeline-lifecycle-20260320/autoresearch.jsonl"

# ── 5 Vitals ──
# Shared metric names across autoresearch benches, production telemetry, and Grafana.
VITALS = {
    "chat.session_load_ms":       {"label": "Session Load",  "unit": "ms",    "proxy": "chat.full_reload_ms"},
    "chat.ttft_ms":               {"label": "First Token",   "unit": "ms",    "proxy": None},
    "chat.jank_pct":              {"label": "Render Jank",   "unit": "%",     "proxy": "_jank_pct_derived"},
    "chat.voice_first_result_ms": {"label": "Voice",         "unit": "ms",    "proxy": None},
    "chat.catchup_ms":            {"label": "Reconnect",     "unit": "ms",    "proxy": None},
}

# ── Style ──
plt.rcParams.update({
    "figure.facecolor": "#1a1a2e",
    "axes.facecolor": "#16213e",
    "axes.edgecolor": "#444",
    "axes.labelcolor": "#ccc",
    "text.color": "#ddd",
    "xtick.color": "#999",
    "ytick.color": "#999",
    "grid.color": "#333",
    "grid.alpha": 0.5,
    "font.size": 9,
    "axes.titlesize": 11,
    "figure.titlesize": 14,
})

KEEP_COLOR = "#22C55E"
DISCARD_COLOR = "#EAB308"
CRASH_COLOR = "#EF4444"
CHECKS_FAIL_COLOR = "#F97316"
ACCENT = "#60A5FA"
ACCENT2 = "#A78BFA"
ACCENT3 = "#F472B6"
ACCENT4 = "#34D399"
VITAL_COLORS = ["#60A5FA", "#F472B6", "#FBBF24", "#34D399", "#A78BFA"]


def load_autoresearch(path: Path) -> list[dict]:
    """Load experiment runs from autoresearch.jsonl, skipping config lines."""
    runs = []
    if not path.exists():
        return runs
    with path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            data = json.loads(line)
            if data.get("type") == "config":
                continue
            runs.append(data)
    return runs


def load_telemetry_by_build(db_path: Path) -> dict:
    """Query key metrics aggregated by build_number."""
    if not db_path.exists():
        return {}

    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row

    result = {}

    # Standard per-build aggregation
    metrics_of_interest = [
        "chat.timeline_apply_ms",
        "chat.timeline_layout_ms",
        "chat.cell_configure_ms",
        "chat.ttft_ms",
        "chat.fresh_content_lag_ms",
        "chat.full_reload_ms",
        "chat.voice_prewarm_ms",
        "chat.voice_setup_ms",
        "chat.voice_first_result_ms",
        "chat.catchup_ms",
        "chat.session_load_ms",
        "chat.cache_load_ms",
        "chat.reducer_load_ms",
    ]

    for metric in metrics_of_interest:
        try:
            rows = conn.execute("""
                SELECT build_number,
                       COUNT(*) as n,
                       AVG(value) as avg_val,
                       MIN(value) as min_val,
                       MAX(value) as max_val,
                       MIN(ts_ms) as first_ts,
                       MAX(ts_ms) as last_ts
                FROM chat_metric_samples
                WHERE metric = ? AND build_number IS NOT NULL
                GROUP BY build_number
                ORDER BY MIN(ts_ms)
            """, (metric,)).fetchall()
            result[metric] = [dict(r) for r in rows]
        except Exception:
            result[metric] = []

    # Derived: jank_pct per build (% of timeline_apply_ms > 16ms, build >= 21)
    try:
        rows = conn.execute("""
            SELECT build_number,
                   COUNT(*) as n,
                   ROUND(100.0 * SUM(CASE WHEN value > 16 THEN 1 ELSE 0 END) / COUNT(*), 1) as avg_val,
                   0 as min_val,
                   100 as max_val,
                   MIN(ts_ms) as first_ts,
                   MAX(ts_ms) as last_ts
            FROM chat_metric_samples
            WHERE metric = 'chat.timeline_apply_ms'
              AND build_number IS NOT NULL
              AND build_number >= '21'
            GROUP BY build_number
            ORDER BY MIN(ts_ms)
        """).fetchall()
        result["_jank_pct_derived"] = [dict(r) for r in rows]
    except Exception:
        result["_jank_pct_derived"] = []

    # Build timeline
    try:
        rows = conn.execute("""
            SELECT build_number,
                   COUNT(*) as samples,
                   COUNT(DISTINCT metric) as metrics,
                   MIN(ts_ms) as first_ts,
                   MAX(ts_ms) as last_ts
            FROM chat_metric_samples
            WHERE build_number IS NOT NULL
            GROUP BY build_number
            ORDER BY MIN(ts_ms)
        """).fetchall()
        result["_builds"] = [dict(r) for r in rows]
    except Exception:
        result["_builds"] = []

    conn.close()
    return result


def ts_to_dt(ts_ms: int) -> datetime:
    return datetime.fromtimestamp(ts_ms / 1000, tz=timezone.utc)


# ── Plot helpers ──

def plot_autoresearch_runs(ax, runs: list[dict], title: str, metric_label: str):
    """Plot experiment runs with status coloring."""
    if not runs:
        ax.text(0.5, 0.5, "No data", ha="center", va="center", color="#666")
        ax.set_title(title)
        return

    x = [r["run"] for r in runs]
    y = [r["metric"] for r in runs]
    colors = []
    for r in runs:
        status = r.get("status", "")
        if status == "keep":
            colors.append(KEEP_COLOR)
        elif status == "crash":
            colors.append(CRASH_COLOR)
        elif status == "checks_failed":
            colors.append(CHECKS_FAIL_COLOR)
        else:
            colors.append(DISCARD_COLOR)

    ax.scatter(x, y, c=colors, s=50, zorder=3, edgecolors="white", linewidth=0.5)

    # Connect kept runs with a line
    kept_x = [r["run"] for r in runs if r["status"] == "keep"]
    kept_y = [r["metric"] for r in runs if r["status"] == "keep"]
    if len(kept_x) > 1:
        ax.plot(kept_x, kept_y, color=KEEP_COLOR, alpha=0.4, linewidth=1.5, linestyle="--")

    # Baseline and best annotations
    if kept_y:
        baseline = kept_y[0]
        best = min(kept_y)
        improvement = (1 - best / baseline) * 100
        ax.axhline(y=baseline, color="#666", linestyle=":", alpha=0.5, linewidth=0.8)
        ax.annotate(f"baseline: {baseline:.1f}", xy=(kept_x[0], baseline),
                    xytext=(5, 8), textcoords="offset points", fontsize=7, color="#999")
        if best < baseline:
            best_idx = kept_y.index(best)
            ax.annotate(f"best: {best:.1f} (-{improvement:.1f}%)",
                        xy=(kept_x[best_idx], best),
                        xytext=(5, -12), textcoords="offset points",
                        fontsize=7, color=KEEP_COLOR, fontweight="bold")

    ax.set_xlabel("Run")
    ax.set_ylabel(metric_label)
    ax.set_title(title)
    ax.grid(True, alpha=0.3)

    from matplotlib.lines import Line2D
    legend_items = [
        Line2D([0], [0], marker="o", color="w", markerfacecolor=KEEP_COLOR, markersize=6, label="keep"),
        Line2D([0], [0], marker="o", color="w", markerfacecolor=DISCARD_COLOR, markersize=6, label="discard"),
        Line2D([0], [0], marker="o", color="w", markerfacecolor=CHECKS_FAIL_COLOR, markersize=6, label="checks_failed"),
    ]
    ax.legend(handles=legend_items, fontsize=7, loc="upper right", framealpha=0.3)


def plot_metric_by_build(ax, data: list[dict], title: str, ylabel: str, color: str = ACCENT):
    """Bar chart of a metric's average per build."""
    if not data:
        ax.text(0.5, 0.5, "No data", ha="center", va="center", color="#666")
        ax.set_title(title)
        return

    builds = [str(d["build_number"]) for d in data]
    avgs = [d["avg_val"] for d in data]
    counts = [d["n"] for d in data]

    bars = ax.bar(builds, avgs, color=color, alpha=0.8, edgecolor="white", linewidth=0.3)

    for bar, count in zip(bars, counts):
        ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height(),
                f"n={count:,}", ha="center", va="bottom", fontsize=6, color="#888")

    ax.set_xlabel("Build")
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.grid(True, axis="y", alpha=0.3)


def plot_timeline_secondary(ax, runs: list[dict]):
    """Plot secondary metrics from timeline lifecycle autoresearch."""
    if not runs:
        ax.text(0.5, 0.5, "No data", ha="center", va="center", color="#666")
        ax.set_title("Timeline Lifecycle — Secondary Metrics")
        return

    kept = [r for r in runs if r["status"] == "keep"]
    if not kept:
        return

    x = [r["run"] for r in kept]
    metrics_to_plot = {
        "streaming_max_us": (ACCENT, "stream_max"),
        "insert_total_us": (ACCENT2, "insert"),
        "end_settle_us": (ACCENT3, "end_settle"),
    }

    for metric_key, (color, label) in metrics_to_plot.items():
        y = [r["metrics"].get(metric_key, 0) for r in kept]
        y_ms = [v / 1000 for v in y]
        ax.plot(x, y_ms, marker="o", color=color, markersize=4, linewidth=1.2, label=label)

    ax.set_xlabel("Run (kept only)")
    ax.set_ylabel("ms")
    ax.set_title("Timeline Lifecycle — Component Breakdown")
    ax.legend(fontsize=7, loc="upper right", framealpha=0.3)
    ax.grid(True, alpha=0.3)


def plot_vitals_scorecard(axes_row, telemetry: dict):
    """Plot the 5 vitals as individual bar charts in a row of 3 axes.

    axes_row: list of 3 axes.
    - Left: Session Load + First Token (grouped bar, ms)
    - Center: Render Jank (bar, %)
    - Right: Voice + Reconnect (grouped bar, ms)
    """

    # Resolve vital data (using proxies where needed)
    def get_vital_data(vital_name):
        info = VITALS[vital_name]
        source = info["proxy"] if info["proxy"] else vital_name
        return telemetry.get(source, [])

    # Left: Session Load + First Token
    ax = axes_row[0]
    sl_data = get_vital_data("chat.session_load_ms")
    ttft_data = get_vital_data("chat.ttft_ms")
    _plot_grouped_vital_bars(ax, [
        ("Session Load", sl_data, VITAL_COLORS[0]),
        ("First Token", ttft_data, VITAL_COLORS[1]),
    ], "Vitals: Session Load + First Token", "avg ms")

    # Center: Render Jank
    ax = axes_row[1]
    jank_data = get_vital_data("chat.jank_pct")
    if jank_data:
        builds = [str(d["build_number"]) for d in jank_data]
        vals = [d["avg_val"] for d in jank_data]
        counts = [d["n"] for d in jank_data]
        bars = ax.bar(builds, vals, color=VITAL_COLORS[2], alpha=0.8, edgecolor="white", linewidth=0.3)
        for bar, count in zip(bars, counts):
            ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height(),
                    f"n={count:,}", ha="center", va="bottom", fontsize=6, color="#888")
    else:
        ax.text(0.5, 0.5, "No data", ha="center", va="center", color="#666")
    ax.set_xlabel("Build")
    ax.set_ylabel("jank %")
    ax.set_title("Vital: Render Jank (chat.jank_pct)")
    ax.grid(True, axis="y", alpha=0.3)

    # Right: Voice + Reconnect
    ax = axes_row[2]
    voice_data = get_vital_data("chat.voice_first_result_ms")
    catchup_data = get_vital_data("chat.catchup_ms")
    _plot_grouped_vital_bars(ax, [
        ("Voice", voice_data, VITAL_COLORS[3]),
        ("Reconnect", catchup_data, VITAL_COLORS[4]),
    ], "Vitals: Voice + Reconnect", "avg ms")


def _plot_grouped_vital_bars(ax, series_list, title, ylabel):
    """Draw grouped bars for multiple vitals sharing an axis.

    series_list: [(label, data, color), ...]
    """
    # Collect all builds across series
    all_builds = []
    for _, data, _ in series_list:
        for d in data:
            b = str(d["build_number"])
            if b not in all_builds:
                all_builds.append(b)

    if not all_builds:
        ax.text(0.5, 0.5, "No data", ha="center", va="center", color="#666")
        ax.set_title(title)
        return

    x = np.arange(len(all_builds))
    n_series = len(series_list)
    width = 0.8 / n_series

    for i, (label, data, color) in enumerate(series_list):
        lookup = {str(d["build_number"]): d["avg_val"] for d in data}
        vals = [lookup.get(b, 0) for b in all_builds]
        offset = (i - (n_series - 1) / 2) * width
        ax.bar(x + offset, vals, width, label=label, color=color, alpha=0.8, edgecolor="white", linewidth=0.3)

    ax.set_xticks(x)
    ax.set_xticklabels(all_builds)
    ax.set_xlabel("Build")
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.legend(fontsize=7, loc="upper right", framealpha=0.3)
    ax.grid(True, axis="y", alpha=0.3)


def plot_build_sample_volume(ax, builds: list[dict]):
    """Show telemetry sample volume per build."""
    if not builds:
        ax.text(0.5, 0.5, "No data", ha="center", va="center", color="#666")
        ax.set_title("Telemetry Volume by Build")
        return

    names = [str(b["build_number"]) for b in builds]
    samples = [b["samples"] for b in builds]
    metrics_count = [b["metrics"] for b in builds]

    bars = ax.bar(names, samples, color=ACCENT4, alpha=0.8, edgecolor="white", linewidth=0.3)

    for bar, mc in zip(bars, metrics_count):
        ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height(),
                f"{mc} metrics", ha="center", va="bottom", fontsize=6, color="#888")

    ax.set_xlabel("Build")
    ax.set_ylabel("Total Samples")
    ax.set_title("Telemetry Volume by Build")
    ax.grid(True, axis="y", alpha=0.3)


def plot_connection_stack(ax, telemetry: dict):
    """Stacked bar of connection phase latencies by build (without stream_open_ms)."""
    phases = [
        ("chat.subscribe_ack_ms", "subscribe_ack", "#A78BFA"),
        ("chat.ttft_ms", "ttft", "#F472B6"),
    ]

    builds = set()
    for metric, _, _ in phases:
        for d in telemetry.get(metric, []):
            builds.add(str(d["build_number"]))

    if not builds:
        ax.text(0.5, 0.5, "No data", ha="center", va="center", color="#666")
        ax.set_title("Connection Latency Stack")
        return

    builds = sorted(builds)
    x = np.arange(len(builds))
    width = 0.6

    bottom = np.zeros(len(builds))
    for metric, label, color in phases:
        metric_data = {str(d["build_number"]): d["avg_val"] for d in telemetry.get(metric, [])}
        vals = [metric_data.get(b, 0) for b in builds]
        if "ttft" in label:
            vals = [min(v, 15000) for v in vals]
        ax.bar(x, vals, width, bottom=bottom, label=label, color=color, alpha=0.8, edgecolor="white", linewidth=0.3)
        bottom += np.array(vals)

    ax.set_xticks(x)
    ax.set_xticklabels(builds)
    ax.set_xlabel("Build")
    ax.set_ylabel("ms (TTFT capped at 15s)")
    ax.set_title("Connection → First Token (chat.ttft_ms)")
    ax.legend(fontsize=7, loc="upper right", framealpha=0.3)
    ax.grid(True, axis="y", alpha=0.3)


def plot_render_perf_trend(ax, telemetry: dict):
    """Line chart of render pipeline metrics across builds."""
    metrics = [
        ("chat.timeline_apply_ms", "timeline_apply", ACCENT),
        ("chat.timeline_layout_ms", "timeline_layout", ACCENT2),
        ("chat.cell_configure_ms", "cell_configure", ACCENT3),
    ]

    for metric, label, color in metrics:
        data = telemetry.get(metric, [])
        if not data:
            continue
        builds = [str(d["build_number"]) for d in data]
        avgs = [d["avg_val"] for d in data]
        ax.plot(builds, avgs, marker="o", color=color, markersize=5, linewidth=1.5, label=label)

    ax.set_xlabel("Build")
    ax.set_ylabel("avg ms")
    ax.set_title("Render Pipeline — Jank Drill-down (chat.jank_pct)")
    ax.legend(fontsize=7, loc="upper right", framealpha=0.3)
    ax.grid(True, alpha=0.3)


def plot_session_load_pipeline(ax, telemetry: dict):
    """Session load pipeline components by build."""
    components = [
        ("chat.full_reload_ms", "full_reload", "#EF4444"),
        ("chat.cache_load_ms", "cache_load", KEEP_COLOR),
        ("chat.reducer_load_ms", "reducer_load", "#F97316"),
    ]

    for metric, label, color in components:
        data = telemetry.get(metric, [])
        if not data:
            continue
        builds = [str(d["build_number"]) for d in data]
        avgs = [d["avg_val"] for d in data]
        ax.plot(builds, avgs, marker="o", color=color, markersize=5, linewidth=1.5, label=label)

    ax.set_xlabel("Build")
    ax.set_ylabel("avg ms")
    ax.set_title("Session Load Pipeline (chat.session_load_ms)")
    ax.legend(fontsize=7, loc="upper right", framealpha=0.3)
    ax.grid(True, alpha=0.3)


def main():
    parser = argparse.ArgumentParser(description="Autoresearch + Telemetry Dashboard")
    parser.add_argument("--output", default=str(REPO_ROOT / "autoresearch-dashboard.png"),
                        help="Output PNG path")
    parser.add_argument("--telemetry-db", default=str(DEFAULT_TELEMETRY_DB),
                        help="Path to telemetry SQLite DB")
    parser.add_argument("--open", action="store_true", help="Open in Preview after generating")
    args = parser.parse_args()

    # Load data
    gol_runs = load_autoresearch(AUTORESEARCH_JSONL)
    timeline_runs = load_autoresearch(TIMELINE_JSONL)
    telemetry = load_telemetry_by_build(Path(args.telemetry_db))

    # Build 4x3 dashboard (expanded from 3x3 with vitals scorecard row)
    fig, axes = plt.subplots(4, 3, figsize=(18, 18))
    fig.suptitle("Oppi Metrics Dashboard — 5 Vitals + Autoresearch + Telemetry", fontweight="bold", y=0.98)

    # Row 1: Autoresearch experiment results
    plot_autoresearch_runs(axes[0, 0], gol_runs, "Game of Life Indicator", "composite score")
    plot_autoresearch_runs(axes[0, 1], timeline_runs, "Timeline Lifecycle", "lifecycle_score")
    plot_timeline_secondary(axes[0, 2], timeline_runs)

    # Row 2: Vitals Scorecard (NEW)
    plot_vitals_scorecard([axes[1, 0], axes[1, 1], axes[1, 2]], telemetry)

    # Row 3: Production telemetry drill-downs
    plot_render_perf_trend(axes[2, 0], telemetry)
    plot_metric_by_build(axes[2, 1], telemetry.get("chat.ttft_ms", []),
                         "First Token by Build (chat.ttft_ms)", "ms", ACCENT3)
    plot_connection_stack(axes[2, 2], telemetry)

    # Row 4: Supporting metrics
    plot_session_load_pipeline(axes[3, 0], telemetry)
    plot_metric_by_build(axes[3, 1], telemetry.get("chat.fresh_content_lag_ms", []),
                         "Fresh Content Lag by Build", "ms", ACCENT2)
    plot_build_sample_volume(axes[3, 2], telemetry.get("_builds", []))

    fig.tight_layout(rect=[0, 0, 1, 0.96])

    output = Path(args.output)
    fig.savefig(output, dpi=150, bbox_inches="tight")
    plt.close()

    print(f"Dashboard saved to {output}")
    print(f"  autoresearch (GoL): {len(gol_runs)} runs")
    print(f"  autoresearch (timeline): {len(timeline_runs)} runs")
    print(f"  telemetry builds: {len(telemetry.get('_builds', []))}")
    print(f"  vitals tracked: {len(VITALS)}")

    if args.open:
        subprocess.run(["open", str(output)])


if __name__ == "__main__":
    main()
