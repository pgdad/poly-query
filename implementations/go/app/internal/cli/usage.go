package cli

const usage = `pqledger — personal finance ledger on an embedded PolyQuery engine

usage: pqledger [--config PATH] [--format table|csv|json] COMMAND [ARGS]

commands:
  init                                  create an empty ledger in data_dir
  import FILE --account NAME            import a bank CSV export
  report monthly [FILTERS]              income, expenses and net per month
  report categories [FILTERS]           spending per category with shares
  report merchants [FILTERS] [--top N]  top merchants by spending (default 10)
  budget --month YYYY-MM [--account NAME]
                                        spending against the monthly budgets
  accounts                              transactions, balance and dates per account
  list [FILTERS] [--category C | --uncategorized]
                                        transactions ordered by date
  export [FILTERS]                      all transaction columns, by id
  set-category ID CATEGORY              override the category of a transaction
  set-category ID --clear               remove the override
  query SQL                             run SQL on the tables transactions,
                                        batches, overrides, ledger, rules, budgets
  help                                  show this help
  version                               show the version

filters:
  --month YYYY-MM | --from YYYY-MM | --to YYYY-MM   month or inclusive month range
  --account NAME                                     one account

The configuration is read from --config PATH, else $PQLEDGER_CONFIG, else
./pqledger.conf. See APP.md for the configuration reference.

exit status: 0 ok, 1 usage, 2 configuration, 3 over budget, 4 import data,
5 query error, 6 ledger state, 7 other error
`
