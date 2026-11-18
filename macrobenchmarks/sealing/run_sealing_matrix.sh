#!/bin/sh
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

# run_sealing_matrix.sh — Baseline vs Seal-instrumented, nginx/lighttpd/redis.
#
# Methodology:
#   * REPS=10 repetitions, ab -n 50000 requests per measurement by default.
#   * A FRESH server is started for every single measurement (no warm-up or
#     test-ordering effects).
#   * SELF-VALIDATING: records ab's "Failed requests" and "Non-2xx responses",
#     and PINGs redis after each run. A server that dies mid-measurement still
#     yields an rps number from ab, so these columns are what reveal it.
#   * nginx runs master_process off (single process), matching the calloc runs.
# CSV: run,variant,test,rps,failed,non2xx     (redis: ...,ops_per_sec,alive,-)
# Defaults match pipeline/set_env.sh — change them THERE, not here.
R=${REPO_DIR:-$HOME/capward}
B=${WORKSPACE_DIR:-$R/workspace}
# Keep sealing output out of the calloc experiment's artifact directory: the two
# are independent measurements and should not share a tree.
OUT=${OUT:-$B/sealing/artifact/results}; mkdir -p $OUT
OPENSSL_SRC=${OPENSSL_SRC:-$HOME/lib_srcs/openssl}
OPENSSL_BUILD=${OPENSSL_BUILD:-$OPENSSL_SRC/build_purecap}
OSSL=${OSSL:-$OPENSSL_BUILD/install/lib}
AB=${AB:-/usr/local64/bin/ab}
NGX=${NGINX_SRC:-$HOME/nginx-cheri-${NGINX_VERSION:-1.24.0}}
REDIS_SRC=${REDIS_SRC:-$HOME/redis-${REDIS_VERSION:-7.0.12}}
REDIS_BENCHMARK=${REDIS_BENCHMARK:-$REDIS_SRC/src/redis-benchmark}
REDIS_CLI=${REDIS_CLI:-$REDIS_SRC/src/redis-cli}
# Server ports.
NGINX_HTTP_PORT=${NGINX_HTTP_PORT:-8088};    NGINX_HTTPS_PORT=${NGINX_HTTPS_PORT:-8443}
LIGHTTPD_HTTP_PORT=${LIGHTTPD_HTTP_PORT:-8089}; LIGHTTPD_HTTPS_PORT=${LIGHTTPD_HTTPS_PORT:-8444}
REDIS_BENCH_PORT=${REDIS_BENCH_PORT:-6399}
REPS=${REPS:-10}; NREQ=${NREQ:-50000}; NOPS=${NOPS:-100000}
export no_proxy=127.0.0.1,localhost,::1
rps(){    echo "$1" | grep "Requests per second" | awk '{print $4}'; }
failed(){ echo "$1" | grep "Failed requests"    | awk '{print $3}'; }
non2xx(){ v=$(echo "$1" | grep "Non-2xx responses" | awk '{print $3}'); echo "${v:-0}"; }

run_nginx(){
  CSV=$OUT/nginx_bench.csv; echo "run,variant,test,rps,failed,non2xx" > $CSV
  BL=$NGX/objs/nginx; IN=$B/nginx/instrumented/nginx
  BLIBS=$OSSL:$B/libraries/pcre2:$B/libraries/zlib
  ILIBS=$B/nginx/instrumented
  start(){ pkill -f nginx 2>/dev/null; sleep 2
    if [ "$1" = baseline ]; then LD_LIBRARY_PATH=$BLIBS $BL -p $NGX -c conf/nginx_ssl_test.conf 2>/dev/null
    else LD_LIBRARY_PATH=$ILIBS $IN -p $NGX -c conf/nginx_ssl_test.conf 2>/dev/null; fi
    for i in 1 2 3 4 5; do sleep 1; curl -s -o /dev/null http://localhost:${NGINX_HTTP_PORT}/bench.txt && break; done; }
  probe(){ r=$1; v=$2; n=$3; shift 3
    O=$(timeout 180 $AB -n $n -c 1 -k "$@" 2>&1)
    echo "$r,$v,$LBL,$(rps "$O"),$(failed "$O"),$(non2xx "$O")" >> $CSV; }
  r=1; while [ $r -le $REPS ]; do for v in baseline instrumented; do
    LBL=http;            start $v; probe $r $v $NREQ http://localhost:${NGINX_HTTP_PORT}/bench.txt
    LBL=http+pcre;       start $v; probe $r $v $NREQ http://localhost:${NGINX_HTTP_PORT}/bench.html
    LBL=http+pcre+gzip;  start $v; probe $r $v $NREQ -H "Accept-Encoding: gzip" http://localhost:${NGINX_HTTP_PORT}/bench.html
    LBL=https;           start $v; probe $r $v $NREQ -f TLS1.2 https://localhost:${NGINX_HTTPS_PORT}/bench.html
    LBL=https+gzip;      start $v; probe $r $v $NREQ -f TLS1.2 -H "Accept-Encoding: gzip" https://localhost:${NGINX_HTTPS_PORT}/bench.html
    pkill -f nginx 2>/dev/null
  done; r=$((r+1)); done; echo "nginx done $(date)"; }

run_lighttpd(){
  CSV=$OUT/lighttpd_bench.csv; echo "run,variant,test,rps,failed,non2xx" > $CSV
  BL=$B/lighttpd/baseline/lighttpd; IN=$B/lighttpd/instrumented/lighttpd
  CONF=$B/lighttpd/bench/lighttpd_bench.conf
  start(){ pkill -f lighttpd 2>/dev/null; sleep 2
    if [ "$1" = baseline ]; then LD_LIBRARY_PATH=$B/lighttpd/baseline:$OSSL $BL -f $CONF -D 2>/dev/null &
    else LD_LIBRARY_PATH=$B/lighttpd/instrumented:$OSSL $IN -f $CONF -D 2>/dev/null & fi
    for i in 1 2 3 4 5; do sleep 1; curl -s -o /dev/null http://localhost:${LIGHTTPD_HTTP_PORT}/bench.txt && break; done; }
  probe(){ r=$1; v=$2; n=$3; shift 3
    O=$(timeout 180 $AB -n $n -c 1 -k "$@" 2>&1)
    echo "$r,$v,$LBL,$(rps "$O"),$(failed "$O"),$(non2xx "$O")" >> $CSV; }
  r=1; while [ $r -le $REPS ]; do for v in baseline instrumented; do
    LBL=http;         start $v; probe $r $v $NREQ http://localhost:${LIGHTTPD_HTTP_PORT}/bench.txt
    LBL=http+static;  start $v; probe $r $v $NREQ http://localhost:${LIGHTTPD_HTTP_PORT}/bench.html
    LBL=https;        start $v; probe $r $v $NREQ -f TLS1.2 https://localhost:${LIGHTTPD_HTTPS_PORT}/bench.html
    pkill -f lighttpd 2>/dev/null
  done; r=$((r+1)); done; echo "lighttpd done $(date)"; }

run_redis(){
  CSV=$OUT/redis_bench.csv; echo "run,variant,test,ops_per_sec,alive,non2xx" > $CSV
  # Both clients come from the same stock 7.0.12 tree. redis-cli is admin-only
  # here (shutdown before/after, and the post-run PING behind the `alive`
  # column); it is never on the clock.
  RS=$REDIS_BENCHMARK; CLI=$REDIS_CLI
  T="SET,GET,INCR,LPUSH,RPUSH,LPOP,RPOP,SADD,SPOP,HSET,MSET"
  r=1; while [ $r -le $REPS ]; do for v in baseline instrumented; do
    $CLI -p $REDIS_BENCH_PORT shutdown nosave 2>/dev/null; sleep 2
    if [ "$v" = baseline ]; then LD=$B/redis/baseline; BIN=$LD/redis-server
    else LD=$B/redis/instrumented; BIN=$LD/redis-server; fi
    LD_LIBRARY_PATH=$LD $BIN --port $REDIS_BENCH_PORT --daemonize yes --save "" --appendonly no --loglevel warning 2>/dev/null
    sleep 2
    O=$(LD_LIBRARY_PATH=$LD:$OSSL $RS -p $REDIS_BENCH_PORT -n $NOPS -c 1 -q -t "$T" 2>&1)
    ALIVE=$($CLI -p $REDIS_BENCH_PORT ping 2>/dev/null | tr -d '\r')
    echo "$O" | tr '\r' '\n' | grep "requests per second" | while IFS= read -r l; do
      t=$(echo "$l"|sed 's/:.*//'|tr -d '\r'|tr '[:upper:]' '[:lower:]'|tr ' ' '_'|sed 's/^_//')
      o=$(echo "$l"|sed 's/.*: //'|sed 's/ requests per second.*//')
      echo "$r,$v,$t,$o,${ALIVE:-DEAD},0" >> $CSV
    done
    $CLI -p $REDIS_BENCH_PORT shutdown nosave 2>/dev/null; sleep 1
  done; r=$((r+1)); done; echo "redis done $(date)"; }

for a in ${*:-nginx lighttpd redis}; do
  echo "=== $a REPS=$REPS NREQ=$NREQ $(date) ==="
  case $a in nginx) run_nginx;; lighttpd) run_lighttpd;; redis) run_redis;; esac
done
echo "ALL DONE $(date)"
