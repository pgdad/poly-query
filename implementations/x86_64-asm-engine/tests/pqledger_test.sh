#!/bin/sh
# End-to-end checks of bin/pqledger (spec/apps/pqledger.md) in a temporary
# directory: init, import, reports, set-category, query and error exits.
# The full black-box suite is tests/apps/pqledger/runner.py.
set -u
DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$DIR/bin/pqledger"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 1
FAILS=0

# expect EXIT EXPECTED_STDOUT ARGS... : runs pqledger, compares status and stdout
expect() {
  want_rc=$1; want_out=$2; shift 2
  out=$("$APP" "$@" 2>"$TMP/err"); rc=$?
  if [ "$rc" != "$want_rc" ]; then
    echo "FAIL pqledger $*: exit $rc, expected $want_rc ($(head -1 "$TMP/err"))"; FAILS=$((FAILS + 1)); return
  fi
  if [ "$want_rc" != 0 ] && [ "$want_rc" != 3 ]; then
    if [ -n "$out" ] || ! head -1 "$TMP/err" | grep -q '^pqledger: error: '; then
      echo "FAIL pqledger $*: error output"; FAILS=$((FAILS + 1)); return
    fi
  fi
  if [ "$want_out" != "-" ] && [ "$out" != "$want_out" ]; then
    echo "FAIL pqledger $*: got"; echo "$out"; echo "expected"; echo "$want_out"; FAILS=$((FAILS + 1))
  fi
}

cat > pqledger.conf <<'EOF'
# test configuration
[ledger]
data_dir = books
rules_file = rules.conf
budget_file = budgets.conf
EOF
printf 'groceries = WHOLE FOODS*, SAFEWAY\ntransport = UBER*\n' > rules.conf
printf 'groceries = 100\ntransport = 10.5\n' > budgets.conf
printf 'Date,Description,Amount\n2026-01-03,Whole Foods #12,-60.00\n2026-01-04,Uber trip,-12.00\n2026-02-01,Payroll,1000.00\n2026-02-02,SAFEWAY 4071,-40.00\n' > bank.csv

expect 0 - version
expect 0 - help
expect 6 - accounts
expect 0 "initialized ledger" init
expect 6 - init
expect 0 "batch 1: imported 4, duplicates 0" import bank.csv --account chk
expect 0 "batch 2: imported 0, duplicates 4" import bank.csv --account chk
expect 0 "month,income,expenses,net,transactions
2026-01,0.00,72.00,-72.00,2
2026-02,1000.00,40.00,960.00,2" --format csv report monthly
expect 0 '{"category":"groceries","spent":"100.00","share":"89.3","transactions":2}
{"category":"transport","spent":"12.00","share":"10.7","transactions":1}' --format json report categories
expect 3 "category   budget  spent  remaining  status
---------  ------  -----  ---------  ------
groceries  100.00  60.00      40.00  ok
transport   10.50  12.00      -1.50  over
(2 rows)" budget --month 2026-01
expect 0 "transaction 2: category travel" set-category 2 travel
expect 0 "id,date,account,description,amount,category
2,2026-01-04,chk,Uber trip,-12.00,travel" --format csv list --category travel
expect 0 "n
3" --format csv query "SELECT COUNT(*) AS n FROM ledger WHERE category <> 'travel'"
expect 1 - report weekly
expect 1 - report monthly --month 2026-13
expect 1 - set-category 2 Bad
expect 5 - query "SELEC 1"
expect 6 - set-category 99 travel
expect 2 - --config missing.conf accounts
# the version line needs no configuration
"$APP" version | grep -q '^pqledger ' || { echo "FAIL version line"; FAILS=$((FAILS + 1)); }

if [ "$FAILS" -ne 0 ]; then
  echo "pqledger_test: $FAILS failure(s)"; exit 1
fi
echo "pqledger_test: ok"
