#!/bin/sh
# Records the JVM AOT cache of pqledger (invoked by `make build`):
#   script/pqledger-training.sh WORK_DIR AOT_CACHE_OUTPUT
# Builds a small training ledger from a synthetic statement, then runs an
# overlapping import and an ad-hoc query over the categorized ledger with
# -XX:AOTCacheOutput. Every application and engine namespace is loaded at
# start-up, so these runs cover the classes of all commands.
set -e
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WORK="$1"
OUT="$2"
rm -rf "$WORK"
mkdir -p "$WORK"
cd "$WORK"
cat > pqledger.conf <<'CONF'
[ledger]
data_dir = ledger
rules_file = rules.conf
budget_file = budgets.conf
CONF
cat > rules.conf <<'CONF'
groceries = WHOLE FOODS*, TRADER JOE*
coffee = STARBUCKS*, SQ *BLUE BOTTLE*
housing = RENT*
income = PAYROLL*
CONF
echo "groceries = 600" > budgets.conf
awk 'BEGIN {
  print "Date,Description,Amount"
  split("Whole Foods Market #12,Trader Joe'"'"'s #3,Starbucks Store 4606,SQ *Blue Bottle 99,Rent 2026,PAYROLL ACME,Corner Shop", m, ",")
  for (i = 0; i < 600; i++) {
    printf "2026-%02d-%02d,%s,%s%d.%02d\n", 1 + (i % 12), 1 + (i % 28), m[1 + (i % 7)], (i % 7 == 5) ? "" : "-", 1 + (i * 37) % 900, i % 100
  }
}' > a.csv
head -n 301 a.csv > b.csv
"$ROOT/bin/pqledger" init > /dev/null
"$ROOT/bin/pqledger" import b.csv --account checking > /dev/null
PQLEDGER_JAVA_OPTS="-XX:AOTCacheOutput=$OUT" "$ROOT/bin/pqledger" query \
  "SELECT category, COUNT(*) AS n, SUM(amount) AS total FROM ledger GROUP BY category ORDER BY category" > /dev/null
