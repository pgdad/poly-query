package pqledger.commands;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.ArrayList;
import java.util.List;
import polyquery.api.Column;
import polyquery.api.ColumnType;
import polyquery.api.Result;
import pqledger.AppException;
import pqledger.ExitCode;
import pqledger.cli.Filters;
import pqledger.ledger.Ledger;
import pqledger.ledger.LedgerQueries;
import pqledger.output.Tabular;

/**
 * The reports and listings (spec §8.1, §8.2, §8.4, §9.1–§9.3): each is one SQL query on the
 * ledger, printed as is — except {@code report categories}, whose {@code share} column is
 * computed here from the query's {@code spent} values.
 */
final class ReportCommands {
    private ReportCommands() {
    }

    static ExitCode monthly(Session s) throws AppException {
        return simple(s, LedgerQueries.monthly(s.invocation().filters()));
    }

    static ExitCode merchants(Session s) throws AppException {
        return simple(s, LedgerQueries.merchants(s.invocation().filters(), s.invocation().top()));
    }

    static ExitCode accounts(Session s) throws AppException {
        return simple(s, LedgerQueries.accounts());
    }

    static ExitCode export(Session s) throws AppException {
        return simple(s, LedgerQueries.export(s.rules(), s.invocation().filters()));
    }

    static ExitCode list(Session s) throws AppException {
        String category = s.invocation().uncategorized() ? pqledger.Names.UNCATEGORIZED : s.invocation().category();
        return simple(s, LedgerQueries.list(s.rules(), s.invocation().filters(), category));
    }

    private static ExitCode simple(Session s, String sql) throws AppException {
        s.rules(); // read by every ledger command: an invalid rules file is reported for every one
        try (Ledger ledger = s.openLedger()) {
            s.print(Tabular.of(ledger.query(sql)));
        }
        return ExitCode.SUCCESS;
    }

    static ExitCode categories(Session s) throws AppException {
        Filters filters = s.invocation().filters();
        String sql = LedgerQueries.categories(s.rules(), filters);
        Result r;
        try (Ledger ledger = s.openLedger()) {
            r = ledger.query(sql);
        }
        BigDecimal total = BigDecimal.ZERO;
        for (int i = 0; i < r.rowCount(); i++) {
            total = total.add(r.getDecimal(i, 1));
        }
        List<List<Object>> rows = new ArrayList<>(r.rowCount());
        for (int i = 0; i < r.rowCount(); i++) {
            BigDecimal spent = r.getDecimal(i, 1);
            rows.add(List.of(r.getString(i, 0), spent, share(spent, total), r.getLong(i, 2)));
        }
        List<Column> columns = List.of(r.columns().get(0), r.columns().get(1),
                new Column("share", ColumnType.decimal(18, 1)), r.columns().get(2));
        s.print(new Tabular(columns, rows));
        return ExitCode.SUCCESS;
    }

    /** {@code 100 × spent ÷ total}, exactly, rounded half away from zero to one fractional digit. */
    static BigDecimal share(BigDecimal spent, BigDecimal total) {
        return spent.multiply(BigDecimal.valueOf(100)).divide(total, 1, RoundingMode.HALF_UP);
    }
}
