package pqledger.config;

import java.util.Set;
import java.util.regex.Pattern;

/**
 * How the bank CSV files of an account are read (spec §3.3, the keys of {@code [import]} and
 * {@code [account NAME]}).
 *
 * @param thousandsSeparator the separator removed from amounts, or "" for none
 * @param currencySymbol     text removed from amounts, or "" for none
 */
public record ImportSettings(char delimiter, boolean header, int skipLines, ColumnRef dateColumn,
                             DateFormat dateFormat, ColumnRef descriptionColumn, AmountMode amountMode,
                             ColumnRef amountColumn, ColumnRef debitColumn, ColumnRef creditColumn,
                             char decimalSeparator, String thousandsSeparator, String currencySymbol,
                             boolean invertSign) {
    /** {@code signed}: one amount column; {@code debit_credit}: credit minus debit. */
    public enum AmountMode {
        SIGNED,
        DEBIT_CREDIT
    }

    /** The keys of {@code [import]} and {@code [account NAME]}. */
    public static final Set<String> KEYS = Set.of("delimiter", "header", "skip_lines", "date_column", "date_format",
            "description_column", "amount_mode", "amount_column", "debit_column", "credit_column",
            "decimal_separator", "thousands_separator", "currency_symbol", "invert_sign");

    public static final ImportSettings DEFAULTS = new ImportSettings(',', true, 0, ColumnRef.parse("Date"),
            DateFormat.ISO, ColumnRef.parse("Description"), AmountMode.SIGNED, ColumnRef.parse("Amount"),
            ColumnRef.parse("Debit"), ColumnRef.parse("Credit"), '.', "", "", false);

    private static final Pattern DIGITS = Pattern.compile("[0-9]+");

    /**
     * A copy with {@code key} set to {@code value}.
     *
     * @throws IllegalArgumentException with a message describing an unknown key or invalid value
     */
    public ImportSettings with(String key, String value) {
        Builder b = new Builder(this);
        switch (key) {
            case "delimiter" -> b.delimiter = delimiterChar(value);
            case "header" -> b.header = bool(key, value);
            case "skip_lines" -> b.skipLines = count(key, value);
            case "date_column" -> b.dateColumn = column(key, value);
            case "date_format" -> b.dateFormat = dateFormat(value);
            case "description_column" -> b.descriptionColumn = column(key, value);
            case "amount_mode" -> b.amountMode = amountMode(value);
            case "amount_column" -> b.amountColumn = column(key, value);
            case "debit_column" -> b.debitColumn = column(key, value);
            case "credit_column" -> b.creditColumn = column(key, value);
            case "decimal_separator" -> b.decimalSeparator = decimalSeparator(value);
            case "thousands_separator" -> b.thousandsSeparator = thousandsSeparator(value);
            case "currency_symbol" -> b.currencySymbol = value;
            case "invert_sign" -> b.invertSign = bool(key, value);
            default -> throw new IllegalArgumentException("unknown key '" + key + "'");
        }
        return b.build();
    }

    /** Mutable copy used by {@link #with}. */
    private static final class Builder {
        private char delimiter;
        private boolean header;
        private int skipLines;
        private ColumnRef dateColumn;
        private DateFormat dateFormat;
        private ColumnRef descriptionColumn;
        private AmountMode amountMode;
        private ColumnRef amountColumn;
        private ColumnRef debitColumn;
        private ColumnRef creditColumn;
        private char decimalSeparator;
        private String thousandsSeparator;
        private String currencySymbol;
        private boolean invertSign;

        Builder(ImportSettings s) {
            delimiter = s.delimiter;
            header = s.header;
            skipLines = s.skipLines;
            dateColumn = s.dateColumn;
            dateFormat = s.dateFormat;
            descriptionColumn = s.descriptionColumn;
            amountMode = s.amountMode;
            amountColumn = s.amountColumn;
            debitColumn = s.debitColumn;
            creditColumn = s.creditColumn;
            decimalSeparator = s.decimalSeparator;
            thousandsSeparator = s.thousandsSeparator;
            currencySymbol = s.currencySymbol;
            invertSign = s.invertSign;
        }

        ImportSettings build() {
            return new ImportSettings(delimiter, header, skipLines, dateColumn, dateFormat, descriptionColumn,
                    amountMode, amountColumn, debitColumn, creditColumn, decimalSeparator, thousandsSeparator,
                    currencySymbol, invertSign);
        }
    }

    /**
     * Checks the rules between keys that hold for every effective setting.
     *
     * @throws IllegalArgumentException if the decimal and thousands separators are equal
     */
    public void validate() {
        if (thousandsSeparator.equals(String.valueOf(decimalSeparator))) {
            throw new IllegalArgumentException("decimal_separator and thousands_separator must differ (both '"
                    + decimalSeparator + "')");
        }
    }

    /** The column references the amount mode uses. */
    public java.util.List<ColumnRef> referencedColumns() {
        return amountMode == AmountMode.SIGNED
                ? java.util.List.of(dateColumn, descriptionColumn, amountColumn)
                : java.util.List.of(dateColumn, descriptionColumn, debitColumn, creditColumn);
    }

    private static char delimiterChar(String v) {
        if (v.equals("tab")) {
            return '\t';
        }
        if (v.length() != 1 || v.charAt(0) > 127 || v.charAt(0) == '"' || v.charAt(0) == '\r'
                || v.charAt(0) == '\n') {
            throw new IllegalArgumentException("delimiter must be one ASCII character (not '\"') or 'tab', got '"
                    + v + "'");
        }
        return v.charAt(0);
    }

    private static boolean bool(String key, String v) {
        return switch (v) {
            case "true" -> true;
            case "false" -> false;
            default -> throw new IllegalArgumentException(key + " must be true or false, got '" + v + "'");
        };
    }

    private static int count(String key, String v) {
        if (!DIGITS.matcher(v).matches()) {
            throw new IllegalArgumentException(key + " must be an integer >= 0, got '" + v + "'");
        }
        String digits = v.replaceFirst("^0+(?=.)", "");
        return digits.length() > 9 ? Integer.MAX_VALUE : Integer.parseInt(digits);
    }

    private static ColumnRef column(String key, String v) {
        ColumnRef ref = ColumnRef.parse(v);
        if (ref == null) {
            throw new IllegalArgumentException(key + " must be a column position >= 1 or a header name, got '"
                    + v + "'");
        }
        return ref;
    }

    private static DateFormat dateFormat(String v) {
        DateFormat f = DateFormat.fromText(v);
        if (f == null) {
            throw new IllegalArgumentException("date_format must be YYYY-MM-DD, YYYYMMDD, MM/DD/YYYY, DD/MM/YYYY "
                    + "or DD.MM.YYYY, got '" + v + "'");
        }
        return f;
    }

    private static AmountMode amountMode(String v) {
        return switch (v) {
            case "signed" -> AmountMode.SIGNED;
            case "debit_credit" -> AmountMode.DEBIT_CREDIT;
            default -> throw new IllegalArgumentException("amount_mode must be signed or debit_credit, got '"
                    + v + "'");
        };
    }

    private static char decimalSeparator(String v) {
        if (!v.equals(".") && !v.equals(",")) {
            throw new IllegalArgumentException("decimal_separator must be '.' or ',', got '" + v + "'");
        }
        return v.charAt(0);
    }

    private static String thousandsSeparator(String v) {
        return switch (v) {
            case "none" -> "";
            case ",", ".", "'" -> v;
            case "space" -> " ";
            default -> throw new IllegalArgumentException("thousands_separator must be none, ',', '.', space or "
                    + "\"'\", got '" + v + "'");
        };
    }
}
