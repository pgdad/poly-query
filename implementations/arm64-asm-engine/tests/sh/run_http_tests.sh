#!/bin/sh
# HTTP server smoke tests (make test): endpoints, status mapping, streaming,
# metrics, cancellation, admission control and graceful shutdown.
# Speaks HTTP/1.1 through bash's /dev/tcp, so no client tools are needed.
if [ -z "$BASH_VERSION" ]; then
    if command -v bash >/dev/null 2>&1; then exec bash "$0" "$@"; fi
    echo "http tests: skipped (bash not available)"; exit 0
fi
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
pq="$here/../../bin/polyquery"
tmp=$(mktemp -d)
pids=""
trap 'for p in $pids; do kill -9 $p 2>/dev/null; done; rm -rf "$tmp"' EXIT
fail=0
pass=0

check() {   # check NAME EXPECTED-SUBSTRING ACTUAL
    case "$3" in
        *"$2"*) pass=$((pass+1)) ;;
        *) echo "FAIL: $1"; echo "  expected substring: $2"; echo "  got: ${3:0:400}"; fail=$((fail+1)) ;;
    esac
}

start() {   # start NAME OPTIONS... -> sets port, pid
    "$pq" serve --port 0 --data-dir "$tmp" "${@:2}" >"$tmp/$1.out" 2>"$tmp/$1.err" &
    pid=$!
    pids="$pids $pid"
    for _ in $(seq 100); do
        port=$(sed -n 's/.*"port":\([0-9]*\).*/\1/p' "$tmp/$1.out")
        [ -n "$port" ] && return 0
        sleep 0.05
    done
    echo "FAIL: server $1 did not start"; exit 1
}

http() {    # http METHOD PATH [BODY] -> raw response
    exec 3<>"/dev/tcp/127.0.0.1/$port" || return 1
    printf '%s %s HTTP/1.1\r\nHost: t\r\nConnection: close\r\nContent-Length: %d\r\n\r\n%s' \
        "$1" "$2" "${#3}" "$3" >&3
    cat <&3
    exec 3<&-
}

start main --enable-test-functions
check "listening line" '{"event":"listening","host":"127.0.0.1","port":' "$(cat "$tmp/main.out")"
check "health" 'HTTP/1.1 200 OK' "$(http GET /health)"
check "health body" '{"status":"ok"}' "$(http GET /health)"
check "version" '"protocol_version":1' "$(http GET /v1/version)"
check "capabilities" '"phase4","http.streaming"' "$(http GET /v1/capabilities)"
out=$(http PUT '/v1/tables/t?format=csv' $'id,name\n1,a\n2,b\n3,c\n')
check "PUT table" 'HTTP/1.1 201 Created' "$out"
check "PUT row count" '"row_count":3' "$out"
check "PUT duplicate" 'HTTP/1.1 409' "$(http PUT '/v1/tables/t?format=csv' $'x\n1\n')"
check "PUT bad csv" '"INGEST_ERROR"' "$(http PUT '/v1/tables/bad?format=csv' $'a,b\n1\n')"
check "tables" '"tables":[{"name":"t","row_count":3}]' "$(http GET /v1/tables)"
check "schema" '"columns":[{"name":"id","type":"INT64"}' "$(http GET /v1/tables/t/schema)"
check "stats" '"distinct_count":3' "$(http GET /v1/tables/t/stats)"
out=$(http POST /v1/query '{"sql":"SELECT name FROM t WHERE id >= 2 ORDER BY id","options":{"query_id":"smoke-1"}}')
check "query" '"rows":[["b"],["c"]]' "$out"
check "query id header" 'X-PolyQuery-Query-Id: smoke-1' "$out"
check "parse error" 'HTTP/1.1 400' "$(http POST /v1/query '{"sql":"SELEC 1"}')"
check "malformed json" '"INVALID_REQUEST"' "$(http POST /v1/query '{bad')"
check "unknown table" 'HTTP/1.1 404' "$(http GET /v1/tables/nope/schema)"
check "unknown path" '"NOT_FOUND"' "$(http GET /v2/x)"
check "wrong method" 'HTTP/1.1 405' "$(http GET /v1/query)"
check "explain" '"plan":{' "$(http POST /v1/explain '{"sql":"SELECT id FROM t"}')"
check "generic request" '"row_count":3' "$(http POST /v1/request '{"op":"schema","table":"t"}')"
check "access denied" 'HTTP/1.1 403' "$(http POST /v1/request '{"op":"load","table":"x","format":"csv","path":"/etc/passwd"}')"
out=$(http POST /v1/query/stream '{"sql":"SELECT id FROM t ORDER BY id"}')
check "stream chunked" 'Transfer-Encoding: chunked' "$out"
check "stream ndjson" 'Content-Type: application/x-ndjson' "$out"
check "stream header" '{"type":"header","query_id":' "$out"
check "stream rows" '{"type":"rows","rows":[[1],[2],[3]]}' "$out"
check "stream end" '{"type":"end","row_count":3}' "$out"
# cancellation of a running query
http POST /v1/query '{"sql":"SELECT PQ_SLEEP(5000)","options":{"query_id":"slow"}}' >"$tmp/slow.out" &
sleep 0.3
check "queries list" '"query_id":"slow","state":"running"' "$(http GET /v1/queries)"
check "duplicate query id" 'HTTP/1.1 409' "$(http POST /v1/query '{"sql":"SELECT 1","options":{"query_id":"slow"}}')"
check "cancel" '"cancelled":true' "$(http DELETE /v1/queries/slow)"
wait $!
check "cancelled response" '"code":"CANCELLED"' "$(cat "$tmp/slow.out")"
check "cancel unknown" 'HTTP/1.1 404' "$(http DELETE /v1/queries/slow)"
check "timeout" 'HTTP/1.1 504' "$(http POST /v1/query '{"sql":"SELECT PQ_SLEEP(3000)","options":{"timeout_ms":100}}')"
out=$(http GET /metrics)
check "metrics ok" 'polyquery_queries_total{status="ok"}' "$out"
check "metrics cancelled" 'polyquery_queries_cancelled_total 1' "$out"
check "metrics tables" 'polyquery_tables 1' "$out"
check "delete table" '"ok":true' "$(http DELETE /v1/tables/t)"
check "log line" '"msg":"query finished","query_id":"smoke-1","status":"ok"' "$(cat "$tmp/main.err")"
kill -TERM $pid
wait $pid
check "graceful exit status" "0" "$?"

# admission control: 1 worker, no queue
start busy --enable-test-functions --workers 1 --queue-depth 0
http POST /v1/query '{"sql":"SELECT PQ_SLEEP(800)"}' >"$tmp/busy1.out" &
sleep 0.3
check "overloaded" 'HTTP/1.1 503' "$(http POST /v1/query '{"sql":"SELECT 1"}')"
check "health while busy" 'HTTP/1.1 200' "$(http GET /health)"
check "rejected counter" 'polyquery_queries_rejected_total 1' "$(http GET /metrics)"
wait $!
check "admitted query" 'HTTP/1.1 200' "$(cat "$tmp/busy1.out")"
# request size limit
kill -TERM $pid; wait $pid
start small --max-request-bytes 10
check "request too large" 'HTTP/1.1 413' "$(http PUT '/v1/tables/x?format=csv' $'a\n1\n2\n3\n4\n5\n6\n')"
kill -TERM $pid; wait $pid

echo "http tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
