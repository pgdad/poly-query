package pqledger;

/** A failure that ends the invocation with an exit status and a message for stderr. */
public final class AppException extends Exception {
    private static final long serialVersionUID = 1L;

    private final ExitCode exitCode;

    public AppException(ExitCode exitCode, String message) {
        super(message);
        this.exitCode = exitCode;
    }

    public ExitCode exitCode() {
        return exitCode;
    }

    public static AppException usage(String message) {
        return new AppException(ExitCode.USAGE, message);
    }

    public static AppException config(String message) {
        return new AppException(ExitCode.CONFIG, message);
    }

    public static AppException importData(String message) {
        return new AppException(ExitCode.IMPORT_DATA, message);
    }

    public static AppException ledgerState(String message) {
        return new AppException(ExitCode.LEDGER_STATE, message);
    }

    public static AppException other(String message) {
        return new AppException(ExitCode.OTHER, message);
    }
}
