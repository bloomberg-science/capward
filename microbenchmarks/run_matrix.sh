#!/bin/sh
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

set -eu

# ------------------- CONFIG -------------------
# Every value below is overridable from the environment, and the defaults match
# pipeline/set_env.sh — change them THERE, not here:
#
#   MODIFIED_LIBC=/path/to/libc.modified.perarena \
#   BASELINE_LIBC=/path/to/libc.baseline \
#       ./run_matrix.sh --out results.csv --no-call --tcache
#
# The two runtime trees are NOT part of this repository; each must contain
# ld-elf.so.1 and libc.so.7. See README.md.
BASELINE_LIBC="${BASELINE_LIBC:-$HOME/libc.baseline}"
MODIFIED_LIBC="${MODIFIED_LIBC:-$HOME/libc.modified.perarena}"

MOD_RTLD="${MOD_RTLD:-$MODIFIED_LIBC/ld-elf.so.1}"
MOD_LIBC_DIR="${MOD_LIBC_DIR:-$MODIFIED_LIBC}"
BASELINE_RTLD="${BASELINE_RTLD:-$BASELINE_LIBC/ld-elf.so.1}"
BASELINE_LIBC_DIR="${BASELINE_LIBC_DIR:-$BASELINE_LIBC}"

BENCH="${BENCH:-./build/bench_driver}"
TIME_CMD="${TIME_CMD:-/usr/bin/time -l}"

DEFAULT_SEED=10000
DEFAULT_REPS_PER_SEED=10

OUT="results.csv"
#COMPS_LIST="1 2 4 8 16 32 64 128"
COMPS_LIST="2 8 16 64"
THREADS_LIST="1 4 8"

MODE_ALLOC=1
MODE_CALL=1

OPS_ALLOC=20000
OPS_ALLOC_SMALL=200000
OPS_CALL=500000

LIVE=4096
FREE_PCT=0
REMOTE_FREE=0
SIZES="mixed"
#FIXED_SIZES="16 32 64 128 256 512 1024 4096 65536 1048576"
FIXED_SIZES="64 256 1024 4096 16384 65536"
#FIXED_SIZES="-1"

PATTERN_LIST="rr"
BURST_LEN=1024

PIN=1
TCACHE=0

SEEDS_LIST=""
NUM_SEEDS=0
REPS_PER_SEED="$DEFAULT_REPS_PER_SEED"
SEED="$DEFAULT_SEED"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
Usage: $0 [options]
  --out FILE
  --comps-list "1 2 4"
  --threads-list "1 2 4"
  --seeds-list "100 200" | --num-seeds N
  --reps-per-seed N
  --no-alloc | --no-call
  --ops-alloc N | --ops-call N
  --live N --free-pct P --remote-free 0|1 --sizes small|mixed --fixed-sizes comma-separated-list
  --pattern rr|burst|zipf|phased|prodcon
  --pattern-list "rr zipf phased prodcon"
  --burst-len N
  --seed N
  --no-pin
  --tcache             Enable tcache (default: disabled)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2;;
    --comps-list) COMPS_LIST="$2"; shift 2;;
    --threads-list) THREADS_LIST="$2"; shift 2;;

    --seeds-list) SEEDS_LIST="$2"; shift 2;;
    --num-seeds) NUM_SEEDS="$2"; shift 2;;
    --reps-per-seed) REPS_PER_SEED="$2"; shift 2;;

    --no-alloc) MODE_ALLOC=0; shift 1;;
    --no-call) MODE_CALL=0; shift 1;;

    --ops-alloc) OPS_ALLOC="$2"; OPS_ALLOC_SMALL="$2"; shift 2;;
    --ops-call) OPS_CALL="$2"; shift 2;;

    --live) LIVE="$2"; shift 2;;
    --free-pct) FREE_PCT="$2"; shift 2;;
    --remote-free) REMOTE_FREE="$2"; shift 2;;
    --sizes) SIZES="$2"; shift 2;;
    --fixed-sizes) FIXED_SIZES="$2"; shift 2;;

    --pattern) PATTERN_LIST="$2"; shift 2;;
    --pattern-list) PATTERN_LIST="$2"; shift 2;;
    --burst-len) BURST_LEN="$2"; shift 2;;

    --seed) SEED="$2"; shift 2;;
    --no-pin) PIN=0; shift 1;;
    --tcache) TCACHE=1; shift 1;;

    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 1;;
  esac
done

if [ ! -x "$BENCH" ]; then
  echo "ERROR: benchmark not found/executable: $BENCH" >&2
  exit 2
fi

if [ ! -f "$OUT" ]; then
  echo "ts,variant,mode,comps,threads,seed_index,fixed_size,seed_rep,pattern,burst_len,ops_per_thread,live,free_pct,remote_free,sizes,alloc_fn,seed,seconds,ops_per_sec,allocs,frees,remote_frees,trace_digest,count_64k,count_1m,checksum,maxrss_kb,cmd" > "$OUT"
fi

# Only take the primary CPU mask line (avoid domain-policy masks).
allowed_cpus() {
  if have_cmd cpuset; then
    cpuset -g -p $$ 2>/dev/null \
      | awk -F'mask: ' '/^pid[[:space:]]+[0-9]+[[:space:]]+mask: / {print $2; exit}' \
      | tr -d ' \t\r'
  else
    echo ""
  fi
}

mask_to_list() {
  m="$1"
  out=""
  oldIFS="$IFS"
  IFS=","
  for part in $m; do
    IFS="$oldIFS"
    case "$part" in
      *-*)
        lo="$(echo "$part" | awk -F- '{print $1}')"
        hi="$(echo "$part" | awk -F- '{print $2}')"
        if have_cmd jot; then
          out="$out $(jot - $lo $hi)"
        fi
        ;;
      *)
        out="$out $part"
        ;;
    esac
    IFS=","
  done
  IFS="$oldIFS"
  echo "$out" | awk '{$1=$1;print}'
}

pin_prefix() {
  t="$1"
  if [ "$PIN" -ne 1 ] || ! have_cmd cpuset; then
    echo ""
    return 0
  fi

  mask="$(allowed_cpus)"
  if [ -n "$mask" ]; then
    lst="$(mask_to_list "$mask")"
    if [ -n "$lst" ]; then
      sel=""
      n=0
      for cpu in $lst; do
        sel="$sel $cpu"
        n=$((n+1))
        [ "$n" -ge "$t" ] && break
      done
      sel="$(echo "$sel" | awk '{$1=$1;print}')"
      cpu_list="$(echo "$sel" | tr ' ' ',')"
      echo "cpuset -l $cpu_list"
      return 0
    fi
  fi

  ncpu="$(sysctl -n hw.ncpu 2>/dev/null || sysctl -n kern.smp.cpus 2>/dev/null || echo 1)"
  [ -z "$ncpu" ] && ncpu=1
  if [ "$t" -le 1 ]; then
    echo "cpuset -l 0"
  else
    hi=$((t-1))
    max=$((ncpu-1))
    [ "$hi" -gt "$max" ] && hi="$max"
    echo "cpuset -l 0-$hi"
  fi
}

# Map variant -> alloc_fn (only meaningful in alloc mode)
alloc_fn_for_variant() {
  v="$1"
  if [ "$v" = "calloc" ]; then
    echo "calloc"
  else
    echo "malloc"
  fi
}

# Map variant -> environment prefix
env_prefix_for_variant() {
  variant="$1"

  # Build MALLOC_CONF based on variant and tcache setting
  if [ "$TCACHE" -eq 1 ]; then
    tcache_conf=""
  else
    tcache_conf="tcache:false"
  fi

  # Baseline and calloc are stock runtime: no modified rtld, no modified libc.
  if [ "$variant" = "baseline" ] || [ "$variant" = "calloc" ]; then
    if [ -n "$tcache_conf" ]; then
      echo "LD_COMPARTMENT_ENABLE=1 LD_LIBRARY_PATH=$BASELINE_LIBC_DIR LD_PRELOAD= LD_LIBMAP= LD_ELF_HINTS_PATH= MALLOC_CONF=$tcache_conf"
    else
      echo "LD_COMPARTMENT_ENABLE=1 LD_LIBRARY_PATH=$BASELINE_LIBC_DIR LD_PRELOAD= LD_LIBMAP= LD_ELF_HINTS_PATH="
    fi
    return 0
  fi

  # Modified variants require these paths.
  if [ -z "${MOD_LIBC_DIR:-}" ] || [ -z "${MOD_RTLD:-}" ]; then
    echo "ERROR: MOD_LIBC_DIR and MOD_RTLD must be set for variant=$variant" >&2
    exit 2
  fi

  if [ "$variant" = "modified_disabled" ]; then
    if [ -n "$tcache_conf" ]; then
      echo "LD_COMPARTMENT_ENABLE=1 LD_LIBRARY_PATH=$MOD_LIBC_DIR LD_PRELOAD= LD_LIBMAP= LD_ELF_HINTS_PATH= MALLOC_CONF=heap_compartment:false,$tcache_conf"
    else
      echo "LD_COMPARTMENT_ENABLE=1 LD_LIBRARY_PATH=$MOD_LIBC_DIR LD_PRELOAD= LD_LIBMAP= LD_ELF_HINTS_PATH= MALLOC_CONF=heap_compartment:false"
    fi
  else
    if [ -n "$tcache_conf" ]; then
      echo "LD_COMPARTMENT_ENABLE=1 LD_LIBRARY_PATH=$MOD_LIBC_DIR LD_PRELOAD= LD_LIBMAP= LD_ELF_HINTS_PATH= MALLOC_CONF=heap_compartment:true,$tcache_conf"
    else
      echo "LD_COMPARTMENT_ENABLE=1 LD_LIBRARY_PATH=$MOD_LIBC_DIR LD_PRELOAD= LD_LIBMAP= LD_ELF_HINTS_PATH= MALLOC_CONF=heap_compartment:true"
    fi
  fi
}

kv_get() {
  key="$1"
  line="$2"
  echo "$line" | awk -v k="$key" '{
    for(i=1;i<=NF;i++){
      split($i,a,"=");
      if(a[1]==k){print a[2]; exit}
    }
  }'
}

run_one() {
  variant="$1"
  mode="$2"
  comps="$3"
  threads="$4"
  seed_index="$5"
  seed_rep="$6"
  seed="$7"
  fs="$8"

  alloc_fn="$(alloc_fn_for_variant "$variant")"
  env_cmd="$(env_prefix_for_variant "$variant")"
  pin="$(pin_prefix "$threads")"

  if [ "$mode" = "alloc" ]; then
    # Use higher ops count for small fixed sizes to get stable measurements.
    if [ "$fs" != "-1" ] && [ "$fs" -le 1024 ] 2>/dev/null; then
      ops="$OPS_ALLOC_SMALL"
    else
      ops="$OPS_ALLOC"
    fi
    args="--mode alloc --comps $comps --threads $threads --pattern $PATTERN --burst-len $BURST_LEN --seed $seed --ops $ops --live $LIVE --free-pct $FREE_PCT --remote-free $REMOTE_FREE --sizes $SIZES --alloc-fn $alloc_fn"
  else
    ops="$OPS_CALL"
    args="--mode call --comps $comps --threads $threads --pattern $PATTERN --burst-len $BURST_LEN --seed $seed --ops $ops"
  fi

  # Only pass fixed-size if not sentinel
  if [ "$fs" != "-1" ]; then
    args="$args --fixed-size $fs"
  fi

  exec_cmd="$BASELINE_RTLD $BENCH $args"
  # Only modified_* variants run under the modified rtld.
  if [ "$variant" = "modified_disabled" ] || [ "$variant" = "modified_enabled" ]; then
    exec_cmd="$MOD_RTLD $BENCH $args"
  fi

  tmpout="$(mktemp)"
  tmperr="$(mktemp)"

  printf '%s\n' "RUN start: variant=$variant mode=$mode comps=$comps threads=$threads seed_index=$seed_index seed_rep=$seed_rep seed=$seed alloc_fn=$alloc_fn" >&2
  printf '%s\n' "RUN cmd:   $(printf "%s %s %s %s" "$env_cmd" "$pin" "$TIME_CMD" "$exec_cmd" | sed 's/  */ /g')" >&2

  # shellcheck disable=SC2086
  sh -c "$env_cmd $pin $TIME_CMD $exec_cmd" >"$tmpout" 2>"$tmperr" || {
    echo "Run failed: $variant $mode comps=$comps threads=$threads seed=$seed" >&2
    cat "$tmperr" >&2
    rm -f "$tmpout" "$tmperr"
    return 1
  }

  maxrss_kb=""
  if grep -q "maximum resident set size" "$tmperr" 2>/dev/null; then
    maxrss_kb="$(grep "maximum resident set size" "$tmperr" | awk '{print $1}' | tail -n 1)"
  fi

  line="$(grep '^RESULT ' "$tmpout" | tail -n 1 || true)"
  if [ -z "$line" ]; then
    echo "ERROR: no RESULT line found" >&2
    cat "$tmpout" >&2
    cat "$tmperr" >&2
    rm -f "$tmpout" "$tmperr"
    return 1
  fi

  seconds="$(kv_get seconds "$line")"
  opsps="$(kv_get ops_per_sec "$line")"
  allocs="$(kv_get allocs "$line")"
  frees="$(kv_get frees "$line")"
  rfrees="$(kv_get remote_frees "$line")"
  tdigest="$(kv_get trace_digest "$line")"
  c64k="$(kv_get count_64k "$line")"
  c1m="$(kv_get count_1m "$line")"
  cksum="$(kv_get checksum "$line")"

  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  cmd_str="$(printf "%s %s %s" "$env_cmd" "$pin" "$exec_cmd" | sed 's/  */ /g')"

  echo "$ts,$variant,$mode,$comps,$threads,$seed_index,$fs,$seed_rep,$PATTERN,$BURST_LEN,$ops,$LIVE,$FREE_PCT,$REMOTE_FREE,$SIZES,$alloc_fn,$seed,$seconds,$opsps,$allocs,$frees,$rfrees,$tdigest,$c64k,$c1m,$cksum,$maxrss_kb,\"$cmd_str\"" >> "$OUT"

  rm -f "$tmpout" "$tmperr"
}

# Seeds to run
seeds_to_run="$SEEDS_LIST"
if [ -z "$seeds_to_run" ] && [ "$NUM_SEEDS" -gt 0 ]; then
  i=0
  seeds_to_run=""
  while [ "$i" -lt "$NUM_SEEDS" ]; do
    seeds_to_run="$seeds_to_run $((SEED + i))"
    i=$((i+1))
  done
fi
if [ -z "$seeds_to_run" ]; then
  seeds_to_run="$SEED"
fi


# User may set FIXED_SIZES to something like:
#   FIXED_SIZES="16 32 64 128 256 512 1024 4096 65536 1048576"
# If it's unset/empty, we use a single sentinel value "-1".
FIXED_SIZES="${FIXED_SIZES:-}"
[ -n "$FIXED_SIZES" ] || FIXED_SIZES="-1"

# The four variants:
#  1) baseline (malloc)
#  2) calloc   (calloc)
#  3) modified_disabled (malloc)
#  4) modified_enabled  (malloc)
VARIANTS="baseline calloc modified_disabled modified_enabled"

for PATTERN in $PATTERN_LIST; do
  for fs in $FIXED_SIZES; do
    for comps in $COMPS_LIST; do
      for threads in $THREADS_LIST; do
        seed_index=0
        for seed_run in $seeds_to_run; do
          seed_index=$((seed_index+1))
          seed_rep=1
          while [ "$seed_rep" -le "$REPS_PER_SEED" ]; do
            if [ "$MODE_CALL" -eq 1 ]; then
              for v in $VARIANTS; do
                run_one "$v" call "$comps" "$threads" "$seed_index" "$seed_rep" "$seed_run" "$fs"
              done
            fi

            if [ "$MODE_ALLOC" -eq 1 ]; then
              for v in $VARIANTS; do
                run_one "$v" alloc "$comps" "$threads" "$seed_index" "$seed_rep" "$seed_run" "$fs"
              done
            fi

            seed_rep=$((seed_rep+1))
          done
        done
      done
    done
  done
done
