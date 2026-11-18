# Macrobenchmarks

Measured results for nginx, lighttpd and redis on ARM Morello / CheriBSD.

| experiment | compares | figure |
|------------|----------|--------|
| sealing | Baseline vs Seal-instrumented | `generated/sealing_benchmark_results{,_errorbars}.{pdf,png}` |
| calloc | Baseline vs Calloc vs HC-off vs HC-on | `generated/calloc_benchmark_results{,_errorbars}.{pdf,png}` |

Raw CSVs are under `raw/<experiment>/`, rendered figures under `generated/`, and the
plot scripts under `scripts/`. The CSVs were produced on Morello by the runners in
[`macrobenchmarks/`](../../macrobenchmarks/): `sealing/run_sealing_matrix.sh` and
`calloc/run_paper_matrix.sh`.

| figure | reads |
|--------|-------|
| `sealing_benchmark_results{,_errorbars}` | `raw/sealing/{nginx,lighttpd,redis}_bench.csv` |
| `calloc_benchmark_results{,_errorbars}` | `raw/calloc/{nginx,lighttpd,redis}.csv` |

The `driver*.log` files beside each set are the run logs for those CSVs.

## Rendering the figures

From the repository root:

```sh
python3 results/macrobenchmarks/scripts/plot_sealing_benchmarks.py
python3 results/macrobenchmarks/scripts/plot_calloc_benchmarks.py
```

Both need `matplotlib` and `numpy`. They read from `raw/` and write into `generated/`,
so the figures regenerate without CHERI hardware.

## How it was measured

Every datapoint uses a freshly started server. Only the server is wrapped by the
modified rtld/libc; the clients run on the stock runtime — `ab -n 50000` for the web
servers, `redis-benchmark -n 100000 -c 1` for redis.

Overhead is `(baseline − variant) / baseline × 100` on throughput metrics, so
**positive means slower**. Small negatives are noise, not speed-ups.

## Results

### Sealing

| app | mean overhead | statistically significant |
|-----|--------------:|---------------------------|
| nginx    | +0.34% | https +0.55%, https+gzip +0.35% |
| lighttpd | +0.46% | none |
| redis    | −0.17% | none |

Sealing costs under ~1% on all three applications, with a small measurable cost confined
to nginx's TLS paths.

### Calloc / heap compartmentalisation

| app | Calloc | HC-off (control) | HC-on |
|-----|-------:|-----------------:|------:|
| nginx    | +2.64% | −0.03% | −0.30% |
| lighttpd | −0.26% | +0.54% | +0.30% |
| redis    | +0.89% | +0.24% | +1.08% |

`HC-off` is the modified rtld/libc with `heap_compartment:false`, isolating the cost of
the modified runtime from that of compartmentalisation itself.
