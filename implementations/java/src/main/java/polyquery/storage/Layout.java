package polyquery.storage;

import java.util.Locale;

/** In-memory physical representation of a table (indexes-and-planning.md §1). */
public enum Layout {
    /** A sequence of row tuples. */
    ROW,
    /** One typed vector per column plus null bitmap (optionally dictionary-encoded strings). */
    COLUMN;

    public String jsonName() {
        return name().toLowerCase(Locale.ROOT);
    }

    /** Parses {@code "row"} / {@code "column"}; null if unknown. */
    public static Layout fromName(String name) {
        return switch (name) {
            case "row" -> ROW;
            case "column" -> COLUMN;
            default -> null;
        };
    }
}
