#!/usr/bin/env python3
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

import argparse
from pathlib import Path

H_TEMPLATE = r"""#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {{
#endif

void*   {sym}_malloc(size_t sz);
void*   {sym}_calloc(size_t n, size_t sz);
void    {sym}_free(void* p);
uint64_t {sym}_ping(uint64_t x);

#ifdef __cplusplus
}}
#endif
"""

C_TEMPLATE = r"""#include "{sym}.h"
#include <stdlib.h>
#include <stdint.h>

/*
 * Simple libc wrappers, one DSO per compartment/library.
 * These call through to libc malloc/calloc/free.
 */

static volatile uint64_t g_sink = 0;

void* {sym}_malloc(size_t sz) {{
  void* p = malloc(sz);
  char *c = (char*)p+10;
  *c = 'h';
  return p;
}}

void* {sym}_calloc(size_t n, size_t sz) {{
  void* p = calloc(n, sz);
  char *c = (char*)p+10;
  *c = 'h';
  return p;
}}

void {sym}_free(void* p) {{
  free(p);
  g_sink ^= (uint64_t)(uintptr_t)p;
}}

uint64_t {sym}_ping(uint64_t x) {{
  x ^= g_sink;
  x ^= (x >> 33);
  x *= 0xff51afd7ed558ccdULL;
  x ^= (x >> 33);
  return x;
}}
"""

DISPATCH_H_TOP = r"""#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Generated maximum number of compartments compiled in.
extern const unsigned comp_max;

// comp_id is 0-based: [0, comp_max)
void*    comp_dispatch_malloc(unsigned comp_id, size_t sz);
void*    comp_dispatch_calloc(unsigned comp_id, size_t n, size_t sz);
void     comp_dispatch_free  (unsigned comp_id, void* p);
uint64_t comp_dispatch_ping  (unsigned comp_id, uint64_t x);

#ifdef __cplusplus
}
#endif
"""

def gen_dispatch_c(prefix: str, n: int) -> str:
    lines = []
    lines.append('#include "comp_dispatch.h"')
    for i in range(1, n+1):
        suf = f"{i:03d}"
        sym = f"{prefix}{suf}"
        lines.append(f'#include "{sym}.h"')
    lines.append("")
    lines.append(f"const unsigned comp_max = {n};")
    lines.append("")
    lines.append("void* comp_dispatch_malloc(unsigned comp_id, size_t sz) {")
    lines.append("  switch (comp_id) {")
    for i in range(1, n+1):
        suf = f"{i:03d}"
        sym = f"{prefix}{suf}"
        lines.append(f"    case {i-1}: return {sym}_malloc(sz);")
    lines.append("    default: return 0;")
    lines.append("  }")
    lines.append("}")
    lines.append("")
    lines.append("void* comp_dispatch_calloc(unsigned comp_id, size_t n, size_t sz) {")
    lines.append("  switch (comp_id) {")
    for i in range(1, n+1):
        suf = f"{i:03d}"
        sym = f"{prefix}{suf}"
        lines.append(f"    case {i-1}: return {sym}_calloc(n, sz);")
    lines.append("    default: return 0;")
    lines.append("  }")
    lines.append("}")
    lines.append("")
    lines.append("void comp_dispatch_free(unsigned comp_id, void* p) {")
    lines.append("  switch (comp_id) {")
    for i in range(1, n+1):
        suf = f"{i:03d}"
        sym = f"{prefix}{suf}"
        lines.append(f"    case {i-1}: {sym}_free(p); return;")
    lines.append("    default: return;")
    lines.append("  }")
    lines.append("}")
    lines.append("")
    lines.append("uint64_t comp_dispatch_ping(unsigned comp_id, uint64_t x) {")
    lines.append("  switch (comp_id) {")
    for i in range(1, n+1):
        suf = f"{i:03d}"
        sym = f"{prefix}{suf}"
        lines.append(f"    case {i-1}: return {sym}_ping(x);")
    lines.append("    default: return x;")
    lines.append("  }")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="gen", help="output directory")
    ap.add_argument("--n", type=int, default=128, help="number of compartments/DSOs")
    ap.add_argument("--prefix", default="comp", help="library prefix (default: comp)")
    args = ap.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    for i in range(1, args.n + 1):
        suf = f"{i:03d}"
        sym = f"{args.prefix}{suf}"
        (out / f"{sym}.h").write_text(H_TEMPLATE.format(sym=sym))
        (out / f"{sym}.c").write_text(CreativeTemplate := C_TEMPLATE.format(sym=sym))

    (out / "comp_dispatch.h").write_text(DISPATCH_H_TOP)
    (out / "comp_dispatch.c").write_text(gen_dispatch_c(args.prefix, args.n))
    print(f"Generated {args.n} DSOs sources + dispatcher under: {out}/")

if __name__ == "__main__":
    main()
