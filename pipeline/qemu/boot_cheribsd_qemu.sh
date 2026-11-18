#!/bin/sh
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

# boot_cheribsd_qemu.sh — Boot CheriBSD 25.03 under qemu-system-morello.
#
# For Tier 3 of ARTIFACT-EVALUATION.md: functional testing of the sealed
# binaries without Morello hardware. NOT for performance measurement — QEMU is
# an ISA-level emulator with no timing model, and the release kernel is built
# with INVARIANTS and WITNESS on top of that.
#
# Prerequisites:
#   1. qemu-system-morello, from cheribuild:
#        git clone https://github.com/CTSRD-CHERI/cheribuild.git
#        cd cheribuild && ./cheribuild.py qemu
#      Installs to $HOME/cheri/output/sdk/bin/. On macOS you also need Homebrew
#      cmake, ninja, make, libtool, glib, pkg-config, automake and autoconf.
#
#   2. The CheriBSD 25.03 purecap release image:
#        curl -LO https://download.cheribsd.org/releases/arm64/aarch64c/25.03/\
#   cheribsd-memstick-arm64-aarch64c-25.03.img.xz
#        xz -d cheribsd-memstick-arm64-aarch64c-25.03.img.xz
#      1.6 GB compressed, 3.1 GB raw. Use 25.03: the artifact targets its
#      interfaces and other releases are not supported.
#
# Usage:
#   sh pipeline/qemu/boot_cheribsd_qemu.sh              # boot the installer
#   sh pipeline/qemu/boot_cheribsd_qemu.sh --installed  # boot what you installed
#
# The image is INSTALLER media. On first run, install to $QEMU_DISK from the
# menu, then use --installed thereafter. To get a shell without installing at
# all, pick loader menu option 2 ("Boot Single user").
#
# Once installed, SSH in on localhost:$QEMU_SSH_PORT.

set -e

# Defaults match pipeline/set_env.sh — change them THERE, not here.
CHERI_DIR="${CHERI_DIR:-$HOME/cheri}"
QEMU_MORELLO="${QEMU_MORELLO:-$CHERI_DIR/output/sdk/bin/qemu-system-morello}"
QEMU_BIOS="${QEMU_BIOS:-edk2-aarch64-code.fd}"
QEMU_MEM="${QEMU_MEM:-2048}"
# Guest vCPUs. QEMU runs each as its own host thread (MTTCG), so this is worth
# raising well above 1 on a many-core host: it does not speed up a single
# monolithic LTO link, which is serial, but it lets independent builds run
# concurrently and makes `make -j` in the guest useful.
QEMU_SMP="${QEMU_SMP:-4}"
QEMU_SSH_PORT="${QEMU_SSH_PORT:-19507}"

# Control socket for the QEMU monitor. Without one, the monitor is multiplexed
# onto the serial console (Ctrl-A C) and is therefore lost with the terminal --
# and a guest whose terminal has gone cannot be shut down cleanly at all if you
# have no root shell inside it. With it, a clean ACPI poweroff is always one
# command away, from any shell on the host:
#
#   echo system_powerdown | nc -U -q1 $QEMU_MONITOR      # or socat - unix-connect:
#
# That is an ACPI power-button press, which FreeBSD handles as a clean
# shutdown, so it is safe to use when you have no root shell in the guest.
#
# Set QEMU_MONITOR= (empty) to omit it.
QEMU_MONITOR="${QEMU_MONITOR:-$CHERI_DIR/images/qemu-monitor-${CHERIBSD_VERSION:-25.03}.sock}"

CHERIBSD_VERSION="${CHERIBSD_VERSION:-25.03}"
CHERIBSD_IMG="${CHERIBSD_IMG:-$CHERI_DIR/images/cheribsd-memstick-arm64-aarch64c-${CHERIBSD_VERSION}.img}"
QEMU_DISK="${QEMU_DISK:-$CHERI_DIR/images/cheribsd-${CHERIBSD_VERSION}-disk.img}"
QEMU_DISK_SIZE="${QEMU_DISK_SIZE:-20G}"

BOOT_INSTALLED=0
[ "$1" = "--installed" ] && { BOOT_INSTALLED=1; shift; }

if [ ! -x "$QEMU_MORELLO" ]; then
    echo "ERROR: qemu-system-morello not found at $QEMU_MORELLO" >&2
    echo "  Build it with:  ./cheribuild.py qemu" >&2
    echo "  Or set QEMU_MORELLO to its location." >&2
    exit 1
fi

# The target disk persists the installed system across runs.
if [ ! -f "$QEMU_DISK" ]; then
    echo ">>> Creating $QEMU_DISK ($QEMU_DISK_SIZE)"
    mkdir -p "$(dirname "$QEMU_DISK")"
    "$(dirname "$QEMU_MORELLO")/qemu-img" create -f raw "$QEMU_DISK" "$QEMU_DISK_SIZE"
fi

# The machine is virt with a Morello CPU — NOT "-M morello", which exists but is
# not what CheriBSD expects. This invocation matches what
# `cheribuild.py run-morello-purecap --pretend` emits.
set -- -M virt,gic-version=3 -cpu morello \
       -bios "$QEMU_BIOS" -m "$QEMU_MEM" -smp "$QEMU_SMP" -nographic \
       -drive if=none,file="$QEMU_DISK",id=hd,format=raw \
       -device virtio-blk-pci,drive=hd \
       -device virtio-net-pci,netdev=net0 \
       -netdev user,id=net0,hostfwd=tcp:127.0.0.1:${QEMU_SSH_PORT}-:22 \
       -device virtio-rng-pci "$@"

# A stale socket from a previous run makes QEMU refuse to start.
if [ -n "$QEMU_MONITOR" ]; then
    rm -f "$QEMU_MONITOR"
    set -- "$@" -monitor "unix:$QEMU_MONITOR,server,nowait"
fi

if [ "$BOOT_INSTALLED" -eq 0 ]; then
    if [ ! -f "$CHERIBSD_IMG" ]; then
        echo "ERROR: installer image not found: $CHERIBSD_IMG" >&2
        echo "  Download and decompress the CheriBSD $CHERIBSD_VERSION release" >&2
        echo "  image, or set CHERIBSD_IMG. See the header of this script." >&2
        exit 1
    fi
    # Installer disk first so the firmware boots it rather than the blank target.
    set -- -drive if=none,file="$CHERIBSD_IMG",id=instm,format=raw \
           -device virtio-blk-pci,drive=instm "$@"
fi

echo "======================================================================"
echo "Booting CheriBSD $CHERIBSD_VERSION under qemu-system-morello"
echo "  installer: $([ "$BOOT_INSTALLED" -eq 0 ] && echo "$CHERIBSD_IMG" || echo "(skipped)")"
echo "  disk:      $QEMU_DISK"
echo "  ssh:       localhost:$QEMU_SSH_PORT  (once installed and sshd is up)"
echo "  cpus/mem:  $QEMU_SMP vCPU, $QEMU_MEM MB"
if [ -n "$QEMU_MONITOR" ]; then
    echo "  monitor:   $QEMU_MONITOR"
    echo "             clean shutdown from any host shell, no terminal needed:"
    echo "               echo system_powerdown | nc -U -q1 $QEMU_MONITOR"
fi
echo ""
echo "  Exit QEMU with Ctrl-A X. Run it under tmux so a dropped connection"
echo "  does not take the guest down with it."
echo "======================================================================"

exec "$QEMU_MORELLO" "$@"
