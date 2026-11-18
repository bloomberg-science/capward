# The CAPWARD artifact-evaluation image

`capward-ae:llvm15` carries everything the artifact needs beyond Python: Morello LLVM
15.0.d20250318, a CheriBSD 25.03 purecap sysroot, and Rocq 9.2. It serves
[Tier 2](../ARTIFACT-EVALUATION.md#tier-2--the-analysis-and-instrumentation-with-docker)
and the Tier 1 proofs.

Most evaluators do not need to build it. The prebuilt image is on Zenodo:

```sh
zstd -d capward-ae-llvm15.tar.zst -c | docker load
```

## Using it

The image carries the toolchain, not the repository — mount your checkout:

```sh
docker run --rm -it -v "$PWD":/capward capward-ae:llvm15
```

| | |
|---|---|
| `/opt/morello-llvm` | Morello LLVM 15.0.d20250318 (`clang`, `opt`, `llvm-link`, `lld`, `libLLVM.so`) |
| `/opt/cheribsd-sysroot-purecap` | CheriBSD 25.03 purecap sysroot |
| `/home/rocq/.opam/4.14.2+flambda` | Rocq 9.2, for the proofs |

`LLVM_PREFIX`, `SYSROOT`, `SYSTEM_INCLUDE_DIR`, `CHERI_TARGET`, `CMAKE` and `REPO_DIR`
are already set, so `pipeline/set_env.sh` needs no arguments inside the container.

## Building it yourself

```sh
docker build -t capward-ae:llvm15 docker/
```

Roughly 25 minutes on 64 cores, most of it LLVM.

Behind a proxy, pass it as a build argument so it is not baked into the image:

```sh
docker build --build-arg http_proxy="$http_proxy" \
             --build-arg https_proxy="$https_proxy" \
             -t capward-ae:llvm15 docker/
```

If that proxy also intercepts TLS, the `https` downloads fail with
`curl: (60) SSL certificate problem`. Put your organisation's root CA in
[`certs/`](certs/) as a `.crt` file and rebuild.

## Which LLVM revision

Pinned to `d34e0f94b8180e9a4f2fd27da8b7b7f7d296bc13` from
`git.morello-project.org/morello/llvm-project` — the revision CheriBSD packaged as
`llvm-morello-15.0.d20250318`. The cmake flags in the Dockerfile are that port's own.
