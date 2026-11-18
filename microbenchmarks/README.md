# Heap Compartmentalization Microbenchmark

Measures the throughput and memory cost of per-compartment heap isolation. The
harness builds a program linked against *N* shared libraries ("compartments"),
each exposing its own `malloc`/`calloc`/`free` wrappers, then drives allocation
traffic across them and records ops/sec and peak RSS.

Each compartment is a separate DSO (`libcomp001.so` … `libcompNNN.so`) generated
from a template, so the allocator sees genuinely distinct callers rather than
one binary passing a compartment ID. A generated switch-case dispatcher routes
each operation to the right DSO, avoiding indirect-call overhead in the
measurement path.

## Prerequisites

**CheriBSD 25.03.** The harness relies on `bmake` syntax (`!=`, `.for`), `jot`,
`cpuset`, `ld-elf.so.1`, `/usr/bin/time -l`, and the `LD_COMPARTMENT_ENABLE`
library compartmentalization support in the CheriBSD runtime linker. It does not
build or run on Linux or macOS.

**Modified libc builds are required and are not included in this repository.**
`run_matrix.sh` measures four variants, which need two separate libc trees:

| Variant | libc tree | `MALLOC_CONF` |
|---|---|---|
| `baseline` | stock | — |
| `calloc` | stock | — |
| `modified_disabled` | heap-compartmentalized | `heap_compartment:false` |
| `modified_enabled` | heap-compartmentalized | `heap_compartment:true` |

`baseline` and `calloc` are the same runtime and differ only in the allocation
function the driver calls, isolating the cost of zeroing. `modified_disabled`
runs the compartmentalized libc with the feature switched off, which separates
code-path overhead from the cost of the feature itself.

Point the harness at the two trees through the environment — no file needs
editing. The defaults are the same ones `pipeline/set_env.sh` sets, so sourcing
that is enough if your runtimes are in the conventional place:

```sh
. ../pipeline/set_env.sh          # sets BASELINE_LIBC and MODIFIED_LIBC
./run_matrix.sh --out results.csv --no-call --tcache
```

Otherwise override them for the run:

```sh
BASELINE_LIBC=/path/to/libc.baseline \
MODIFIED_LIBC=/path/to/libc.modified.perarena \
    ./run_matrix.sh --out results.csv --no-call --tcache
```

Each must be a directory containing `ld-elf.so.1` and `libc.so.7`. The runtime
loader and library directory are derived from them (`MOD_RTLD`, `MOD_LIBC_DIR`,
`BASELINE_RTLD`, `BASELINE_LIBC_DIR`), and can be overridden individually if
your layout splits them.

## Build

```sh
make            # N=128 compartment DSOs (default)
make N=64       # rebuild with a different count
make clean
```

`make` generates `gen/comp*.{c,h}` plus the dispatcher via `tools/gen_comps.py`,
compiles one `.so` per compartment into `build/lib/`, and links
`build/bench_driver` against all of them with `-rpath $ORIGIN/lib`.

`N` is the number compiled in, and is the ceiling on `--comps` at runtime — the
driver errors out if `--comps` exceeds it. Rebuild with a larger `N` to go
beyond 128.

## Run

`run_matrix.sh` sweeps the full parameter grid, running each configuration under
the appropriate runtime and appending one CSV row per run.

The published results in `../results/microbenchmarks/raw/results_final_tcache.csv`
were produced by:

```sh
./run_matrix.sh --out results_final_tcache.csv --no-call --tcache
```

That grid is 4 variants × 4 compartment counts (2, 8, 16, 64) × 3 thread counts
(1, 4, 8) × 6 allocation sizes (64 B – 64 KB) × 10 repetitions = **2880 runs**.

Useful flags (see `--help` for the full set):

| Flag | Default | Meaning |
|---|---|---|
| `--out FILE` | `results.csv` | Output CSV; appended to if it exists |
| `--comps-list "..."` | `2 8 16 64` | Compartment counts to sweep |
| `--threads-list "..."` | `1 4 8` | Thread counts to sweep |
| `--fixed-sizes "..."` | `64 256 1024 4096 16384 65536` | Allocation sizes in bytes |
| `--reps-per-seed N` | `10` | Repetitions per configuration |
| `--tcache` | off | Enable jemalloc tcache (otherwise `tcache:false`) |
| `--no-call` / `--no-alloc` | both on | Skip the call-latency or allocation mode |
| `--no-pin` | pinned | Disable `cpuset` CPU pinning |

Threads are pinned with `cpuset` by default, and ops/sec is raised from 20 000 to
200 000 per thread for sizes ≤ 1 KB so the short runs stay measurable.

`bench_driver` can also be invoked directly for a single configuration:

```sh
./build/bench_driver --mode alloc --comps 8 --threads 4 --ops 200000 \
    --fixed-size 1024 --alloc-fn malloc --pattern rr --seed 10000
```

It prints a single `RESULT ...` line of `key=value` pairs, which `run_matrix.sh`
parses into CSV columns. Peak RSS comes from `/usr/bin/time -l`, not the driver.

## Generate the graphs

```sh
python3 ../results/microbenchmarks/scripts/gen_graphs.py
```

The script resolves its own paths, so it defaults to the checked-in
`raw/results_final_tcache.csv` and writes into `generated/` regardless of where
you run it from. Pass `--csv` / `--out-dir` to use your own run instead.

Requires `matplotlib` and `numpy`. This writes 12 PDFs — `ops_per_sec` and `rss`,
each on linear and log axes, for 1, 4, and 8 threads. Every plot is a 2×2 grid of
subplots, one per compartment count, with allocation size on the x-axis and the
four variants as grouped bars. Bars for `calloc`, `HC-off`, and `HC-on` are
annotated with their percentage overhead relative to `baseline`.

## Layout

```
microbenchmarks/
├── Makefile             bmake build; generates DSOs and links the driver
├── bench_driver.c       workload driver, CLI, timing, RESULT output
├── common.h             shared parameter and result structs
├── run_matrix.sh        parameter sweep; sets up per-variant runtime env
├── tools/gen_comps.py   emits gen/comp*.{c,h} and the switch dispatcher
├── gen/                 generated sources        (created by make)
└── build/               DSOs and bench_driver    (created by make)
```

## CSV schema

One row per run, 28 columns:

`ts`, `variant`, `mode`, `comps`, `threads`, `seed_index`, `fixed_size`,
`seed_rep`, `pattern`, `burst_len`, `ops_per_thread`, `live`, `free_pct`,
`remote_free`, `sizes`, `alloc_fn`, `seed`, `seconds`, `ops_per_sec`, `allocs`,
`frees`, `remote_frees`, `trace_digest`, `count_64k`, `count_1m`, `checksum`,
`maxrss_kb`, `cmd`

`cmd` records the full command line including the environment prefix, so any
individual run can be reproduced from its row.

Three columns exist to validate a run rather than measure it:

- `trace_digest` — rolling hash over the generated operation trace (op kind,
  compartment, index, size). For a given seed it is identical across all four
  variants, confirming they executed the same workload and that a throughput
  difference reflects the allocator, not a divergent trace.
- `checksum` — XOR of every pointer returned. Creates a data dependency on the
  allocation results so the compiler cannot elide the workload.
- `count_64k` / `count_1m` — how many allocations landed in the two largest size
  classes, a sanity check on the size distribution under `--sizes mixed`.
