#!/bin/sh
# End-to-end tests of `polyquery serve` (protocol.md §7) driven with curl:
# endpoints, status mapping, streaming, cancellation, admission control,
# metrics, structured logs and graceful shutdown.  Skipped without curl.
DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN="$DIR/bin/polyquery"
if ! command -v curl >/dev/null 2>&1; then
  echo "server_test: curl not found, skipped"
  exit 0
fi
TMP=$(mktemp -d)
pass=0
fail=0
SRV=
trap 'kill -9 $SRV 2>/dev/null; rm -rf "$TMP"' EXIT

ok() { pass=$((pass + 1)); }
ko() { fail=$((fail + 1)); echo "FAIL: $1"; }

# start_server ARGS...: starts the server, sets SRV (pid) and U (base URL)
start_server() {
  rm -f "$TMP/out" "$TMP/err"
  "$BIN" serve --port 0 --data-dir "$TMP" "$@" > "$TMP/out" 2> "$TMP/err" &
  SRV=$!
  i=0
  while [ ! -s "$TMP/out" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  port=$(sed -n 's/.*"port":\([0-9]*\).*/\1/p' "$TMP/out")
  U="http://127.0.0.1:$port"
}

stop_server() {
  kill -TERM $SRV 2>/dev/null
  wait $SRV
  rc=$?
  SRV=
  return $rc
}

# expect NAME STATUS PATTERN CURL-ARGS...: response status and body pattern
expect() {
  name=$1; st=$2; pat=$3; shift 3
  got=$(curl -s -o "$TMP/body" -w '%{http_code}' "$@")
  if [ "$got" = "$st" ] && grep -q -- "$pat" "$TMP/body"; then ok; else ko "$name: $got $(head -c 300 "$TMP/body")"; fi
}

printf 'id,name\n1,a\n2,b\n3,c\n' > "$TMP/t.csv"
printf 'x\n7\n' > "$TMP/c.csv"

start_server --enable-test-functions --workers 1 --queue-depth 1
expect health 200 '"status":"ok"' "$U/health"
expect version 200 '"protocol_version":1' "$U/v1/version"
expect capabilities 200 '"phase4"' "$U/v1/capabilities"
expect put 201 '"row_count":3' -X PUT --data-binary @"$TMP/t.csv" "$U/v1/tables/t?format=csv"
expect put_dup 409 '"ALREADY_EXISTS"' -X PUT --data-binary @"$TMP/t.csv" "$U/v1/tables/t?format=csv"
expect put_chunked 201 '"row_count":1' -X PUT -H 'Transfer-Encoding: chunked' --data-binary @"$TMP/c.csv" "$U/v1/tables/c?format=csv"
expect tables 200 '"name":"c"' "$U/v1/tables"
expect schema 200 '"columns":\[{"name":"id","type":"INT64"}' "$U/v1/tables/t/schema"
expect stats 200 '"distinct_count":3' "$U/v1/tables/t/stats"
expect query 200 '"rows":\[\[2,"b"\]\]' -d '{"sql":"SELECT id, name FROM t WHERE id = 2"}' "$U/v1/query"
expect parse_error 400 '"PARSE_ERROR"' -d '{"sql":"SELEC 1"}' "$U/v1/query"
expect bad_json 400 '"INVALID_REQUEST"' -d '{nope' "$U/v1/query"
expect not_found 404 '"NOT_FOUND"' "$U/v1/nope"
expect wrong_method 405 '"INVALID_REQUEST"' "$U/v1/query"
expect access 403 '"ACCESS_DENIED"' -d '{"op":"load","table":"x","format":"csv","path":"../x"}' "$U/v1/request"
expect request 200 '"id":7' -d '{"op":"schema","table":"t","id":7}' "$U/v1/request"
expect explain 200 '"plan":{' -d '{"sql":"SELECT id FROM t"}' "$U/v1/explain"
expect index 200 '"row_count":0' -d '{"sql":"CREATE INDEX ti ON t (id)"}' "$U/v1/query"
expect stream 200 '{"type":"end","row_count":3}' -d '{"sql":"SELECT * FROM t ORDER BY id"}' "$U/v1/query/stream"
expect stream_err 400 '"SEMANTIC_ERROR"' -d '{"sql":"SELECT nope FROM t"}' "$U/v1/query/stream"
expect timeout 504 '"TIMEOUT"' -d '{"sql":"SELECT PQ_SLEEP(3000)","options":{"timeout_ms":100}}' "$U/v1/query"
# one worker, queue depth one: running + queued, the third is rejected
curl -s -o "$TMP/q1" -d '{"sql":"SELECT PQ_SLEEP(3000)","options":{"query_id":"long"}}' "$U/v1/query" &
c1=$!
sleep 0.3
curl -s -o "$TMP/q2" -d '{"sql":"SELECT 1"}' "$U/v1/query" &
c2=$!
sleep 0.2
expect overloaded 503 '"OVERLOADED"' -d '{"sql":"SELECT 1"}' "$U/v1/query"
expect list 200 '"query_id":"long","state":"running"' "$U/v1/queries"
expect dup_id 409 '"ALREADY_EXISTS"' -d '{"sql":"SELECT 1","options":{"query_id":"long"}}' "$U/v1/query"
expect cancel 200 '"cancelled":true' -X DELETE "$U/v1/queries/long"
wait $c1 $c2
if grep -q '"CANCELLED"' "$TMP/q1"; then ok; else ko "cancelled query: $(cat "$TMP/q1")"; fi
if grep -q '"rows":\[\[1\]\]' "$TMP/q2"; then ok; else ko "queued query: $(cat "$TMP/q2")"; fi
expect cancel_unknown 404 '"NOT_FOUND"' -X DELETE "$U/v1/queries/long"
expect metrics 200 'polyquery_queries_rejected_total 1' "$U/metrics"
expect drop 200 '"ok":true' -X DELETE "$U/v1/tables/c"
if stop_server; then ok; else ko "exit status after SIGTERM"; fi
if grep -v '^{"ts":"[0-9T:.-]*Z","level":"[a-z]*","msg":' "$TMP/err" | grep -q .; then ko "non-JSON log line"; else ok; fi
if grep -q '"query_id":"long","status":"cancelled"' "$TMP/err"; then ok; else ko "query completion log"; fi

# graceful shutdown lets the running query finish
start_server --enable-test-functions
curl -s -o "$TMP/g1" -d '{"sql":"SELECT PQ_SLEEP(600) AS s"}' "$U/v1/query" &
c1=$!
sleep 0.2
if stop_server; then ok; else ko "graceful exit status"; fi
wait $c1
if grep -q '"rows":\[\[600\]\]' "$TMP/g1"; then ok; else ko "in-flight query during shutdown: $(cat "$TMP/g1")"; fi

echo "server_test: $pass passed, $fail failed"
[ "$fail" = 0 ]
