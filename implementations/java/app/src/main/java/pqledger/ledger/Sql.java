package pqledger.ledger;

import java.time.LocalDate;

/** SQL literal helpers. */
public final class Sql {
    private Sql() {
    }

    /** A string literal: {@code 'it''s'}. */
    public static String string(String s) {
        return "'" + s.replace("'", "''") + "'";
    }

    /** A DATE literal: {@code DATE '2026-01-31'}. */
    public static String date(LocalDate d) {
        return "DATE '" + d + "'";
    }
}
