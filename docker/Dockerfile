# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

# CAPWARD artifact-evaluation image
#
# Supplies the one thing an evaluator cannot obtain any other way: the exact
# Morello LLVM the paper's toolchain depends on.
#
# WHY THIS IMAGE EXISTS. The artifact's bitcode was produced by
# llvm-morello 15.0.d20250318. That package has been REMOVED from the CheriBSD
# package repository, and the LLVM 17 successor cannot read the bitcode at all:
#
#     opt: redis_merged.bc: error: Not an enum attribute
#          (Producer: 'LLVM15.0.0git'  Reader: 'LLVM 17.0.0git')
#
# So the toolchain has to be rebuilt from source at the exact revision. This
# image does that once, here, so that evaluators do not have to.
#
# WHERE THE REVISION COMES FROM. CheriBSD's devel/llvm-morello port records the
# snapshot it packaged in devel/llvm-morello/Makefile.snapshot. At ports commit
# b5262edf (2025-03-31, which is the build date stamped into the installed
# package) that file reads:
#
#     LLVM_MAJOR=  15
#     SNAPDATE=    20250318
#     LLVM_COMMIT= d34e0f94b8180e9a4f2fd27da8b7b7f7d296bc13
#
# The cmake flags below are taken from the same port (devel/llvm-cheri/Makefile)
# so this build matches the packaged one rather than merely resembling it.
#
# BUILD (64-core host, roughly 25 minutes):
#   docker build -t capward-ae:llvm15 docker/
#
# Behind a proxy, pass it as a build argument rather than baking it in:
#   docker build --build-arg http_proxy=$http_proxy \
#                --build-arg https_proxy=$https_proxy -t capward-ae:llvm15 docker/
#
# If that proxy also intercepts TLS, every https download here fails with
# "curl: (60) SSL certificate problem". Drop your organisation's root CA into
# docker/certs/ as a .crt file and it will be trusted in each build stage.
# The directory ships empty, so this costs nothing when it is not needed.
#
# USE (the image carries the toolchain; mount your own checkout):
#   docker run --rm -it -v /path/to/capward:/capward capward-ae:llvm15

# =============================================================================
# Stage 1 — build Morello LLVM 15 from the pinned revision
# =============================================================================
FROM ubuntu:22.04 AS llvm-builder

# ARG, not ENV: build-time proxy settings must not persist into the shipped
# image. A Zenodo artifact carrying a corporate proxy address would be both
# leaky and broken for everyone else.
ARG http_proxy
ARG https_proxy
ARG no_proxy

ARG LLVM_COMMIT=d34e0f94b8180e9a4f2fd27da8b7b7f7d296bc13
ARG LLVM_PREFIX=/opt/morello-llvm

# Matches LLVM_TARGETS in devel/llvm-morello/Makefile. X86 is the host; AArch64
# is Morello. ARM and BPF are carried only to keep parity with the package.
ARG LLVM_TARGETS="AArch64;ARM;BPF;X86"

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        cmake \
        curl \
        git \
        libncurses-dev \
        ninja-build \
        python3 \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Empty unless an evaluator supplies a CA for a TLS-intercepting proxy.
COPY certs/ /usr/local/share/ca-certificates/
RUN update-ca-certificates

WORKDIR /src
RUN curl -fsSL \
      "https://git.morello-project.org/morello/llvm-project/-/archive/${LLVM_COMMIT}/llvm-project-${LLVM_COMMIT}.tar.gz" \
    | tar xz \
    && mv "llvm-project-${LLVM_COMMIT}" llvm-project

# LLVM_BUILD_LLVM_DYLIB/LLVM_LINK_LLVM_DYLIB are REQUIRED, not a size
# optimisation: pipeline/build/passes/build_passes_morello.sh links each pass
# plugin against -lLLVM, so libLLVM.so must exist in $LLVM_PREFIX/lib.
#
# CLANG_DEFAULT_LINKER=lld matches how this toolchain behaves on CheriBSD, where
# /usr/bin/ld IS lld, so the build scripts never had to ask for it. On a Linux
# host clang would otherwise invoke the GNU ld in /usr/bin and fail with
# "unrecognised emulation mode: aarch64elf_cheri". Setting it here keeps the
# purecap link working without a -fuse-ld flag in ten separate build scripts.
#
# LLVM_DEFAULT_TARGET_TRIPLE is deliberately NOT set. On the Morello box the
# native triple is aarch64-unknown-freebsd15.0, so a bare clang++ built the
# passes natively. Here the host is x86-64 Linux and the pass plugins must be
# native x86-64 shared objects, so the default triple stays the host's and the
# purecap target is named explicitly at cross-compile time instead.
RUN cmake -S /src/llvm-project/llvm -B /src/build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${LLVM_PREFIX}" \
        -DLLVM_ENABLE_PROJECTS="clang;lld" \
        -DLLVM_TARGETS_TO_BUILD="${LLVM_TARGETS}" \
        -DLLVM_BUILD_LLVM_DYLIB=ON \
        -DLLVM_LINK_LLVM_DYLIB=ON \
        -DLLVM_INSTALL_UTILS=ON \
        -DLLVM_ENABLE_ASSERTIONS=OFF \
        -DLLVM_ENABLE_Z3_SOLVER=OFF \
        -DLLVM_ENABLE_LIBXML2=OFF \
        -DLLVM_ENABLE_LIBEDIT=OFF \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DCLANG_DEFAULT_LINKER=lld \
    && ninja -C /src/build \
    && ninja -C /src/build install

# =============================================================================
# Stage 2 — fetch the CheriBSD 25.03 purecap sysroot
# =============================================================================
#
# Deliberately NOT cheribuild's sdk-morello-purecap. That target builds CheriBSD
# from source: hours of work, and the result is a different tree from the 25.03
# release the paper measured on. The release's own aarch64c base.txz is the
# sysroot, matches 25.03 by construction, and is a 122 MB download.
#
# bsdtar, not GNU tar: FreeBSD distribution sets carry extended attributes that
# GNU tar mishandles.
FROM ubuntu:22.04 AS sysroot-builder

ARG http_proxy
ARG https_proxy
ARG no_proxy

ARG CHERIBSD_VERSION=25.03
ARG SYSROOT=/opt/cheribsd-sysroot-purecap

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl libarchive-tools \
    && rm -rf /var/lib/apt/lists/*

COPY certs/ /usr/local/share/ca-certificates/
RUN update-ca-certificates

RUN mkdir -p "${SYSROOT}" \
    && curl -fsSL \
        "https://download.cheribsd.org/releases/arm64/aarch64c/${CHERIBSD_VERSION}/ftp/base.txz" \
      | bsdtar -xf - -C "${SYSROOT}" \
        ./usr/include ./usr/lib ./usr/libdata ./lib \
    && rm -rf "${SYSROOT}/usr/lib/debug"

# =============================================================================
# Stage 3 — Rocq, for the Tier 1 proofs
# =============================================================================
#
# Taken from the official image rather than built with opam: the opam route
# compiles OCaml from source and takes half an hour, for the same result.
#
# The switch MUST land on the same path it had in the source image. findlib
# records its own absolute location, so relocating the tree makes rocq fail with
# "Config file not found - neither .../lib/findlib.conf nor ...".
#
# The version matters. These proofs need 9.2; under 9.1.0 CHERI_compartheap.v
# fails to parse.
FROM rocq/rocq-prover:9.2 AS rocq

ARG ROCQ_SWITCH=/home/rocq/.opam/4.14.2+flambda

# Strip what is only needed to BUILD OCaml code, not to run rocq: static
# archives, native and interface objects, IDE type info, sources and docs.
# The binaries, the .cmxs plugins and the .vo standard library all stay. Takes
# the switch from 1.9 GB to 1.1 GB, which is worth it for a published artifact.
USER root
RUN cd "${ROCQ_SWITCH}" \
    && find . \( -name '*.cmt' -o -name '*.cmti' -o -name '*.a' -o -name '*.cmx' \
                  -o -name '*.ml' -o -name '*.mli' -o -name '*.glob' \) -delete \
    && rm -rf man doc share/doc

# =============================================================================
# Stage 4 — the shipped image
# =============================================================================
FROM ubuntu:22.04

ARG http_proxy
ARG https_proxy
ARG no_proxy

LABEL org.opencontainers.image.title="CAPWARD artifact evaluation"
LABEL org.opencontainers.image.description="Morello LLVM 15.0.d20250318, a CheriBSD 25.03 purecap sysroot, and Rocq 9.2 for the CAPWARD artifact"
LABEL capward.llvm.commit="d34e0f94b8180e9a4f2fd27da8b7b7f7d296bc13"
LABEL capward.llvm.version="15.0.d20250318"
LABEL capward.cheribsd.version="25.03"
LABEL capward.rocq.version="9.2"

# Runtime for libLLVM.so, python3 for pipeline steps 4-5, and the autotools /
# perl needed by the application configure scripts when building on the host.
#
# g++ is not for compiling anything with gcc: it supplies the libstdc++ headers
# that the toolchain's own clang++ needs to build the pass plugins. Without it
# build_passes_morello.sh dies on "'cstddef' file not found".
#
# python3 matters: base CheriBSD has none, and cross_compartment_analyzer.py
# uses str.removeprefix, so 3.9 is the floor. Ubuntu 22.04 ships 3.10.
RUN apt-get update && apt-get install -y --no-install-recommends \
        autoconf \
        automake \
        bash \
        bzip2 \
        ca-certificates \
        cmake \
        curl \
        file \
        g++ \
        git \
        libtinfo6 \
        libtool \
        make \
        patch \
        perl \
        pkg-config \
        python3 \
        xz-utils \
        zlib1g \
    && rm -rf /var/lib/apt/lists/*

# Also in the shipped image: a host-side source build fetches tarballs at run time.
COPY certs/ /usr/local/share/ca-certificates/
RUN update-ca-certificates

COPY --from=llvm-builder   /opt/morello-llvm             /opt/morello-llvm
COPY --from=sysroot-builder /opt/cheribsd-sysroot-purecap /opt/cheribsd-sysroot-purecap
COPY --from=rocq /home/rocq/.opam/4.14.2+flambda /home/rocq/.opam/4.14.2+flambda

# The variables pipeline/set_env.sh reads. Setting them here means an evaluator
# can source set_env.sh inside the container with no arguments and have every
# required path resolve. set_env.sh honours anything already exported, so these
# are defaults, not impositions.
ENV LLVM_PREFIX=/opt/morello-llvm \
    LLVM_BIN=/opt/morello-llvm/bin \
    CMAKE=/usr/bin/cmake \
    SYSROOT=/opt/cheribsd-sysroot-purecap \
    SYSTEM_INCLUDE_DIR=/opt/cheribsd-sysroot-purecap/usr/include \
    SYSTEM_LIB_DIR=/opt/cheribsd-sysroot-purecap/usr/lib \
    CHERI_TARGET=aarch64-unknown-freebsd15.0 \
    REPO_DIR=/capward \
    PATH=/opt/morello-llvm/bin:/home/rocq/.opam/4.14.2+flambda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR /capward
CMD ["/bin/bash"]
