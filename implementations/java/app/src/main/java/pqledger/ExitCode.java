package pqledger;

/** The exit statuses of pqledger (spec/apps/pqledger.md §10). */
public enum ExitCode {
    SUCCESS(0),
    USAGE(1),
    CONFIG(2),
    OVER_BUDGET(3),
    IMPORT_DATA(4),
    QUERY(5),
    LEDGER_STATE(6),
    OTHER(7);

    private final int status;

    ExitCode(int status) {
        this.status = status;
    }

    public int status() {
        return status;
    }
}
