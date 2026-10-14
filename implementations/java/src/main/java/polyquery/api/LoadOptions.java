package polyquery.api;

import java.util.List;

/**
 * Options of {@link Database#loadFile} and {@link Database#loadText} (the protocol's
 * {@code load} operation). Immutable; the {@code with…} methods return modified copies:
 *
 * <pre>{@code
 * LoadOptions opts = LoadOptions.csv().withDelimiter(';').withReplace(true);
 * }</pre>
 *
 * @param format    input format
 * @param schema    explicit column names and types, or {@code null} to infer them
 *                  (required for CSV without a header)
 * @param header    CSV: the first record is a header
 * @param delimiter CSV: field delimiter, one ASCII character other than {@code "}, CR and LF
 * @param replace   replace an existing table of the same name (else {@code ALREADY_EXISTS})
 */
public record LoadOptions(Format format, List<Column> schema, boolean header, char delimiter, boolean replace) {
    /** Input formats of {@code load} ({@code spec/data-types/ingestion.md}). */
    public enum Format {
        /** RFC 4180 CSV. */
        CSV,
        /** A JSON array of objects. */
        JSON,
        /** JSON Lines: one object per line. */
        JSONL
    }

    public LoadOptions {
        if (format == null) {
            throw new IllegalArgumentException("format must not be null");
        }
        schema = schema == null ? null : List.copyOf(schema);
    }

    /** CSV with a header row, {@code ,} as delimiter, inferred schema, no replace. */
    public static LoadOptions csv() {
        return new LoadOptions(Format.CSV, null, true, ',', false);
    }

    /** A JSON array of objects, inferred schema. */
    public static LoadOptions json() {
        return new LoadOptions(Format.JSON, null, true, ',', false);
    }

    /** JSON Lines, inferred schema. */
    public static LoadOptions jsonLines() {
        return new LoadOptions(Format.JSONL, null, true, ',', false);
    }

    public LoadOptions withSchema(List<Column> newSchema) {
        return new LoadOptions(format, newSchema, header, delimiter, replace);
    }

    public LoadOptions withHeader(boolean newHeader) {
        return new LoadOptions(format, schema, newHeader, delimiter, replace);
    }

    public LoadOptions withDelimiter(char newDelimiter) {
        return new LoadOptions(format, schema, header, newDelimiter, replace);
    }

    public LoadOptions withReplace(boolean newReplace) {
        return new LoadOptions(format, schema, header, delimiter, newReplace);
    }
}
