package pqledger.ledger;

import java.time.LocalDate;
import java.time.YearMonth;
import java.util.ArrayList;
import java.util.List;
import pqledger.Names;
import pqledger.cli.Filters;
import pqledger.cli.MonthRange;
import pqledger.config.Rule;

/**
 * The SQL statements pqledger runs on the embedded engine. All filtering, joining,
 * aggregation, sorting and category resolution happens in these statements (spec §1).
 *
 * <p>Tables: {@code transactions}, {@code batches}, {@code overrides} (spec §4) and, where
 * needed, {@code budgets} ({@code category}, {@code amount}).
 */
public final class LedgerQueries {
    private LedgerQueries() {
    }

    /**
     * The resolved category of transaction {@code t} joined with its override {@code o}
     * (spec §5.1): the override, else the category of the first matching rule, else
     * {@code uncategorized}. Rules become a {@code CASE} whose {@code WHEN}s are in rule order.
     */
    static String categoryExpression(List<Rule> rules) {
        if (rules.isEmpty()) {
            return "COALESCE(o.category, " + Sql.string(Names.UNCATEGORIZED) + ")";
        }
        StringBuilder sb = new StringBuilder("COALESCE(o.category, CASE");
        for (Rule r : rules) {
            sb.append(" WHEN t.merchant LIKE ").append(Sql.string(r.likePattern()))
                    .append(" THEN ").append(Sql.string(r.category()));
        }
        return sb.append(" ELSE ").append(Sql.string(Names.UNCATEGORIZED)).append(" END)").toString();
    }

    /**
     * The transactions passing {@code filters} (and {@code extraCondition} on {@code t}, if not
     * null) with their resolved {@code category}: the columns of {@code transactions} followed
     * by {@code category}.
     */
    public static String ledger(List<Rule> rules, Filters filters, String extraCondition) {
        List<String> conditions = conditions(filters);
        if (extraCondition != null) {
            conditions.add(extraCondition);
        }
        return "SELECT t.id AS id, t.account AS account, t.\"date\" AS \"date\", t.description AS description, "
                + "t.merchant AS merchant, t.amount AS amount, t.batch AS batch, "
                + categoryExpression(rules) + " AS category "
                + "FROM transactions t LEFT JOIN overrides o ON o.id = t.id" + where(conditions);
    }

    /** The {@code ledger} table of {@code pqledger query}: every transaction with its category. */
    public static String ledgerTable(List<Rule> rules) {
        return ledger(rules, Filters.NONE, null) + " ORDER BY id";
    }

    /** Conditions on {@code t} for the filter options. */
    static List<String> conditions(Filters filters) {
        List<String> out = new ArrayList<>();
        MonthRange months = filters.months();
        LocalDate first = months.firstDay();
        LocalDate last = months.lastDay();
        if (first != null) {
            out.add("t.\"date\" >= " + Sql.date(first));
        }
        if (last != null) {
            out.add("t.\"date\" <= " + Sql.date(last));
        }
        if (filters.account() != null) {
            out.add("t.account = " + Sql.string(filters.account()));
        }
        return out;
    }

    private static String where(List<String> conditions) {
        return conditions.isEmpty() ? "" : " WHERE " + String.join(" AND ", conditions);
    }

    // ---------------------------------------------------------------- reports (spec §9)

    /** {@code report monthly}: month, income, expenses, net, transactions. */
    public static String monthly(Filters filters) {
        return "SELECT month, "
                + "SUM(CASE WHEN amount > 0 THEN amount ELSE 0.00 END) AS income, "
                + "-SUM(CASE WHEN amount < 0 THEN amount ELSE 0.00 END) AS expenses, "
                + "SUM(amount) AS net, COUNT(*) AS transactions "
                + "FROM (SELECT SUBSTR(CAST(t.\"date\" AS STRING), 1, 7) AS month, t.amount AS amount "
                + "FROM transactions t" + where(conditions(filters)) + ") m "
                + "GROUP BY month ORDER BY month";
    }

    /** {@code report categories} without the share: category, spent, transactions. */
    public static String categories(List<Rule> rules, Filters filters) {
        return "SELECT category, -SUM(amount) AS spent, COUNT(*) AS transactions "
                + "FROM (" + ledger(rules, filters, "t.amount < 0") + ") l "
                + "GROUP BY category ORDER BY spent DESC, category";
    }

    /** {@code report merchants}: merchant, spent, transactions; the first {@code top} rows. */
    public static String merchants(Filters filters, long top) {
        List<String> conditions = conditions(filters);
        conditions.add("t.amount < 0");
        return "SELECT t.merchant AS merchant, -SUM(t.amount) AS spent, COUNT(*) AS transactions "
                + "FROM transactions t" + where(conditions) + " "
                + "GROUP BY t.merchant ORDER BY spent DESC, merchant LIMIT " + top;
    }

    /** {@code budget}: category, budget, spent, remaining, status for every row of {@code budgets}. */
    public static String budget(List<Rule> rules, YearMonth month, String account) {
        Filters filters = new Filters(MonthRange.of(month), account);
        return "WITH outflows AS (SELECT category, -SUM(amount) AS spent "
                + "FROM (" + ledger(rules, filters, "t.amount < 0") + ") l GROUP BY category) "
                + "SELECT b.category AS category, b.amount AS budget, COALESCE(s.spent, 0.00) AS spent, "
                + "b.amount - COALESCE(s.spent, 0.00) AS remaining, "
                + "CASE WHEN COALESCE(s.spent, 0.00) <= b.amount THEN 'ok' ELSE 'over' END AS status "
                + "FROM budgets b LEFT JOIN outflows s ON s.category = b.category "
                + "ORDER BY category";
    }

    /** {@code accounts}: account, transactions, balance, first, last. */
    public static String accounts() {
        return "SELECT t.account AS account, COUNT(*) AS transactions, SUM(t.amount) AS balance, "
                + "MIN(t.\"date\") AS \"first\", MAX(t.\"date\") AS \"last\" "
                + "FROM transactions t GROUP BY t.account ORDER BY account";
    }

    /**
     * {@code list}: id, date, account, description, amount, category ordered by date and id;
     * only category {@code category} if not null.
     */
    public static String list(List<Rule> rules, Filters filters, String category) {
        return "SELECT id, \"date\", account, description, amount, category "
                + "FROM (" + ledger(rules, filters, null) + ") l"
                + (category == null ? "" : " WHERE category = " + Sql.string(category))
                + " ORDER BY \"date\", id";
    }

    /** {@code export}: id, account, date, description, merchant, amount, category, batch by id. */
    public static String export(List<Rule> rules, Filters filters) {
        return "SELECT id, account, \"date\", description, merchant, amount, category, batch "
                + "FROM (" + ledger(rules, filters, null) + ") l ORDER BY id";
    }

    // ---------------------------------------------------------------- import and editing

    /**
     * The number of transactions per (date, amount, merchant) of {@code account} dated between
     * {@code from} and {@code to}: columns d, amount, merchant, n.
     */
    public static String keyCounts(String account, LocalDate from, LocalDate to) {
        return "SELECT t.\"date\" AS d, t.amount AS amount, t.merchant AS merchant, COUNT(*) AS n "
                + "FROM transactions t WHERE t.account = " + Sql.string(account)
                + " AND t.\"date\" >= " + Sql.date(from) + " AND t.\"date\" <= " + Sql.date(to)
                + " GROUP BY t.\"date\", t.amount, t.merchant";
    }

    /** The largest transaction id and batch number (0 for an empty ledger): columns max_id, max_batch. */
    public static String maxima() {
        return "SELECT COALESCE((SELECT MAX(id) FROM transactions), 0) AS max_id, "
                + "COALESCE((SELECT MAX(batch) FROM batches), 0) AS max_batch";
    }

    /** {@code table} followed by the rows of {@code added}, ordered by {@code key}. */
    public static String append(String table, String added, String key) {
        return "SELECT * FROM " + table + " UNION ALL SELECT * FROM " + added + " ORDER BY " + key;
    }

    /** The number of transactions with id {@code id}: column n. */
    public static String countId(long id) {
        return "SELECT COUNT(*) AS n FROM transactions WHERE id = " + id;
    }

    /** The overrides with the override of {@code id} set to {@code category} (null: removed). */
    public static String overridesWith(long id, String category) {
        String others = "SELECT id, category FROM overrides WHERE id <> " + id;
        return category == null ? others + " ORDER BY id"
                : others + " UNION ALL SELECT " + id + " AS id, " + Sql.string(category) + " AS category ORDER BY id";
    }
}
