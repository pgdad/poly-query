package pqledger;

/** The text of {@code pqledger help}. */
final class Usage {
    static final String TEXT = """
            usage: pqledger [--config PATH] [--format table|csv|json] COMMAND [ARGUMENTS]

            Personal-finance ledger: imports bank-statement CSV exports, assigns categories with
            rules and prints reports and budget checks. See APP.md for the full guide.

            commands:
              init                                  create an empty ledger in data_dir
              import FILE --account NAME            import a bank CSV export (duplicates are skipped)
              report monthly [FILTERS]              income, expenses and net per month
              report categories [FILTERS]           spending per category with its share
              report merchants [FILTERS] [--top N]  the N merchants with the highest spending (10)
              budget --month YYYY-MM [--account NAME]
                                                    budget, spending and status per category
                                                    (exit 3 if a category is over budget)
              accounts                              transactions, balance and date range per account
              list [FILTERS] [--category C | --uncategorized]
                                                    transactions by date
              export [FILTERS]                      all columns of the transactions by id
              set-category ID CATEGORY              override the category of a transaction
              set-category ID --clear               remove the override
              query SQL                             run SQL on the tables transactions, batches,
                                                    overrides, ledger, rules and budgets
              help                                  this text
              version                               the version

            filters: --month YYYY-MM | --from YYYY-MM | --to YYYY-MM, --account NAME

            The configuration file is --config PATH, else $PQLEDGER_CONFIG, else ./pqledger.conf.
            exit status: 0 ok, 1 usage, 2 configuration, 3 over budget, 4 import data,
                         5 query error, 6 ledger state, 7 other error
            """;

    private Usage() {
    }
}
