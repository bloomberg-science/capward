#!/bin/sh
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

# run_paper_matrix.sh — paper macrobenchmark matrix on CheriBSD/Morello
#
# Compares four runtime/allocator variants for nginx, lighttpd and redis:
#   baseline     stock allocator,        unmodified rtld+libc (libc.baseline)
#   calloc       malloc->calloc binary,  unmodified rtld+libc
#   compart_off  stock allocator,        modified rtld+libc, heap_compartment:false
#   compart_on   stock allocator,        modified rtld+libc, heap_compartment:true
#
# Methodology:
#   * A FRESH server process is started for every single measurement, so no
#     measurement is affected by warm-up or ordering of preceding tests.
#   * nginx runs with `master_process off` (no worker fork). Forking triggers a
#     CHERI revocation cost that would otherwise dominate the
#     compartmentalisation result.
#   * Client (ab / redis-benchmark) always runs on the STOCK system runtime;
#     only the server is wrapped by the modified rtld+libc.
#
# Usage:  REPS=5 sh run_paper_matrix.sh [nginx|lighttpd|redis ...]
# Output: results/<app>.csv  (columns: run,variant,test,rps)

# Defaults match pipeline/set_env.sh — change them THERE, not here.
REPS=${REPS:-5}
NREQ=${NREQ:-5000}       # ab requests per measurement (paper value 5000)
NOPS=${NOPS:-100000}     # redis-benchmark ops per measurement
R=${REPO_DIR:-$HOME/capward}
B=${WORKSPACE_DIR:-$R/workspace}
A=$B/calloc/artifact
OUT=${OUT:-$A/results}; mkdir -p $OUT
BL=${BASELINE_LIBC:-$HOME/libc.baseline}
MD=${MODIFIED_LIBC:-$HOME/libc.modified.perarena}
OPENSSL_SRC=${OPENSSL_SRC:-$HOME/lib_srcs/openssl}
OPENSSL_BUILD=${OPENSSL_BUILD:-$OPENSSL_SRC/build_purecap}
OSSL=${OSSL:-$OPENSSL_BUILD/install/lib}
AB=${AB:-/usr/local64/bin/ab}
# Server ports.
NGINX_HTTP_PORT=${NGINX_HTTP_PORT:-8088};       NGINX_HTTPS_PORT=${NGINX_HTTPS_PORT:-8443}
LIGHTTPD_HTTP_PORT=${LIGHTTPD_HTTP_PORT:-8089}; LIGHTTPD_HTTPS_PORT=${LIGHTTPD_HTTPS_PORT:-8444}
REDIS_BENCH_PORT=${REDIS_BENCH_PORT:-6399}
export no_proxy=127.0.0.1,localhost,::1
APPS="${*:-nginx lighttpd redis}"

rtld(){ case $1 in baseline|calloc) echo $BL/ld-elf.so.1;; *) echo $MD/ld-elf.so.1;; esac; }
libc(){ case $1 in baseline|calloc) echo $BL;; *) echo $MD;; esac; }
mconf(){ case $1 in compart_off) echo heap_compartment:false;; compart_on) echo heap_compartment:true;; *) echo "";; esac; }
rps(){ echo "$1" | grep "Requests per second" | awk '{print $4}'; }
VARIANTS="baseline calloc compart_off compart_on"

############################### nginx ###############################
run_nginx(){
  NB=$B/calloc/nginx/bench; NBIN=$B/calloc/nginx/bin
  LIBS=$OSSL:$B/libraries/zlib
  CSV=$OUT/nginx.csv; echo "run,variant,test,rps" > $CSV
  start(){ v=$1; b=nginx_baseline; [ "$v" = calloc ] && b=nginx_calloc
    pkill -f nginx_ 2>/dev/null; sleep 2
    mc=$(mconf $v)
    env LD_COMPARTMENT_ENABLE=1 LD_LIBRARY_PATH=$(libc $v):$LIBS LD_PRELOAD= LD_LIBMAP= LD_ELF_HINTS_PATH= \
        ${mc:+MALLOC_CONF=$mc} $(rtld $v) $NBIN/$b -c $NB/nginx_bench_nomaster.conf -p $NB 2>/dev/null
    for i in 1 2 3 4 5; do sleep 1; curl -s -o /dev/null http://localhost:${NGINX_HTTP_PORT}/bench.txt && break; done; }
  r=1; while [ $r -le $REPS ]; do for v in $VARIANTS; do
    start $v; O=$(timeout 90 $AB -n $NREQ -c 1 -k http://localhost:${NGINX_HTTP_PORT}/bench.txt 2>&1); echo "$r,$v,http,$(rps "$O")" >> $CSV; pkill -f nginx_ 2>/dev/null
    start $v; O=$(timeout 90 $AB -n $NREQ -c 1 -k http://localhost:${NGINX_HTTP_PORT}/bench.html 2>&1); echo "$r,$v,http+pcre,$(rps "$O")" >> $CSV; pkill -f nginx_ 2>/dev/null
    start $v; O=$(timeout 90 $AB -n $NREQ -c 1 -k -H "Accept-Encoding: gzip" http://localhost:${NGINX_HTTP_PORT}/bench.html 2>&1); echo "$r,$v,http+pcre+gzip,$(rps "$O")" >> $CSV; pkill -f nginx_ 2>/dev/null
    start $v; O=$(timeout 90 $AB -n $NREQ -c 1 -k -f TLS1.2 https://localhost:${NGINX_HTTPS_PORT}/bench.html 2>&1); echo "$r,$v,https,$(rps "$O")" >> $CSV; pkill -f nginx_ 2>/dev/null
    start $v; O=$(timeout 90 $AB -n $NREQ -c 1 -k -f TLS1.2 -H "Accept-Encoding: gzip" https://localhost:${NGINX_HTTPS_PORT}/bench.html 2>&1); echo "$r,$v,https+gzip,$(rps "$O")" >> $CSV; pkill -f nginx_ 2>/dev/null
  done; r=$((r+1)); done
  echo "nginx done $(date)"; }

############################# lighttpd ##############################
run_lighttpd(){
  LBIN=$B/calloc/lighttpd/bin; LCONF=$B/lighttpd/bench/lighttpd_bench_bk.conf
  LIBS=$OSSL:$B/libraries/openssl:$B/libraries/zlib
  CSV=$OUT/lighttpd.csv; echo "run,variant,test,rps" > $CSV
  start(){ v=$1; b=lighttpd_baseline; [ "$v" = calloc ] && b=lighttpd_calloc
    pkill -f lighttpd_ 2>/dev/null; sleep 2
    mc=$(mconf $v)
    env LD_COMPARTMENT_ENABLE=1 LD_LIBRARY_PATH=$(libc $v):$LIBS LD_PRELOAD= LD_LIBMAP= LD_ELF_HINTS_PATH= \
        ${mc:+MALLOC_CONF=$mc} $(rtld $v) $LBIN/$b -f $LCONF -D 2>/dev/null &
    for i in 1 2 3 4 5; do sleep 1; curl -s -o /dev/null http://localhost:${LIGHTTPD_HTTP_PORT}/bench.txt && break; done; }
  r=1; while [ $r -le $REPS ]; do for v in $VARIANTS; do
    start $v; O=$(timeout 90 $AB -n $NREQ -c 1 -k http://localhost:${LIGHTTPD_HTTP_PORT}/bench.txt 2>&1); echo "$r,$v,http,$(rps "$O")" >> $CSV; pkill -f lighttpd_ 2>/dev/null
    start $v; O=$(timeout 90 $AB -n $NREQ -c 1 -k http://localhost:${LIGHTTPD_HTTP_PORT}/bench.html 2>&1); echo "$r,$v,http+static,$(rps "$O")" >> $CSV; pkill -f lighttpd_ 2>/dev/null
    start $v; O=$(timeout 90 $AB -n $NREQ -c 1 -k -f TLS1.2 https://localhost:${LIGHTTPD_HTTPS_PORT}/bench.html 2>&1); echo "$r,$v,https,$(rps "$O")" >> $CSV; pkill -f lighttpd_ 2>/dev/null
  done; r=$((r+1)); done
  echo "lighttpd done $(date)"; }

############################### redis ###############################
run_redis(){
  RB=$B/calloc/redis/bin
  T="SET,GET,INCR,LPUSH,RPUSH,LPOP,RPOP,SADD,SPOP,HSET,MSET"
  CSV=$OUT/redis.csv; echo "run,variant,test,ops_per_sec" > $CSV
  r=1; while [ $r -le $REPS ]; do for v in $VARIANTS; do
    b=redis-server_baseline; [ "$v" = calloc ] && b=redis-server_calloc
    $RB/redis-cli -p $REDIS_BENCH_PORT shutdown nosave 2>/dev/null; sleep 1
    mc=$(mconf $v)
    env LD_COMPARTMENT_ENABLE=1 LD_LIBRARY_PATH=$(libc $v) LD_PRELOAD= LD_LIBMAP= LD_ELF_HINTS_PATH= \
        ${mc:+MALLOC_CONF=$mc} $(rtld $v) $RB/$b --port $REDIS_BENCH_PORT --daemonize yes --save "" \
        --appendonly no --loglevel warning 2>/dev/null
    sleep 2
    $RB/redis-benchmark -p $REDIS_BENCH_PORT -n $NOPS -c 1 -q -t "$T" 2>&1 | grep "requests per second" | while IFS= read -r l; do
      t=$(echo "$l"|sed 's/:.*//'|tr -d '\r' | tr '[:upper:]' '[:lower:]'|tr ' ' '_')
      o=$(echo "$l"|sed 's/.*: //'|sed 's/ requests per second.*//')
      echo "$r,$v,$t,$o" >> $CSV
    done
    $RB/redis-cli -p $REDIS_BENCH_PORT shutdown nosave 2>/dev/null; sleep 1
  done; r=$((r+1)); done
  echo "redis done $(date)"; }

for a in $APPS; do
  echo "=== $a : REPS=$REPS  $(date) ==="
  case $a in nginx) run_nginx;; lighttpd) run_lighttpd;; redis) run_redis;; esac
done
echo "ALL DONE $(date)"
