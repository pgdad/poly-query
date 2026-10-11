#!/bin/sh
# CLI / protocol smoke tests that drive the engine binary (make test).
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
pq="$here/../../bin/polyquery"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
pass=0

check() {   # check NAME EXPECTED-SUBSTRING ACTUAL
    case "$3" in
        *"$2"*) pass=$((pass+1)) ;;
        *) echo "FAIL: $1"; echo "  expected substring: $2"; echo "  got: $3"; fail=$((fail+1)) ;;
    esac
}

check version '"protocol_version":1' "$("$pq" version)"
check capabilities '"sql.basic"' "$("$pq" capabilities)"

"$pq" session --bogus </dev/null 2>/dev/null
check "unknown option exit code" "2" "$?"
"$pq" 2>/dev/null
check "missing mode exit code" "2" "$?"

printf 'id,name\n1,a\n2,b\n' > "$tmp/t.csv"
out=$(printf '%s\n' \
  '{"op":"load","id":1,"table":"t","format":"csv","path":"t.csv"}' \
  '' \
  'not json' \
  '{"op":"query","id":"q","sql":"SELECT name FROM t WHERE id = 2"}' \
  '{"op":"tables"}' \
  | "$pq" session --data-dir "$tmp")
check "session load" '{"id":1,"ok":true,"table":"t","row_count":2' "$out"
check "session invalid json" '"id":null,"ok":false,"error":{"code":"INVALID_REQUEST"' "$out"
check "session query" '"rows":[["b"]]' "$out"
check "session tables" '"tables":[{"name":"t","row_count":2}]' "$out"
lines=$(printf '%s\n' "$out" | wc -l)
check "one response per request" "4" "$lines"

printf '[{"op":"load","table":"t","format":"csv","path":"t.csv"},{"op":"query","sql":"SELECT COUNT(*) AS n FROM t"}]' > "$tmp/req.json"
out=$("$pq" exec --data-dir "$tmp" --request "$tmp/req.json")
check "exec array" '"rows":[[2]]' "$out"
out=$(echo '{"op":"version"}' | "$pq" exec --request -)
check "exec stdin" '"spec_version":"1.0.0"' "$out"

out=$(echo '{"op":"load","table":"x","format":"csv","path":"../etc/passwd"}' | "$pq" session --data-dir "$tmp")
check "path safety" 'ACCESS_DENIED' "$out"

out=$(echo '{"op":"sleep","ms":1}' | "$pq" session)
check "sleep disabled" 'INVALID_REQUEST' "$out"
out=$(echo '{"op":"sleep","ms":1}' | "$pq" session --enable-test-functions)
check "sleep enabled" '"ok":true' "$out"

echo "cli tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
