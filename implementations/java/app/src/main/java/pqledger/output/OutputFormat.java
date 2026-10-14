package pqledger.output;

import java.util.Locale;

/** The output formats of results (spec §7). */
public enum OutputFormat {
    TABLE,
    CSV,
    JSON;

    /** The format named {@code name} ({@code table}, {@code csv} or {@code json}), or null. */
    public static OutputFormat fromName(String name) {
        return switch (name) {
            case "table", "csv", "json" -> valueOf(name.toUpperCase(Locale.ROOT));
            default -> null;
        };
    }
}
