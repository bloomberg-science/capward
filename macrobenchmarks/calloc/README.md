# calloc / heap-compartmentalisation macrobenchmark

Measures two costs that are independent of sealing, as a point of comparison
against it:

* the **calloc discipline** — zeroing every allocation;
* **heap compartmentalisation** — per-compartment heap separation in the
  modified rtld + libc.

`run_paper_matrix.sh` produces the data behind
`results/macrobenchmarks/generated/calloc_benchmark_results{,_errorbars}.{pdf,png}`.
The results and their methodology are described in
[`results/macrobenchmarks/README.md`](../../results/macrobenchmarks/README.md).

## The four variants

The application binary and the runtime are varied independently:

| variant | binary | rtld + libc | `MALLOC_CONF` |
|---|---|---|---|
| `baseline` | `<app>_baseline` | unmodified (`BASELINE_LIBC`) | *(unset)* |
| `calloc` | `<app>_calloc` | unmodified (`BASELINE_LIBC`) | *(unset)* |
| `compart_off` | `<app>_baseline` | modified (`MODIFIED_LIBC`) | `heap_compartment:false` |
| `compart_on` | `<app>_baseline` | modified (`MODIFIED_LIBC`) | `heap_compartment:true` |

`calloc` differs from `baseline` only in the binary; `compart_*` differ only in
the runtime. `compart_off` is the control that separates the cost of running the
modified runtime at all from the cost of compartmentalisation itself.

## Prerequisites

* A CheriBSD 25.03 machine on Arm Morello.
* The two runtimes, `BASELINE_LIBC` and `MODIFIED_LIBC` — each a directory
  containing `ld-elf.so.1` and `libc.so.7`. They are not part of this
  repository.
* A matched `<app>_baseline` / `<app>_calloc` pair per application under
  `$WORKSPACE_DIR/calloc/<app>/bin/`. The calloc variant is a separately built
  binary in which allocations are zeroed, not a preloaded allocator shim — the
  runner clears `LD_PRELOAD` explicitly.
* For nginx and lighttpd, a benchmark document root and server configuration
  under `$WORKSPACE_DIR/calloc/nginx/bench/` and `$WORKSPACE_DIR/lighttpd/bench/`,
  serving `bench.txt` and `bench.html` over HTTP and HTTPS on the ports below.
* `ab` (Apache Bench) and, for redis, `redis-benchmark` and `redis-cli`.

## Running

```sh
REPS=10 NREQ=50000 sh macrobenchmarks/calloc/run_paper_matrix.sh nginx lighttpd
REPS=5             sh macrobenchmarks/calloc/run_paper_matrix.sh redis
```

These are the invocations that produced the data in
`results/macrobenchmarks/raw/calloc/`.

Paths come from the environment: `REPO_DIR`, `WORKSPACE_DIR`, `BASELINE_LIBC`,
`MODIFIED_LIBC`, `OPENSSL_SRC` (which derives `OSSL`), `AB`, and `OUT`. Server
ports are `NGINX_HTTP_PORT` / `NGINX_HTTPS_PORT`, `LIGHTTPD_HTTP_PORT` /
`LIGHTTPD_HTTPS_PORT` and `REDIS_BENCH_PORT`. `REPS`, `NREQ` and `NOPS` are the
run knobs. All of them are set in `pipeline/set_env.sh`, which is the one place
to change a default; source it before running.

Per app it runs, with a fresh server for every single measurement:

| app | port(s) | tests |
|---|---|---|
| nginx | 8088 / 8443 | http, http+pcre, http+pcre+gzip, https, https+gzip |
| lighttpd | 8089 / 8444 | http, http+static, https |
| redis | 6399 | SET, GET, INCR, LPUSH, RPUSH, LPOP, RPOP, SADD, SPOP, HSET, MSET |

nginx runs with `master_process off`, so no worker process is forked: the fork
triggers a CHERI revocation cost that would otherwise dominate the
compartmentalisation result.

The client (`ab`, `redis-benchmark`) always runs on the stock system runtime;
only the server is wrapped by the modified rtld + libc.
