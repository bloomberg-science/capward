# CAPWARD

**CAP**ability **W**arding by **A**utomatically **R**estricting **D**ereference.

Artifact for *Mind the Heap: Preventing Capability Leakage Across CHERI
Compartments* (ACM CCS 2026).

CHERI's library compartmentalization isolates code, but not the heap: a pointer
handed across a compartment boundary remains a fully dereferenceable capability,
so a compromised compartment can read and write any object it has ever been
given. CAPWARD closes that gap automatically. It analyses a program's LLVM IR to
find every struct type shared across a compartment boundary, decides which of
them the non-owning compartment never actually dereferences, and rewrites the IR
to seal those pointers with CHERI hardware seal/unseal operations at the
boundary. A sealed capability can be stored and passed around but not
dereferenced, so a pointer that leaks into a compromised compartment is inert
there.

The repository contains the analysis and instrumentation toolchain, the
orchestration needed to apply it to real applications, the Rocq formalization,
and the measurements reported in the paper.

## Repository layout

```
analysis/          The tool itself
  llvm-passes/       CrossCompartmentTypeAnalyzer, SealInstrumentationPass
  python/            cross_compartment_analyzer.py, seal_codegen.py
pipeline/          Orchestration: build the passes, the libraries, and each app
  set_env.sh         Central environment; source before anything else
  build/             passes/, libraries/, apps/, seal_pipeline, run_seal_analysis
  test/              Functional tests for the six evaluated applications
proofs/            Rocq formalization (CASL + CHERI compartment heap)
microbenchmarks/   Heap-compartmentalization microbenchmark (Figure 5)
macrobenchmarks/   Benchmark runners: sealing/ (Figure 6), calloc/ (Figure 7)
results/
  microbenchmarks/   raw CSV, plotting script, generated figures
  macrobenchmarks/   raw CSV, plotting and table scripts, generated figures
```

## How the pieces fit together

`pipeline/build/run_seal_analysis.sh` drives the whole thing. Step numbers below
match the ones the scripts print as they run: the per-app and per-library build
scripts cover steps 1–2, and `seal_pipeline.sh` covers 3–7.

```
     C sources for the app and its libraries
       │  [1-2] built purecap with -flto -Wl,-plugin-opt=save-temps, so each
       │  project's own link step makes the LTO plugin drop whole-program
       │  bitcode next to the output. There is no per-translation-unit
       │  compilation: the compartment module comes straight out of LTO.
       ▼
     One preopt module per compartment
       (nginx.0.0.preopt.bc, libz.so.0.0.preopt.bc, ...)
       │  llvm-link, only where one compartment ships several modules —
       │  openssl (libssl + libcrypto) and libevent (per CMake target)
       ▼
     One module per compartment  (openssl_merged.bc, libevent_merged.bc, ...)
       │  [3] CrossCompartmentTypeAnalyzer      [analysis/llvm-passes]
       ▼
     Per-library JSON type manifests
       │  [4] cross_compartment_analyzer.py     [analysis/python]
       ▼
     sealing_report.json
         which struct types cross a boundary, who owns each one, which
         fields the non-owner touches, and the resulting recommendation:
           seal            non-owner never dereferences it     -> seal outright
           needs_accessor  non-owner reads some fields         -> seal + accessors
           cannot_seal     non-owner reads everything          -> no benefit
       │  [5] seal_codegen.py                   [analysis/python]
       ▼
     instrumentation_config.json  (per-call-site seal/unseal directives)
       │  [6] SealInstrumentationPass, once per compartment, unique otype
       ▼
     Instrumented bitcode
       │  [7] staged and linked with a single clang -flto (purecap)
       ▼
     Sealed .so files + executable, alongside an unmodified baseline
```

Each compartment gets one otype. The sealing capability lives in a file-scope
static (`__sealcap`) inside each `.so`, which CheriBSD's C18N library
compartmentalization keeps out of reach of every other compartment, so no shared
runtime library is needed — the pass emits direct `llvm.cheri.cap.seal` /
`llvm.cheri.cap.unseal` intrinsics.

## Evaluated applications

Six applications, with the libraries each is compartmentalized against:

| Application | Compartmentalized libraries |
|---|---|
| nginx | openssl, pcre2, zlib |
| lighttpd | openssl, zlib |
| curl | openssl, zlib |
| wget | openssl, zlib |
| redis | openssl |
| memcached | openssl, libevent |

## Running the artifact

[`ARTIFACT-EVALUATION.md`](ARTIFACT-EVALUATION.md) is the guide to running everything
here: prerequisites, the four tiers, and what each one reproduces. The analysis and
instrumentation — the paper's central mechanism — reproduce on an ordinary laptop with
nothing but Docker. An optional tier runs the sealed binaries under QEMU on CheriBSD
25.03 to confirm sealing does not break them. The performance measurements are not
claimed — they need a Morello board — but the measured data behind them is included.

Two things are **not** in this repository and must be supplied separately: the modified
libc runtimes behind the heap-compartmentalization measurements, and the application and
library sources the build scripts compile. Neither is needed to run the evaluation.

[`results/macrobenchmarks/README.md`](results/macrobenchmarks/README.md) describes the
benchmark methodology and the measured data.

The `cmd` column of `results/microbenchmarks/raw/results_final_tcache.csv` records the
full command line of each run, so individual measurements remain reproducible from
their row. Home directories in it read `/home/user`; substitute the locations of your
own runtimes.

## Maintainers

- Seyedhamed Ghavamnia ([@shamedgh](https://github.com/shamedgh))
- Julien Vanegue ([@jvanegue](https://github.com/jvanegue))

## Contributions

We welcome your contributions! Please read the
[CONTRIBUTING](https://github.com/bloomberg/.github/blob/main/CONTRIBUTING.md) guidelines
before submitting a pull request. All commits must be signed off under the
[Developer Certificate of Origin](DCO).

## Security

If you believe you have identified a security vulnerability in this project, please follow
the reporting process in [SECURITY.md](SECURITY.md). Please do NOT open a public issue.

## License

This project is licensed under the [MIT License](LICENSE).

## Code of Conduct

This project has adopted a
[Code of Conduct](https://github.com/bloomberg/.github/blob/main/CODE_OF_CONDUCT.md). If you
have any concerns about the Code, or behavior which you have experienced in the project,
please contact us at opensource@bloomberg.net.
