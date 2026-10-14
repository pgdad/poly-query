package pqledger.commands;

import pqledger.AppException;
import pqledger.ExitCode;

/** Runs the command of a session. */
public final class Commands {
    private Commands() {
    }

    public static ExitCode run(Session s) throws AppException {
        return switch (s.invocation().command()) {
            case INIT -> InitCommand.run(s);
            case IMPORT -> ImportCommand.run(s);
            case REPORT_MONTHLY -> ReportCommands.monthly(s);
            case REPORT_CATEGORIES -> ReportCommands.categories(s);
            case REPORT_MERCHANTS -> ReportCommands.merchants(s);
            case BUDGET -> BudgetCommand.run(s);
            case ACCOUNTS -> ReportCommands.accounts(s);
            case LIST -> ReportCommands.list(s);
            case EXPORT -> ReportCommands.export(s);
            case SET_CATEGORY -> SetCategoryCommand.run(s);
            case QUERY -> QueryCommand.run(s);
            case HELP, VERSION -> throw new IllegalStateException("handled without a session");
        };
    }
}
