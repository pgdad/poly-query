package pqledger.importer;

import java.util.regex.Pattern;
import pqledger.config.ImportSettings;
import pqledger.config.LineSyntax;

/** Converts amount fields of bank exports to cents (spec §6.2 step 3). */
public final class AmountParser {
    private static final Pattern AMOUNT = Pattern.compile("[0-9]{1,16}(\\.[0-9]{1,2})?");

    private final char decimalSeparator;
    private final String thousandsSeparator;
    private final String currencySymbol;

    public AmountParser(ImportSettings settings) {
        this.decimalSeparator = settings.decimalSeparator();
        this.thousandsSeparator = settings.thousandsSeparator();
        this.currencySymbol = settings.currencySymbol();
    }

    /** True if the field is empty after trimming spaces and tabs. */
    public static boolean isBlank(String field) {
        return LineSyntax.trim(field).isEmpty();
    }

    /**
     * The amount in cents.
     *
     * @throws IllegalArgumentException if the field is not a valid amount
     */
    public long parse(String field) {
        String t = LineSyntax.trim(field);
        boolean negative = false;
        if (t.length() >= 2 && t.startsWith("(") && t.endsWith(")")) {
            negative = true;
            t = t.substring(1, t.length() - 1);
        } else if (t.startsWith("-")) {
            negative = true;
            t = t.substring(1);
        } else if (t.startsWith("+")) {
            t = t.substring(1);
        }
        if (!currencySymbol.isEmpty()) {
            if (t.startsWith(currencySymbol)) {
                t = t.substring(currencySymbol.length());
            } else if (t.endsWith(currencySymbol)) {
                t = t.substring(0, t.length() - currencySymbol.length());
            }
            t = LineSyntax.trim(t);
        }
        if (!thousandsSeparator.isEmpty()) {
            t = t.replace(thousandsSeparator, "");
        }
        if (decimalSeparator != '.') {
            t = t.replace(decimalSeparator, '.');
        }
        if (!AMOUNT.matcher(t).matches()) {
            throw new IllegalArgumentException("invalid amount '" + LineSyntax.trim(field) + "'");
        }
        int point = t.indexOf('.');
        long cents;
        if (point < 0) {
            cents = Long.parseLong(t) * 100;
        } else {
            String frac = t.substring(point + 1);
            cents = Long.parseLong(t.substring(0, point)) * 100 + Long.parseLong(frac) * (frac.length() == 1 ? 10 : 1);
        }
        return negative ? -cents : cents;
    }
}
