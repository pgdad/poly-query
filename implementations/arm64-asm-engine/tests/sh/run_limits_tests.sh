#!/bin/sh
# CR-6 (expression size limits) tests that drive the engine binary (make
# test): statements at the minimums (nesting depth 999, 10,000-term chains,
# 10,000-item IN list, 1 MiB of text) in every execution mode, the engine's
# own limits (RESOURCE_LIMIT naming the measure), deep evaluation on parallel
# worker threads, and the timeout during parsing / planning of a huge
# statement.
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
pq="$here/../../bin/polyquery"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
pass=0

check() {   # check NAME EXPECTED-SUBSTRING ACTUAL
    case "$3" in
        *"$2"*) pass=$((pass+1)) ;;
        *) echo "FAIL: $1"; echo "  expected substring: $2"
           echo "  got: $(printf '%s' "$3" | cut -c1-300)"; fail=$((fail+1)) ;;
    esac
}

seq 0 99 | { echo x; cat; } > "$tmp/n.csv"

# rep N TEXT: TEXT repeated N times
rep() { awk -v n="$1" -v s="$2" 'BEGIN { for (i = 0; i < n; i++) printf "%s", s }'; }
# join N FMT SEP: FMT (with %d = 0..N-1) joined by SEP
join() { awk -v n="$1" -v f="$2" -v sep="$3" 'BEGIN { for (i = 0; i < n; i++) { if (i) printf "%s", sep; printf f, i } }'; }

# q SQL-FILE OPTIONS -> response of the query (after loading n)
q() {
    { echo '{"op":"load","table":"n","format":"csv","path":"n.csv"}'
      printf '{"op":"query","sql":"'; cat "$1"; printf '","options":%s}\n' "$2"
    } | PQ_PARALLEL_MIN_ROWS=1 "$pq" session --data-dir "$tmp" | tail -1
}
# every_mode NAME SQL-FILE EXPECTED-SUBSTRING
every_mode() {
    for o in '{"mode":"row","threads":1}' '{"mode":"vectorized","threads":1}' \
             '{"mode":"vectorized","threads":8}' '{}'; do
        check "$1 $o" "$3" "$(q "$2" "$o")"
    done
}

out=$("$pq" capabilities)
check "capability" '"change.expression_limits"' "$out"

# ---- minimums (spec/changes/expression-limits.md §5)
w="SELECT count(*) FROM n WHERE"
{ printf '%s ' "$w"; rep 998 '('; printf 'x >= 0'; rep 998 ')'; } > "$tmp/parens.sql"
every_mode "parens 998" "$tmp/parens.sql" '"rows":[[100]]'
{ printf '%s ' "$w"; rep 998 'ABS('; printf 'x'; rep 998 ')'; printf ' >= 0'; } > "$tmp/abs.sql"
every_mode "ABS 998" "$tmp/abs.sql" '"rows":[[100]]'
{ printf '%s ' "$w"; rep 998 'NOT '; printf 'x >= 0'; } > "$tmp/not.sql"
every_mode "NOT 998" "$tmp/not.sql" '"rows":[[100]]'
{ printf '%s ' "$w"; rep 998 '- '; printf 'x >= 0'; } > "$tmp/neg.sql"
every_mode "unary minus 998" "$tmp/neg.sql" '"rows":[[100]]'
{ printf 'SELECT sum('; rep 998 'CASE WHEN x >= 0 THEN '; printf '1'; rep 998 ' ELSE 0 END'; printf ') FROM n'; } > "$tmp/case.sql"
every_mode "nested CASE 998" "$tmp/case.sql" '"rows":[[100]]'
{ printf 'SELECT '; rep 998 '(SELECT '; printf '1'; rep 998 ')'; } > "$tmp/subq.sql"
every_mode "scalar subqueries 998" "$tmp/subq.sql" '"rows":[[1]]'
{ printf '%s ' "$w"; join 10000 'x = %d' ' OR '; } > "$tmp/or.sql"
every_mode "OR 10000" "$tmp/or.sql" '"rows":[[100]]'
{ printf 'SELECT max(x'; rep 9999 ' + 1'; printf ') FROM n'; } > "$tmp/sum.sql"
every_mode "sum 10000" "$tmp/sum.sql" '"rows":[[10098]]'
{ printf 'SELECT max(length(CAST(x AS VARCHAR)'; rep 9999 " || 'a'"; printf ')) FROM n'; } > "$tmp/concat.sql"
every_mode "concat 10000" "$tmp/concat.sql" '"rows":[[10001]]'
{ printf '%s x IN (' "$w"; join 10000 '%d' ', '; printf ')'; } > "$tmp/in.sql"
every_mode "IN 10000" "$tmp/in.sql" '"rows":[[100]]'
{ printf "%s '" "$w"; rep 524000 a; printf "' = '"; rep 524000 a; printf "'"; } > "$tmp/text.sql"
every_mode "1 MiB text" "$tmp/text.sql" '"rows":[[100]]'

# ---- beyond the minimums: computed, or RESOURCE_LIMIT naming the measure
{ printf '%s ' "$w"; join 100000 'x = %d' ' OR '; } > "$tmp/or100k.sql"
every_mode "OR 100000 (workers too)" "$tmp/or100k.sql" '"rows":[[100]]'
{ printf '%s ' "$w"; rep 5000 '('; printf 'x >= 0'; rep 5000 ')'; } > "$tmp/deep.sql"
every_mode "depth 5000" "$tmp/deep.sql" '"message":"expression nesting depth exceeds 4096"'
{ printf '%s x IN (' "$w"; join 1000000 '%d' ','; printf ')'; } > "$tmp/ops.sql"
check "operands 1000001" '"message":"operand count exceeds 1000000"' "$(q "$tmp/ops.sql" '{}')"

# ---- the timeout covers parsing / binding / planning (huge statement)
{ printf 'SELECT max(x'; rep 900000 ' + 1'; printf ') FROM n'; } > "$tmp/big.sql"
check "timeout while preparing" '"code":"TIMEOUT"' "$(q "$tmp/big.sql" '{"timeout_ms":5}')"

echo "limits tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
