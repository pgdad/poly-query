package pqledger.commands;

import java.time.YearMonth;
import java.util.ArrayList;
import java.util.List;
import polyquery.api.Column;
import polyquery.api.ColumnType;
import polyquery.api.Result;
import pqledger.AppException;
import pqledger.ExitCode;
import pqledger.config.Budget;
import pqledger.ledger.Ledger;
import pqledger.ledger.LedgerQueries;
import pqledger.output.Tabular;

/** {@code pqledger budget --month M [--account NAME]} (spec §9.4). */
final class BudgetCommand {
    static final String TABLE = "budgets";
    static final List<Column> COLUMNS = List.of(new Column("category", ColumnType.STRING),
            new Column("amount", ColumnType.decimal(18, 2)));

    private BudgetCommand() {
    }

    static ExitCode run(Session s) throws AppException {
        List<Budget> budgets = s.budgets(true);
        YearMonth month = s.invocation().filters().months().from();
        String sql = LedgerQueries.budget(s.rules(), month, s.invocation().filters().account());
        Result r;
        try (Ledger ledger = s.openLedger()) {
            loadBudgets(ledger, budgets);
            r = ledger.query(sql);
        }
        s.print(Tabular.of(r));
        int status = r.columnIndex("status");
        for (int i = 0; i < r.rowCount(); i++) {
            if ("over".equals(r.getString(i, status))) {
                return ExitCode.OVER_BUDGET;
            }
        }
        return ExitCode.SUCCESS;
    }

    /** Creates the {@code budgets} table (category, amount). */
    static void loadBudgets(Ledger ledger, List<Budget> budgets) {
        List<List<Object>> rows = new ArrayList<>(budgets.size());
        for (Budget b : budgets) {
            rows.add(List.of(b.category(), b.amount()));
        }
        ledger.database().createTable(TABLE, COLUMNS, rows, false);
    }
}
