#!/usr/bin/env python3
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

"""Generate ops/sec and RSS graphs from microbenchmark results (tcache-enabled).

Each graph is a 2x2 grid of subplots, one per compartment count (2, 8, 16, 64).
X-axis per subplot: allocation sizes.
Variants: Baseline, Calloc, HC-off, HC-on.
"""

import argparse
import csv
import os
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

matplotlib.rcParams["hatch.linewidth"] = 0.6

COMPS = [2, 8, 16, 64]
SIZES = [64, 256, 1024, 4096, 16384, 65536]
THREADS = [1, 4, 8]
VARIANTS = ["baseline", "calloc", "modified_disabled", "modified_enabled"]
VARIANT_LABELS = {
    "baseline": "Baseline",
    "calloc": "Calloc",
    "modified_disabled": "HC-off",
    "modified_enabled": "HC-on",
}
# Palette carried over from the Ample paper (Fig. 5): dark plum, apricot, wine.
# Teal is the added fourth — cool counterpart to the three warm tones.
VARIANT_COLORS = {
    "baseline": "#5E4C5F",
    "calloc": "#FFBB6F",
    "modified_disabled": "#219EBC",
    "modified_enabled": "#A21D56",
}
VARIANT_HATCHES = {
    "baseline": "",
    "calloc": "//",
    "modified_disabled": "\\\\",
    "modified_enabled": "xx",
}
SIZE_LABELS = {64: "64B", 256: "256B", 1024: "1KB", 4096: "4KB", 16384: "16KB", 65536: "64KB"}

LABEL_VARIANTS = {"calloc", "modified_disabled", "modified_enabled"}


def load_csv(path):
    with open(path) as f:
        reader = csv.DictReader(f)
        return list(reader)


def get_mean(rows, field):
    vals = []
    for r in rows:
        v = r.get(field, "").strip()
        if v:
            try:
                vals.append(float(v))
            except ValueError:
                pass
    return sum(vals) / len(vals) if vals else 0.0


def filter_rows(data, variant, comps, threads, size):
    return [
        r for r in data
        if r["variant"] == variant
        and int(r["comps"]) == comps
        and int(r["threads"]) == threads
        and int(r["fixed_size"]) == size
    ]


def plot_metric(data, threads, metric, ylabel, title_prefix, out_path, log_scale=False):
    fig, axes = plt.subplots(2, 2, figsize=(14, 5))
    axes_flat = axes.flatten()

    n_variants = len(VARIANTS)
    width = 0.18
    offsets = np.array([-(n_variants - 1) / 2 + i for i in range(n_variants)]) * width
    x_labels = [SIZE_LABELS[s] for s in SIZES]
    x = np.arange(len(SIZES))

    for c_idx, comps in enumerate(COMPS):
        ax = axes_flat[c_idx]

        # Baseline means for this compartment count
        baseline_means = []
        for s in SIZES:
            rows = filter_rows(data, "baseline", comps, threads, s)
            baseline_means.append(get_mean(rows, metric))

        max_mean = 0.0
        for v_idx, variant in enumerate(VARIANTS):
            means = []
            for s in SIZES:
                rows = filter_rows(data, variant, comps, threads, s)
                means.append(get_mean(rows, metric))
            max_mean = max(max_mean, max(means))

            bars = ax.bar(
                x + offsets[v_idx],
                means,
                width,
                label=VARIANT_LABELS[variant] if c_idx == 0 else None,
                color=VARIANT_COLORS[variant],
                hatch=VARIANT_HATCHES[variant],
                edgecolor="black",
                linewidth=0.7,
            )

            # Add overhead % labels for HC-on and calloc
            if variant in LABEL_VARIANTS:
                for i, (bar, val) in enumerate(zip(bars, means)):
                    if baseline_means[i] > 0 and val > 0:
                        if metric == "ops_per_sec":
                            overhead = (baseline_means[i] / val - 1.0) * 100.0
                        else:
                            overhead = (val / baseline_means[i] - 1.0) * 100.0
                        ax.text(
                            bar.get_x() + bar.get_width() / 2,
                            bar.get_height(),
                            f"{overhead:.0f}%",
                            ha="center", va="bottom",
                            fontsize=10, fontweight="bold", rotation=90,
                            color="black", alpha=0.9,
                        )

        if not log_scale and max_mean > 0:
            # Headroom so the rotated overhead labels above tall bars aren't
            # clipped by the axes.
            ax.set_ylim(top=max_mean * 1.25)

        if log_scale:
            ax.set_yscale("log")
            ax.set_ylim(bottom=1)
            cur_top = ax.get_ylim()[1]
            ax.set_ylim(top=max(cur_top, 1e6) * 2)
            ax.yaxis.set_major_locator(matplotlib.ticker.LogLocator(base=10, numticks=20))
            ax.yaxis.set_minor_locator(matplotlib.ticker.LogLocator(base=10, subs=np.arange(2, 10) * 0.1, numticks=20))
            ax.yaxis.set_minor_formatter(matplotlib.ticker.NullFormatter())

        ax.set_title(f"{comps} Compartments", fontsize=14)
        ax.set_xlabel("Allocation Size", fontsize=12)
        ax.set_ylabel(ylabel, fontsize=12)
        ax.set_xticks(x)
        ax.set_xticklabels(x_labels, rotation=45, ha="right", fontsize=11)
        ax.tick_params(axis="y", labelsize=11)
        ax.grid(axis="y", alpha=0.3)

    # Single shared legend
    handles, labels = axes_flat[0].get_legend_handles_labels()
    fig.legend(handles, labels, fontsize=12, loc="upper center", ncol=4,
               bbox_to_anchor=(0.5, 1.02))

    fig.suptitle(
        f"{title_prefix} ({threads} Thread{'s' if threads > 1 else ''})",
        fontsize=16, fontweight="bold", y=1.06,
    )
    plt.tight_layout()
    plt.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close()
    print(f"  Saved: {out_path}")


def parse_args():
    # Resolve defaults relative to this file, not the current directory, so the
    # script runs from anywhere.
    here = os.path.dirname(os.path.abspath(__file__))
    base = os.path.dirname(here)                # results/microbenchmarks/

    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument(
        "--csv", default=os.path.join(base, "raw", "results_final_tcache.csv"),
        help="microbenchmark results CSV (default: %(default)s)",
    )
    ap.add_argument(
        "--out-dir", default=os.path.join(base, "generated"),
        help="directory to write the PDFs into (default: %(default)s)",
    )
    return ap.parse_args()


def main():
    args = parse_args()
    tcache_path = args.csv
    out_dir = args.out_dir
    os.makedirs(out_dir, exist_ok=True)

    data = load_csv(tcache_path)
    print(f"Loaded {len(data)} rows from {tcache_path}")

    for t in THREADS:
        # ops_per_sec — linear scale
        plot_metric(
            data, t,
            metric="ops_per_sec",
            ylabel="Operations per Second",
            title_prefix="Throughput (ops/sec)",
            out_path=os.path.join(out_dir, f"ops_per_sec_linear_{t}t.pdf"),
            log_scale=False,
        )

        # ops_per_sec — log scale with full ticks
        plot_metric(
            data, t,
            metric="ops_per_sec",
            ylabel="Operations per Second",
            title_prefix="Throughput (ops/sec)",
            out_path=os.path.join(out_dir, f"ops_per_sec_log_{t}t.pdf"),
            log_scale=True,
        )

        # RSS graph — linear
        plot_metric(
            data, t,
            metric="maxrss_kb",
            ylabel="Max RSS (KB)",
            title_prefix="Memory Usage (Max RSS)",
            out_path=os.path.join(out_dir, f"rss_linear_{t}t.pdf"),
            log_scale=False,
        )

        # RSS graph — log scale
        plot_metric(
            data, t,
            metric="maxrss_kb",
            ylabel="Max RSS (KB)",
            title_prefix="Memory Usage (Max RSS)",
            out_path=os.path.join(out_dir, f"rss_log_{t}t.pdf"),
            log_scale=True,
        )

    print("\nAll graphs generated.")


if __name__ == "__main__":
    main()
