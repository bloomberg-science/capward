// Copyright 2026 Bloomberg Finance L.P.
// Distributed under the terms of the MIT license.

#pragma once
#include <stdint.h>

typedef enum {
  MODE_ALLOC = 0,
  MODE_CALL  = 1,
} my_mode_t;

typedef enum {
  PATTERN_RR      = 0,
  PATTERN_BURST   = 1,
  PATTERN_ZIPF    = 2,
  PATTERN_PHASED  = 3,
  PATTERN_PRODCON = 4,
  PATTERN_SEQ     = 5,
} pattern_t;

typedef enum {
  SIZE_SMALL = 0,
  SIZE_MIXED = 1,
} size_profile_t;

typedef enum {
  ALLOC_MALLOC = 0,
  ALLOC_CALLOC = 1,
} alloc_fn_t;

typedef struct {
  my_mode_t         mode;
  uint32_t       comps;
  uint32_t       threads;
  uint64_t       ops_per_thread;
  uint64_t       seed;

  pattern_t      pattern;
  uint32_t       burst_len;

  uint32_t       live;
  uint32_t       free_pct;
  uint32_t       remote_free;
  size_profile_t size_profile;

  uint32_t       fixed_size; // 0 = disabled
  alloc_fn_t     alloc_fn;
} bench_params_t;

typedef struct {
  double   seconds;
  double   ops_per_sec;
  uint64_t allocs;
  uint64_t frees;
  uint64_t remote_frees;
  uint64_t checksum;
} bench_result_t;
