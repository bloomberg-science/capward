#!/usr/bin/env python3
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

"""Bar charts comparing Baseline vs Seal-instrumented for nginx, lighttpd, redis.

Sealing measurements, September 2026.

Palette, hatches and layout match plot_calloc_benchmarks.py and
results/microbenchmarks/scripts/gen_graphs.py, so all the figures read as one
system.

Emits two figures:
  results/macrobenchmarks/generated/sealing_benchmark_results.{pdf,png}            plain bars
  results/macrobenchmarks/generated/sealing_benchmark_results_errorbars.{pdf,png}  bars + 95% CI

Data: results/macrobenchmarks/raw/sealing/{nginx,lighttpd,redis}_bench.csv
      10 reps, ab -n 50000, fresh server per measurement, nginx with
      master_process off. Each row carries failed/non2xx (ab) or alive (redis)
      so a mid-run server crash cannot masquerade as a fast result.
"""

import argparse
import os

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np
import csv
import math
import statistics as st
from collections import defaultdict

VARIANTS = ["baseline", "instrumented"]
VARIANT_LABELS = {"baseline": "Baseline", "instrumented": "Seal"}
VARIANT_COLORS = {"baseline": "#5E4C5F",    # dark plum
                  "instrumented": "#A21D56"}  # wine
VARIANT_HATCHES = {"baseline": "", "instrumented": "xx"}
LABEL_VARIANTS = {"instrumented"}

# Resolve paths relative to this file, not the current directory, so the script
# runs from anywhere. Both locations are overridable.
_HERE = os.path.dirname(os.path.abspath(__file__))
_RESULTS = os.path.dirname(_HERE)          # results/macrobenchmarks/

_ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
_ap.add_argument("--raw-dir", default=os.path.join(_RESULTS, "raw", "sealing"),
                 help="directory holding {nginx,lighttpd,redis}_bench.csv")
_ap.add_argument("--out-dir", default=os.path.join(_RESULTS, "generated"),
                 help="directory to write the figures into")
_args = _ap.parse_args()

DATA_DIR = _args.raw_dir
OUT_DIR = _args.out_dir
os.makedirs(OUT_DIR, exist_ok=True)

_T95 = {2: 12.706, 3: 4.303, 4: 3.182, 5: 2.776, 6: 2.571, 7: 2.447, 8: 2.365,
        9: 2.306, 10: 2.262, 11: 2.228, 12: 2.201, 15: 2.145, 20: 2.093,
        25: 2.064, 30: 2.045}


def t95(n):
    if n < 2:
        return 0.0
    if n in _T95:
        return _T95[n]
    return 1.96 if n > 30 else _T95[min(_T95, key=lambda k: abs(k - n))]


def load_csv(filename, metric_col="rps"):
    """Return (tests, means, cis, ns). Also verifies the integrity columns."""
    vals = {v: defaultdict(list) for v in VARIANTS}
    order = []
    bad = 0
    with open(f"{DATA_DIR}/{filename}") as fh:
        text = fh.read().replace("\r", "")
    rows = list(csv.DictReader(text.splitlines()))
    if not rows:
        raise SystemExit(f"{filename}: no rows parsed")
    for row in rows:
        if not row.get(metric_col):
            continue
        # Integrity: ab records failed/non2xx; redis records alive=PONG.
        if (row.get("failed", "0") not in ("0", "", None)
                or row.get("non2xx", "0") not in ("0", "", None)
                or row.get("alive", "PONG") not in ("PONG", "", None)):
            bad += 1
        test, variant = row["test"].strip(), row["variant"].strip()
        if variant not in vals:
            continue
        if test not in order:
            order.append(test)
        vals[variant][test].append(float(row[metric_col]))
    if bad:
        print(f"  !! {filename}: {bad} row(s) with failed requests / dead server")

    means, cis, ns = {}, {}, {}
    for v in VARIANTS:
        means[v], cis[v], ns[v] = [], [], []
        for t in order:
            xs = vals[v][t]
            n = len(xs)
            means[v].append(st.mean(xs) if xs else 0.0)
            cis[v].append(t95(n) * st.stdev(xs) / math.sqrt(n) if n > 1 else 0.0)
            ns[v].append(n)
    return order, means, cis, ns


def subset(order, means, cis, keep):
    idx = [order.index(k) for k in keep if k in order]
    return ([order[i] for i in idx],
            {v: [means[v][i] for i in idx] for v in VARIANTS},
            {v: [cis[v][i] for i in idx] for v in VARIANTS})


def plot_benchmark(ax, labels, means, cis, title, ylabel, errorbars):
    x = np.arange(len(labels))
    width = 0.35
    offsets = np.linspace(-width / 2, width / 2, len(VARIANTS))
    baseline = means["baseline"]

    bars = {}
    for off, variant in zip(offsets, VARIANTS):
        bars[variant] = ax.bar(
            x + off, means[variant], width, label=VARIANT_LABELS[variant],
            color=VARIANT_COLORS[variant], hatch=VARIANT_HATCHES[variant],
            edgecolor='black', linewidth=0.7,
            yerr=cis[variant] if errorbars else None,
            # {} not None when off: bar() only substitutes a default when the
            # kwarg is absent, and unconditionally calls error_kw.pop(), so an
            # explicit None raises AttributeError on matplotlib < 3.9.
            error_kw=dict(ecolor='black', elinewidth=0.9, capsize=2.5,
                          capthick=0.9) if errorbars else {})

    ax.set_ylabel(ylabel, fontsize=12)
    ax.set_title(title, fontsize=14, fontweight='bold')
    ax.set_xticks(x)
    ax.set_xticklabels(labels, fontsize=11, rotation=45, ha='right')
    ax.legend().remove()

    peak = max(means[v][i] + (cis[v][i] if errorbars else 0)
               for v in VARIANTS for i in range(len(labels)))
    ymax = peak * 1.45
    ax.set_ylim(0, ymax)

    # Overhead % above its own column, rotated 90 deg (matches gen_graphs.py).
    # Positive = sealed achieved less throughput than baseline = worse.
    for variant in VARIANTS:
        if variant not in LABEL_VARIANTS:
            continue
        for i, bar in enumerate(bars[variant]):
            b = baseline[i]
            if b <= 0:
                continue
            ov = ((b - means[variant][i]) / b) * 100
            top = bar.get_height() + (cis[variant][i] if errorbars else 0)
            ax.text(bar.get_x() + bar.get_width() / 2, top + ymax * 0.015,
                    f'{ov:+.1f}%', ha='center', va='bottom',
                    fontsize=8, fontweight='bold', rotation=90,
                    color='black', alpha=0.9)

    ax.grid(axis='y', alpha=0.3, linestyle='--')
    ax.set_axisbelow(True)


ng_t, ng_m, ng_c, ng_n = load_csv("nginx_bench.csv")
lt_t, lt_m, lt_c, lt_n = load_csv("lighttpd_bench.csv")
rd_t, rd_m, rd_c, rd_n = load_csv("redis_bench.csv", "ops_per_sec")
rd_t, rd_m, rd_c = subset(rd_t, rd_m, rd_c,
                          ["set", "get", "incr", "lpush", "sadd", "mset_(10_keys)"])

ng_lab = [t.replace("http+pcre+gzip", "HTTP+PCRE\n+gzip").replace("http+pcre", "HTTP+PCRE")
           .replace("https+gzip", "HTTPS+gzip").replace("https", "HTTPS").replace("http", "HTTP")
          for t in ng_t]
lt_lab = [t.replace("http+static", "HTTP+static").replace("https", "HTTPS")
           .replace("http", "HTTP") for t in lt_t]
rd_lab = [t.replace("_(10_keys)", "").upper() for t in rd_t]

print(f"reps per cell — nginx:{ng_n['baseline'][0]} lighttpd:{lt_n['baseline'][0]} "
      f"redis:{rd_n['baseline'][0] if rd_n['baseline'] else '?'}")

for errorbars, suffix in [(False, ""), (True, "_errorbars")]:
    fig, axes = plt.subplots(1, 3, figsize=(14, 2.8))
    plot_benchmark(axes[0], ng_lab, ng_m, ng_c, 'Nginx', 'Requests per Second', errorbars)
    plot_benchmark(axes[1], lt_lab, lt_m, lt_c, 'Lighttpd', 'Requests per Second', errorbars)
    plot_benchmark(axes[2], rd_lab, rd_m, rd_c, 'Redis', 'Operations per Second', errorbars)
    handles, labels = axes[0].get_legend_handles_labels()
    fig.legend(handles, labels, loc='upper center', ncol=2, fontsize=11,
               frameon=True, bbox_to_anchor=(0.5, 1.16))
    plt.tight_layout()
    for ext in ("pdf", "png"):
        plt.savefig(os.path.join(OUT_DIR, f"sealing_benchmark_results{suffix}.{ext}"),
                    bbox_inches='tight', dpi=300)
    plt.close(fig)
    print(f"Saved {os.path.join(OUT_DIR, f'sealing_benchmark_results{suffix}')}.pdf and .png")
