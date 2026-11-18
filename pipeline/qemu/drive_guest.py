#!/usr/bin/env python3
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

"""Drive the CheriBSD QEMU guest over its serial console, expect-style.

Waits for prompts instead of sleeping blindly, which is what made the
fixed-delay shell drivers fragile. Usage:

    python3 gdrive.py <logfile> <cmd1> [cmd2 ...]

Boots the installed disk image, logs in as root, runs each command, prints
the transcript, then halts the guest.
"""
import os, pty, re, select, subprocess, sys, time

HOME = os.path.expanduser("~")
QEMU = f"{HOME}/cheri/output/sdk/bin/qemu-system-morello"
IMGDIR = f"{HOME}/cheri/images"
DISK = f"{IMGDIR}/cheribsd-25.03-disk.img"

ANSI = re.compile(rb"\x1b\[[0-9;?]*[a-zA-Z]|\x1b[()][B0]|\r")


def clean(b):
    return ANSI.sub(b"", b).replace(b"\x00", b"")


def main():
    logfile = sys.argv[1]
    cmds = sys.argv[2:]
    extra = []
    if os.environ.get("ATTACH_MEMSTICK"):
        extra = [
            "-drive", f"if=none,file={IMGDIR}/cheribsd-memstick-arm64-aarch64c-25.03.img,id=m,format=raw",
            "-device", "virtio-blk-pci,drive=m",
        ]
    argv = [
        QEMU, "-M", "virt,gic-version=3", "-cpu", "morello",
        "-bios", "edk2-aarch64-code.fd", "-m", os.environ.get("GUEST_MEM", "4096"),
        "-nographic",
        "-drive", f"if=none,file={DISK},id=hd,format=raw",
        "-device", "virtio-blk-pci,drive=hd",
        "-device", "virtio-net-pci,netdev=n0",
        "-netdev", "user,id=n0" + (f",hostfwd=tcp:127.0.0.1:{os.environ['SSHFWD']}-:22" if os.environ.get("SSHFWD") else ""),
        "-device", "virtio-rng-pci",
    ] + extra

    master, slave = pty.openpty()
    p = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave,
                         cwd=IMGDIR, close_fds=True)
    os.close(slave)

    buf = b""
    log = open(logfile, "wb")
    deadline = time.time() + int(os.environ.get("GUEST_TIMEOUT", "3600"))

    def pump(until, timeout):
        """Read until regex `until` matches or timeout. Returns True on match."""
        nonlocal buf
        end = time.time() + timeout
        while time.time() < end:
            r, _, _ = select.select([master], [], [], 1.0)
            if r:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    return False
                if not chunk:
                    return False
                log.write(chunk); log.flush()
                buf += clean(chunk)
                if len(buf) > 400000:
                    buf = buf[-200000:]
                if until.search(buf):
                    return True
        return False

    def send(s):
        os.write(master, s.encode() + b"\n")

    LOGIN = re.compile(rb"login:\s*$", re.M)
    PROMPT = re.compile(rb"root@[\w.-]*:[^\n]*#\s*$", re.M)

    try:
        if not pump(LOGIN, 600):
            print("!! never reached login prompt", file=sys.stderr)
            return 2
        buf = b""
        send("root")
        if not pump(PROMPT, 180):
            print("!! never reached root shell", file=sys.stderr)
            return 3

        for c in cmds:
            buf = b""
            print(f"\n===> {c}", flush=True)
            send(c)
            # generous per-command budget: package installs are slow emulated
            ok = pump(PROMPT, min(int(os.environ.get("CMD_TIMEOUT", "1800")),
                                  max(60, int(deadline - time.time()))))
            out = buf.decode("utf-8", "replace")
            # strip the echoed command and the trailing prompt
            lines = [l for l in out.splitlines()
                     if l.strip() and not l.strip().startswith("root@")]
            if lines and lines[0].strip() == c.strip():
                lines = lines[1:]
            print("\n".join(lines[:200]), flush=True)
            if not ok:
                print(f"!! timed out waiting for prompt after: {c}", file=sys.stderr)
                break

        buf = b""
        send("halt -p")
        pump(re.compile(rb"All buffers synced|Uptime:"), 180)
        time.sleep(8)
    finally:
        log.close()
        try:
            p.terminate(); p.wait(timeout=25)
        except Exception:
            p.kill()
    return 0


if __name__ == "__main__":
    sys.exit(main())
