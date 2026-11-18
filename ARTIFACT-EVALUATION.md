# Artifact Evaluation: Mind the Heap — Preventing Capability Leakage Across CHERI Compartments

## Artifact description

This artifact accompanies the ACM CCS 2026 paper *Mind the Heap: Preventing Capability
Propagation Across CHERI Compartments*. It provides **CAPWARD** (**CAP**ability
**W**arding by **A**utomatically **R**estricting **D**ereference), an LLVM-based
toolchain that finds every struct type shared across a CHERI compartment boundary,
decides which of them the non-owning compartment never dereferences, and rewrites the
IR to seal those pointers with CHERI hardware seal/unseal operations.

The artifact supports:

- the Rocq formalization of the sealing model;
- the cross-compartment type analysis and seal instrumentation for six applications
  (Tables 2 and 3);
- smoke-testing the sealed binaries to confirm sealing does not break them.

The performance measurements of Section 6 are **not** claimed: they need an ARM Morello
board, which we cannot provide. The measured data behind them is included so the figures
can still be regenerated and inspected.

**Type.** Software artifact: analysis toolchain, build and test orchestration, Rocq
formalization, and the recorded measurements.

**Delivery format.** Everything is on Zenodo. A pre-built Docker image carries the exact
Morello LLVM the artifact depends on, and is what Tier 2 runs in; it can also be built
from the provided `Dockerfile`. The compartment bitcode ships alongside it. The optional
Tier 3 adds a CheriBSD guest disk image for QEMU, with the toolchain and the prebuilt
sealed binaries already installed.

**Host requirements.** x86-64 **Ubuntu 22.04 LTS**, which is what the artifact was
developed and tested on. About 3 GB of disk for Tier 2, or 30 GB if you also do the
optional Tier 3. No CHERI hardware is needed for any tier.
The Docker image is `linux/amd64`.

**Not included.** The modified libc and runtime linker behind the
heap-compartmentalization measurements are maintained separately and are not
distributable here. The application and library sources are not vendored; nothing in
the evaluation needs them, because Tier 2 works from the published compartment bitcode
and Tier 3 from prebuilt binaries.

---

## What each tier reproduces

CAPWARD targets ARM Morello running CheriBSD, which most reviewers will not have. The
artifact is therefore split into four tiers by what each one needs, so you can get as
far as your setup allows and know exactly where the line is.

| Tier | Needs | Reproduces | Time |
|------|-------|-----------|------|
| [1](#tier-1--no-cheri-hardware) | Nothing (Rocq for the proofs, or use the Tier 2 image) | Rocq proofs; Tables 2–3; Figures 5–7 | minutes |
| [2](#tier-2--the-analysis-and-instrumentation-with-docker) | Docker | The analysis and instrumentation, all six applications | ~15 min |
| [3](#tier-3--optional-functional-testing-under-qemu) | QEMU (`qemu-system-morello`) | **Optional.** The sealed binaries still work | ~1 hour |
| [4](#tier-4--performance-not-claimed) | ARM Morello board | *Not claimed* — the raw data is provided instead | — |

**Tiers 1 and 2 together cover the claims the paper actually argues, and they are the
evaluation.** Tier 3 is optional corroboration: it shows the sealed programs still run
correctly, using binaries we provide prebuilt. Tier 4 covers only the cost of sealing,
and is out of scope.

| Paper claim | Reproduced by | Tier |
|---|---|---|
| The sealing model is sound (theorems) | [Experiment 3](#experiment-3-the-rocq-formalization) | 1 |
| Which struct types cross a boundary and which are sealable (Tables 2, 3) | [Experiment 1](#experiment-1-tables-2-and-3), regenerated from scratch by [Experiment 4](#experiment-4-analysis-and-instrumentation-for-all-six-applications) | 1, 2 |
| The analysis and instrumentation run end to end on real applications | [Experiment 4](#experiment-4-analysis-and-instrumentation-for-all-six-applications) | 2 |
| Sealing does not break the programs | [Experiment 5](#experiment-5-smoke-tests-on-the-sealed-binaries) | 3 (optional) |
| Sealing and heap-compartmentalization overhead (Figures 5–7) | [Experiment 2](#experiment-2-figures-57), replotting the measured data | 1 |

---

# Part I: Getting Started Guide (< 30 minutes)

## 1. Prerequisites

Package names are apt's.

**Tier 1.** Python 3 and `make`:

```sh
sudo apt install python3 python3-matplotlib python3-numpy make
```

`matplotlib` and `numpy` are needed only for the figures; the tables use the standard
library alone.

The proofs additionally need **Rocq 9.2**. The Tier 2 image already contains it, so if
you are using Docker there is nothing to install — run the proofs in the container. To
install it on the host instead, see
[`proofs/README-ARTIFACT-ROCQ.md`](proofs/README-ARTIFACT-ROCQ.md); it installs via
opam. The version matters: under 9.1.0 `CHERI_compartheap.v` fails to parse.

**Tier 2.** Docker, and `zstd` to unpack the image:

```sh
sudo apt install docker.io zstd
```

Allow about 2.6 GB for the image and 155 MB for the bitcode.

**Tier 3 (optional).** cheribuild's dependencies, to build `qemu-system-morello`, and
about 25 GB of disk for the emulator and the guest disk:

```sh
sudo apt install git python3 cmake ninja-build make libtool libglib2.0-dev \
                 pkg-config autoconf automake curl
```

Nothing is needed *inside* the guest: the image we ship already carries the toolchain,
python, and the prebuilt binaries the tests run against.

## 2. Get the artifact

Everything comes from Zenodo. Nothing else needs to be downloaded. You do not need all
of it — the **Needed for** column says which tier each file belongs to.

| File | Download | Needed for | Contents |
|---|---|---|---|
| `capward-source.tar.gz` | 3.5 MB | all tiers | the repository |
| `capward-ae-llvm15.tar.zst` | 709 MB | Tier 2 | the Docker image, 2.6 GB once loaded |
| `capward-bitcode-all6.tar.gz` | 81 MB | Tier 2 | compartment bitcode as the analysis consumes it, 18 modules |
| `capward-guest-25.03.img.zst` | 651 MB | Tier 3 only | the CheriBSD guest disk, toolchain and prebuilt binaries included |
| `capward-instrumented-bitcode.tar.gz` | 88 MB | reference | the same 18 modules *after* the seal pass |
| `capward-binaries-all6.tar.gz` | 104 MB | reference | sealed and baseline binaries and shared objects, 36 files |
| `SHA256SUMS` | | | checksums for all of the above |

The two `reference` files are not needed to run anything. They are what the paper's own
Morello runs produced — the instrumentation output, and the binaries built from it — and
are there if you want to examine the sealed code without running the pipeline. The guest
image already contains those binaries, so Tier 3 does not need them either.

**Everyone starts here.** Verify what you downloaded and unpack the repository; the rest
of this guide assumes you are inside it.

```sh
sha256sum -c SHA256SUMS

tar xzf capward-source.tar.gz
cd capward
```

That alone is enough for [Tier 1](#tier-1--no-cheri-hardware).

**For [Tier 2](#tier-2--the-analysis-and-instrumentation-with-docker)**, add the bitcode
the analysis consumes and the toolchain image that runs it:

```sh
tar xzf ../capward-bitcode-all6.tar.gz               # unpacks to workspace/
zstd -d ../capward-ae-llvm15.tar.zst -c | docker load
```

The bitcode must be unpacked at the root of the source tree, as above: it lands in
`workspace/<app>/bitcode/<lib>_merged.bc`, which is exactly where the pipeline looks for
it.

Rather than loading our image, you can build it yourself from the included `Dockerfile`;
see [`docker/README.md`](docker/README.md). If your network intercepts TLS, drop your CA
into [`docker/certs/`](docker/certs/) first.

**For the optional [Tier 3](#tier-3--optional-functional-testing-under-qemu)**, decompress
the guest disk straight into the location the boot script expects. Nothing needs unpacking
into the source tree — the image is self-contained and carries its own copy of the
repository:

```sh
mkdir -p ~/cheri/images
zstd -d ../capward-guest-25.03.img.zst -o ~/cheri/images/cheribsd-25.03-disk.img
```

The disk is declared as 20 GB but sparse, so it occupies about 3 GB on a filesystem that
supports sparse files, and the full 20 GB on one that does not. Decompressing to this
path means every later command works with no arguments; to keep it elsewhere, pass
`QEMU_DISK=/path/to/image` to the boot script each time.

Tier 3 also needs `qemu-system-morello`, which is built separately; that is covered in
[Set up the emulator](#set-up-the-emulator).

## 3. Quick check

Two checks that together confirm both main paths work, in about three minutes. (Not to be
confused with the *smoke tests* of
[Experiment 5](#experiment-5-smoke-tests-on-the-sealed-binaries), which exercise the
sealed binaries under QEMU.)

**Tier 1 — the tables regenerate with no CHERI anything:**

```sh
python3 results/macrobenchmarks/scripts/gen_tables.py --table summary
```

*Expected:* LaTeX for Table 2 on stdout, with a `redis` row reading
`2 & 11 & 11 & 0 & 0 & 581 & 3,650 & 0`.

**Tier 2 — the toolchain runs and reproduces a recorded result:**

```sh
docker run --rm -it -v "$PWD":/capward capward-ae:llvm15

# inside the container:
sh pipeline/build/passes/build_passes_morello.sh
sh pipeline/build/seal_pipeline.sh --app redis --libs "redis:0 openssl:1"
diff workspace/redis/generated/sealing_report.json \
     results/workspace/redis/generated/sealing_report.json && echo "IDENTICAL"
```

*Expected:* the pass build reports two `.so` plugins built; the pipeline finishes with
`Pipeline complete for redis!` after reporting `581 seal insertions` and
`3649 unseal insertions`; the `diff` prints `IDENTICAL`.

*Time:* about 30 seconds for the plugins, 20 seconds for redis.

If both succeed, the environment is good and you can work through Part II.

---

# Part II: Step-by-step reproduction

## Tier 1 — no CHERI hardware

Nothing here is emulated; every input is checked into the repository.

### Experiment 1: Tables 2 and 3

*Reproduces:* Table 2 (cross-compartment sealing instrumentation summary) and Table 3
(struct types requiring accessor functions).

```sh
python3 results/macrobenchmarks/scripts/gen_tables.py --table summary    # Table 2
python3 results/macrobenchmarks/scripts/gen_tables.py --table accessors  # Table 3
```

*Expected:* LaTeX for each on stdout. Table 2's total row reads
`161 & 150 & 8 & 3 & 6,827 & 34,852 & 113`, matching Section 7.2: 161 shared struct
types, of which 150 (93%) fully sealable, 8 (5%) needing accessors and 3 (2%) not
practically sealable. Table 3 lists the five accessor-mediated types — `z_stream_s`,
`asn1_string_st`, `GENERAL_NAME_st`, `X509_info_st` and `ossl_param_st`.

With no `--workspace` argument the script reads the analysis outputs checked in under
[`results/workspace/`](results/workspace/), the output of our Morello pipeline run of
2026-09-02, so the tables regenerate with no CHERI hardware.

*Time:* seconds.

### Experiment 2: Figures 5–7

*Reproduces:* Figure 5 (microbenchmark throughput), Figure 6 (sealing macrobenchmark)
and Figure 7 (calloc vs heap-compartmentalization macrobenchmark).

```sh
python3 results/microbenchmarks/scripts/gen_graphs.py                # Figure 5
python3 results/macrobenchmarks/scripts/plot_sealing_benchmarks.py   # Figure 6
python3 results/macrobenchmarks/scripts/plot_calloc_benchmarks.py    # Figure 7
```

*Expected:* the committed PDFs and PNGs under `results/*/generated/` are overwritten
with identical content. The three that appear in the paper:

| Paper | File | Shows |
|---|---|---|
| Figure 5 | `results/microbenchmarks/generated/ops_per_sec_linear_1t.pdf` | Baseline, calloc, HC-off, HC-on throughput at 1 thread, by compartment count and allocation size |
| Figure 6 | `results/macrobenchmarks/generated/sealing_benchmark_results.pdf` | nginx, lighttpd, redis: Baseline vs Seal |
| Figure 7 | `results/macrobenchmarks/generated/calloc_benchmark_results.pdf` | nginx, lighttpd, redis: Baseline vs Calloc vs HC-off vs HC-on |

Each script resolves its own paths, so the working directory does not matter.

*Time:* seconds.

### Experiment 3: The Rocq formalization

*Reproduces:* the theorems stated in the paper.

Needs Rocq 9.2. The simplest route is the Tier 2 image, which ships it:

```sh
docker run --rm -it -v "$PWD":/capward capward-ae:llvm15
cd proofs && make
```

Or, with Rocq installed on the host, just `cd proofs && make`.

*Expected:*

```
 ================================================================
  ARTIFACT VALIDATED
  3 source files compiled, 165 proofs completed,
  0 admitted, 0 axioms.
 ================================================================
```

See [`proofs/README-ARTIFACT-ROCQ.md`](proofs/README-ARTIFACT-ROCQ.md) for the
claim-by-claim mapping to the paper.

*Time:* minutes.

---

## Tier 2 — the analysis and instrumentation, with Docker

**This is the tier that matters most, and it needs no CHERI hardware and no emulator.**
The image supplies Morello LLVM 15, the toolchain this artifact's bitcode was produced
with. It also carries Rocq 9.2 and a CheriBSD 25.03 purecap sysroot, so the same
container serves [Experiment 3](#experiment-3-the-rocq-formalization) as well.

### Experiment 4: Analysis and instrumentation for all six applications

*Reproduces:* the per-application analysis behind Tables 2 and 3 — which struct types cross
each compartment boundary, which are sealable, and how many seal and unseal operations
get inserted.

Mount your checkout at `/capward`; everything the scripts need is already set in the
image's environment.

```sh
docker run --rm -it -v "$PWD":/capward capward-ae:llvm15
```

Inside the container, build the two pass plugins once:

```sh
sh pipeline/build/passes/build_passes_morello.sh
```

Then run the pipeline for each application:

```sh
sh pipeline/build/seal_pipeline.sh --app redis     --libs "redis:0 openssl:1"
sh pipeline/build/seal_pipeline.sh --app wget      --libs "wget:0 openssl:1 zlib:2"
sh pipeline/build/seal_pipeline.sh --app curl      --libs "curl:0 openssl:1 zlib:2"
sh pipeline/build/seal_pipeline.sh --app lighttpd  --libs "lighttpd:0 openssl:1 zlib:2"
sh pipeline/build/seal_pipeline.sh --app nginx     --libs "nginx:0 openssl:1 pcre2:2 zlib:3"
sh pipeline/build/seal_pipeline.sh --app memcached --libs "memcached:0 openssl:1 libevent:2"
```

Each runs the analyzer pass (step 3), `cross_compartment_analyzer.py` (4),
`seal_codegen.py` (5), `SealInstrumentationPass` (6) and the staging step (7).

*Expected:* each finishes with `Pipeline complete for <app>!` and writes
`workspace/<app>/generated/{sealing_report.json,instrumentation_config.json}`. Compare
against the recorded output of our Morello run:

```sh
for app in redis wget curl lighttpd nginx memcached; do
    diff -q workspace/$app/generated/sealing_report.json \
            results/workspace/$app/generated/sealing_report.json
done
```

Five of the six are byte-identical; memcached differs as described under
[Expected variations](#expected-variations).

To regenerate the tables from what you just produced rather than from the recorded run:

```sh
python3 results/macrobenchmarks/scripts/gen_tables.py --workspace workspace
```

*Time:* about 20 seconds per application, two minutes for all six.

---

## Tier 3 — optional: functional testing under QEMU

**This tier is optional.** Tiers 1 and 2 carry the paper's claims; this one corroborates
that the sealed programs still behave correctly.

**Skip it if you are short of time or of machine.** Everything here happens under
emulation, and that is slow in a way a better host does not fix:
`qemu-system-morello` interprets the Morello instruction set rather than JIT-ing it to
your CPU, so the guest runs orders of magnitude slower than hardware no matter what you
run it on. A fast machine makes the guest less painful, not fast. Budget roughly an hour
for the tier, most of it spent waiting.

It also wants real resources. You need about 25 GB of disk for the emulator and the guest
image, and the guest should be given several GB of RAM — QEMU also runs each guest vCPU
as a host thread, so `QEMU_SMP` should stay well inside your core count. We validated
this tier with `QEMU_MEM=32768 QEMU_SMP=8`; the boot script's defaults are lower and were
chosen to start anywhere, not to be comfortable. If your machine cannot spare that, Tiers
1 and 2 still give you everything the paper argues.

QEMU gives you a Morello machine running purecap CheriBSD, which is enough to *run* the
sealed binaries. It is **not** enough for any performance claim — see
[Tier 4](#tier-4--performance-not-claimed).

### What this tier does and does not ask of you

**We provide the binaries prebuilt.** The guest image ships the sealed and baseline
binaries for all six applications, already linked. You boot the image and run the tests.

**We do not support building your own guest.** To keep reproduction simple we ship one
known-good environment rather than instructions for assembling an equivalent. The
artifact depends on one specific Morello LLVM, and installing a toolchain yourself
invites version incompatibilities that are difficult to debug — see the
[FAQ](#faq) on why the toolchain is shipped as an image at all. Use the guest we provide,
and on CheriBSD 25.03 only; see
[Platform requirement](#platform-requirement-cheribsd-2503).

**We do not ask you to rebuild them, from source or from bitcode.** Both are technically
possible in the guest and neither is practical. QEMU is an ISA-level interpreter with no
JIT to native Morello, so it runs roughly two orders of magnitude slower than hardware
for compilation work. Measured in this guest: linking the OpenSSL compartment alone —
one module, of the 18 — took **53 minutes**. Doing that for all six applications, in
both sealed and baseline variants, is most of a day of emulator time before a single
test runs. Compiling the applications from source on top of that is longer still.

That is a property of the emulator, not of the artifact: the same links take a couple of
minutes on the Morello board the paper used. Shipping the binaries removes the cost
without removing anything you can check — they are the output of the same pipeline you
run yourself in [Tier 2](#tier-2--the-analysis-and-instrumentation-with-docker), produced
by the build scripts in [`pipeline/build/`](pipeline/build/), which are here for
inspection.

**The binaries are reproducible, and we checked.** Linking redis's sealed OpenSSL
compartment inside the QEMU guest produced a file byte-identical to the one built on the
Morello board for the paper — same SHA-256,
`14c70745057ac4ea7d810d4af94ee5314e6d144c5f0999a48bd2be566442c59a`. The link is
deterministic and the guest's toolchain is the same toolchain, so the binaries we ship
are the ones this pipeline produces.

### Set up the emulator

Tier 3 runs outside the Tier 2 container, on your own machine. The emulator is built
with [cheribuild](https://github.com/CTSRD-CHERI/cheribuild), CHERI's own build tool —
it is not part of this repository. You need this even though we ship the guest image:
the image is the guest filesystem, while `qemu-system-morello` is the emulator that runs
it, and no upstream QEMU or distribution package supports Morello.

```sh
git clone https://github.com/CTSRD-CHERI/cheribuild.git
cd cheribuild
./cheribuild.py qemu
```

### Boot the guest image

The image you decompressed in [Get the artifact](#2-get-the-artifact) is a CheriBSD 25.03
purecap install carrying the Morello LLVM 15 toolchain, python 3.11, this repository, the
compartment bitcode, and the prebuilt sealed and baseline binaries for all six
applications — everything Tier 3 needs, with nothing left to install.

```sh
sh pipeline/qemu/boot_cheribsd_qemu.sh --installed
```

> If the guest boots to a firmware screen with nothing to load, the script did not find
> the image. It defaults to `~/cheri/images/cheribsd-25.03-disk.img` and **creates an
> empty disk** if nothing is there, so a wrong path produces a blank 20 GB disk rather
> than an error. Check the path it prints, or pass `QEMU_DISK=` explicitly.

Log in as **`capward`**, password **`capward`**. The script forwards the guest's SSH port
to `localhost:19507`, so `ssh -p 19507 capward@127.0.0.1` also works and is more
comfortable than the serial console.

The script takes its settings from the environment. The defaults are deliberately modest;
on a machine with cores and memory to spare, give the guest more of both:

```sh
QEMU_MEM=32768 QEMU_SMP=8 sh pipeline/qemu/boot_cheribsd_qemu.sh --installed
```

`QEMU_SMP` will not speed up any single compilation — QEMU runs each vCPU as one host
thread and a link is serial — but it lets independent work proceed in parallel.

Two operational notes that will save you trouble:

- **Run QEMU under `tmux` or `screen`.** With `-nographic` the guest console is your
  terminal, so a dropped SSH connection takes the guest down with it.
- **Shut down with `shutdown -p now`**, not `-h`. The script also opens a QEMU monitor
  socket, so a clean ACPI poweroff works from any shell on the host even if you have lost
  the console entirely:
  ```sh
  echo system_powerdown | nc -U -q1 ~/cheri/images/qemu-monitor-25.03.sock
  ```

### Experiment 5: Smoke tests on the sealed binaries

*Reproduces:* the claim that sealing does not break the programs.

The binaries are already in place at `workspace/<app>/instrumented/` (sealed) and
`workspace/<app>/baseline/` (identical build, pre-instrumentation). Inside the guest:

```sh
cd ~/capward
sh pipeline/test/smoke_redis.sh
sh pipeline/test/smoke_memcached.sh
sh pipeline/test/smoke_lighttpd.sh
sh pipeline/test/smoke_nginx.sh
sh pipeline/test/smoke_wget.sh
sh pipeline/test/smoke_curl.sh
```

`wget` and `curl` are clients, so their smoke tests first start a local test server inside
the guest — the baseline lighttpd, serving HTTPS and gzip — and fetch from it. No network
access is needed.

Each script runs the sealed binary and the baseline binary in turn and reports per-variant
results. Only the *server* or the tool under test is instrumented; the clients
(`redis-cli`, `fetch`, `nc`, `openssl`) are always stock, and the guest carries them along
with the real, non-sealed `libssl.so.3`/`libcrypto.so.3` they link against.

*Expected:* `Smoke test: PASS` from each script, with every check passing for **both**
variants. Each sealed run first prints one `seal-init` line per compartment:

```
seal-init: zlib_merged    otype=1027 sysctl=0 root_tag=1 sealcap_tag=1
seal-init: pcre2_merged   otype=1026 sysctl=0 root_tag=1 sealcap_tag=1
seal-init: openssl_merged otype=1025 sysctl=0 root_tag=1 sealcap_tag=1
seal-init: nginx_merged   otype=1024 sysctl=0 root_tag=1 sealcap_tag=1
```

That is the sealing runtime coming up: `sysctl=0` means the compartment obtained the root
sealing capability from `security.cheri.sealcap`, `root_tag=1` and `sealcap_tag=1` that
the capability and the otype derived from it are validly tagged, and each compartment has
its own otype. The baseline runs print no such lines — that difference is the
instrumentation.

The checks marked `[openssl seal boundary]` and `[zlib seal boundary]` matter most: they
move real traffic across a sealed boundary rather than staying inside one compartment.

*Time:* a few minutes per application.

#### Scope of what this tier claims

**This tier claims the smoke tests only.**

For the paper we tested at two levels. The smoke tests above, and a second, heavier layer:
`pipeline/test/test_<app>.sh` runs each project's *own* upstream test suite — redis's Tcl
units, memcached's Perl `t/` suite, the `nginx-tests` suite, and scripted scenario sets
for lighttpd, wget and curl — against both variants, comparing them outcome by outcome so
that a sealed binary must never turn a passing test into a failing one.
[`run_tests.sh`](pipeline/test/run_tests.sh) drives all six. Those runs were done on the
Morello board, and the scripts are included here so you can read exactly what was covered.

We do **not** ask you to run them, and we do not claim them in this tier. Each upstream
suite brings its own toolchain — Tcl, Perl and its CPAN modules, the application source
trees, and a separate test repository for nginx — and standing all of that up inside the
emulator was too time-consuming to be a reasonable ask of a reviewer. The smoke tests are
what we claim under QEMU, and they are sufficient for the property at issue: they start
each sealed binary, drive real traffic across every sealed compartment boundary, and
compare against the baseline built from the same bitcode.

---

## Tier 4 — performance, not claimed

**The performance measurements are not claimed as part of this artifact evaluation.**

Every number in Section 6 was taken on an ARM Morello board running CheriBSD 25.03, and
since, unfortunately, we cannot provide reviewers with access to a Morello box, we
exclude it from the evaluation.

**QEMU cannot substitute.** CheriBSD's own documentation describes QEMU as *ISA-level
emulation*: it models the instruction set, not timing. There is no cycle model, no cache
model, no memory hierarchy. A sealing overhead of ~1% is far below anything an ISA
emulator can express, and numbers taken under QEMU would be meaningless rather than
merely imprecise.

What we do provide is the measured data itself. Every raw CSV behind Figures 5–7 is
checked in under [`results/`](results/), together with the run logs, so the figures can
be regenerated and the numbers inspected without any hardware — that is
[Experiment 2](#experiment-2-figures-57). The methodology is described in
[`results/macrobenchmarks/README.md`](results/macrobenchmarks/README.md).

| Data | Location |
|---|---|
| Sealing macrobenchmark (Figure 6) | `results/macrobenchmarks/raw/sealing/` |
| calloc and heap-compartmentalization macrobenchmark (Figure 7) | `results/macrobenchmarks/raw/calloc/` |
| Allocator microbenchmark (Figure 5) | `results/microbenchmarks/raw/` |

---

## Expected variations

**memcached reports 13 shared struct types where Table 2 says 14.** The recorded run
attributed one argument of libevent's `event_base_loop` to `struct.eventop` rather than
to `struct.event_base`, its declared parameter type, which made `eventop` appear to be
shared. The analyzer now resolves that argument deterministically and the spurious type
is gone.

**Everything else in Tiers 1 and 2 is byte-identical**, and repeatable: running the same
input twice gives the same result.

---

## What cannot be reproduced, and why

**The performance measurements.** Out of scope for this evaluation — see
[Tier 4](#tier-4--performance-not-claimed). The measured data and run logs are included,
together with the harnesses that produced them under `microbenchmarks/` and
`macrobenchmarks/`; those run only on Morello hardware, and need the modified libc and
runtime linker described above.

---

## Platform requirement: CheriBSD 25.03

**Use CheriBSD 25.03. Other versions are not supported.**

Every measurement in the paper was taken on 25.03, and the artifact targets its
interfaces — library compartmentalization is enabled with `LD_COMPARTMENT_ENABLE=1`,
which is the 25.03 mechanism. Later CheriBSD releases changed it. We do not claim the
artifact works on any other release, and a newer guest may fail in ways that are not
loud: compartmentalization can decline to engage while the benchmarks still produce
plausible-looking numbers.

The guest image we ship for [Tier 3](#tier-3--optional-functional-testing-under-qemu)
is 25.03 by construction.

**The sealing capability.** `SealInstrumentationPass` emits a
`sysctlbyname("security.cheri.sealcap", ...)` call to obtain the root sealing capability,
then derives a per-compartment otype from it. This is an OS facility, so it behaves the
same under QEMU as on hardware, but it does mean the instrumented binaries need CheriBSD
— they will not run on a bare Morello FVP with no OS.

---

## FAQ

**Why are there tiers at all, and why does some material ship more than once?**
The guest image of Tier 3 already contains the repository, the compartment bitcode and
the binaries, all of which are also published as separate downloads. We could have put
everything in that one image and dispensed with tiers entirely.

We deliberately did not, because it would force every reviewer through QEMU to reach
results that need nothing of the sort. The analysis and instrumentation are the paper's
central claim, and they run on an ordinary x86-64 machine in about fifteen minutes; the
tables and figures need nothing but Python.

So the tiers are ordered by what they cost you, and each is self-contained. This does
lead to a bit of duplication in the downloads, but we hope it lets you get as far as your
setup and your time allow.

**Why is the toolchain shipped as a Docker image rather than build instructions?**
The bitcode was produced by `llvm-morello 15.0.d20250318`. That package has since been
removed from the CheriBSD package repository, and `cheribuild.py morello-llvm` now
builds LLVM 17, which rejects the bitcode outright:
`Not an enum attribute (Producer: 'LLVM15.0.0git' Reader: 'LLVM 17.0.0git')`. The only
remaining way to get the right toolchain is to rebuild it from source at one specific
revision, which the image does once. [`docker/README.md`](docker/README.md) names it.

**Why does Tier 3 ship prebuilt binaries instead of having me build them?**
Because QEMU is an ISA-level interpreter, and compilation under it is roughly two orders
of magnitude slower than on hardware. Linking the OpenSSL compartment alone measured 53
minutes in the guest, against a couple of minutes on the Morello board — and that is one
module of eighteen, before either variant of any application is linked. The binaries are
the output of the same pipeline you run yourself in Tier 2, and
[`pipeline/build/`](pipeline/build/) contains every script that produced them.

**Could I build the applications from source in the guest if I wanted to?**
Every script needed to do so is included: `pipeline/build/run_seal_analysis.sh` drives
the whole pipeline, from compiling each compartment through to linking the sealed and
baseline binaries. This is **not** something we claim in this artifact evaluation, and we
would not ask a reviewer to attempt it — under emulation it takes the better part of a
day per application. If it is of personal interest, though, everything you need is
already in the guest.

Two things to know if you do try it. It has to happen *inside* the guest rather than
cross-compiled from the host, because these configure systems decide what to build by
*running* test binaries on the target: nginx sizes its types by executing a probe,
lighttpd's CMake uses `try_run`, and each autoconf project needs a hand-written cache
entry for every check it cannot run. And the sources have to match the versions the paper
used — openssl 3.0.5, zlib 1.3.1, pcre2 10.42, libevent 2.1.12-stable, redis 7.0.12,
wget 1.21.4, curl 8.2.1, memcached 1.6.21, lighttpd 1.4.71, and for nginx the CHERI port
at `github.com/CTSRD-CHERI/nginx.git` commit `4628dae0`, **not** upstream nginx.

**Why does memcached report 13 shared struct types when Table 2 says 14?**
See [Expected variations](#expected-variations).

**Can I use a newer CheriBSD than 25.03?**
No — see [Platform requirement](#platform-requirement-cheribsd-2503).
