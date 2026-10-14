package pqledger.commands;

import java.util.ArrayList;
import java.util.List;
import polyquery.api.Column;
import polyquery.api.ColumnType;
import polyquery.api.DatabaseException;
import polyquery.api.Result;
import pqledger.AppException;
import pqledger.ExitCode;
import pqledger.config.Budget;
import pqledger.config.Rule;
import pqledger.ledger.Ledger;
import pqledger.ledger.LedgerQueries;
import pqledger.output.Tabular;

/**
 * {@code pqledger query SQL} (spec §9.5): runs SQL with the tables {@code transactions},
 * {@code batches}, {@code overrides}, {@code ledger}, {@code rules} and {@code budgets}.
 * Nothing is written back.
 */
final class QueryCommand {
    static final List<Column> RULE_COLUMNS = List.of(new Column("rule_no", ColumnType.INT64),
            new Column("category", ColumnType.STRING), new Column("pattern", ColumnType.STRING));

    private QueryCommand() {
    }

    static ExitCode run(Session s) throws AppException {
        List<Rule> rules = s.rules();
        List<Budget> budgets = s.budgets(false);
        Result r;
        try (Ledger ledger = s.openLedger()) {
            ledger.replaceTable("ledger", LedgerQueries.ledgerTable(rules));
            List<List<Object>> ruleRows = new ArrayList<>(rules.size());
            for (Rule rule : rules) {
                ruleRows.add(List.of((long) rule.number(), rule.category(), rule.pattern()));
            }
            ledger.database().createTable("rules", RULE_COLUMNS, ruleRows, false);
            BudgetCommand.loadBudgets(ledger, budgets);
            try {
                r = ledger.query(s.invocation().sql());
            } catch (DatabaseException e) {
                throw new AppException(ExitCode.QUERY, e.code() + ": " + e.getMessage());
            }
        }
        s.print(Tabular.of(r));
        return ExitCode.SUCCESS;
    }
}
