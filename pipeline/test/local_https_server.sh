#!/bin/sh
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

# local_https_server.sh — sourced by smoke_wget.sh and smoke_curl.sh.
#
# Stands up a local test server for the two CLIENT smoke tests: the baseline
# lighttpd on 127.0.0.1, with HTTPS (mod_openssl) and gzip (mod_deflate),
# configured as in smoke_lighttpd.sh. Serving locally keeps the test
# consistent from run to run and independent of the network, so the outcome
# reflects the client under test rather than the reachability or
# configuration of a remote server.
#
# The server is the BASELINE lighttpd, so the only instrumented binary in
# these tests is still the client under test.

LOCAL_PORT="${LOCAL_SERVER_PORT:-7751}"     # HTTP
LOCAL_SSL_PORT=$((LOCAL_PORT + 1))          # HTTPS
LOCAL_SERVER_PID=""
LOCAL_RUNDIR=""

start_local_server() {
    _srv="$WORKSPACE_DIR/lighttpd/baseline/lighttpd"
    _openssl="${OPENSSL_BIN:-/usr/bin/openssl}"
    [ -x "$_srv" ] || { echo "ERROR: local test server missing: $_srv" >&2; return 1; }

    LOCAL_RUNDIR=$(mktemp -d /tmp/client_smoke_server.XXXXXX)
    mkdir -p "$LOCAL_RUNDIR/www"
    printf '<html><body>smoke-ok</body></html>\n' > "$LOCAL_RUNDIR/www/index.html"
    "$_openssl" req -x509 -newkey rsa:2048 -nodes -keyout "$LOCAL_RUNDIR/key.pem" \
        -out "$LOCAL_RUNDIR/cert.pem" -days 1 -subj '/CN=localhost' >/dev/null 2>&1 || return 1

    cat > "$LOCAL_RUNDIR/lighttpd.conf" <<CONF
server.document-root = "$LOCAL_RUNDIR/www"
server.bind          = "127.0.0.1"
server.port          = $LOCAL_PORT
server.modules       = ( "mod_openssl", "mod_deflate" )
server.errorlog      = "$LOCAL_RUNDIR/error.log"
mimetype.assign      = ( ".html" => "text/html" )
index-file.names     = ( "index.html" )
\$SERVER["socket"] == "127.0.0.1:$LOCAL_SSL_PORT" {
    ssl.engine  = "enable"
    ssl.pemfile = "$LOCAL_RUNDIR/cert.pem"
    ssl.privkey = "$LOCAL_RUNDIR/key.pem"
}
deflate.mimetypes         = ( "text/html" )
deflate.allowed-encodings = ( "gzip" )
deflate.min-compress-size = 1
CONF

    LD_LIBRARY_PATH="$WORKSPACE_DIR/lighttpd/baseline" "$_srv" -D -f "$LOCAL_RUNDIR/lighttpd.conf" &
    LOCAL_SERVER_PID=$!
    _i=0
    while [ "$_i" -lt 50 ]; do
        /usr/bin/fetch -qo /dev/null "http://127.0.0.1:$LOCAL_PORT/" 2>/dev/null && return 0
        kill -0 "$LOCAL_SERVER_PID" 2>/dev/null || break
        sleep 0.2; _i=$((_i + 1))
    done
    echo "ERROR: local test server did not start" >&2
    return 1
}

stop_local_server() {
    [ -n "$LOCAL_SERVER_PID" ] && kill "$LOCAL_SERVER_PID" 2>/dev/null
    [ -n "$LOCAL_SERVER_PID" ] && wait "$LOCAL_SERVER_PID" 2>/dev/null
    [ -n "$LOCAL_RUNDIR" ] && rm -rf "$LOCAL_RUNDIR"
    LOCAL_SERVER_PID=""; LOCAL_RUNDIR=""
}
