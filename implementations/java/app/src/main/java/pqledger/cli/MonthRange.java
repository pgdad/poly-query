package pqledger.cli;

import java.time.LocalDate;
import java.time.YearMonth;
import java.util.regex.Pattern;

/**
 * An inclusive range of months; either end may be open (null).
 *
 * @param from first month, or null
 * @param to   last month, or null
 */
public record MonthRange(YearMonth from, YearMonth to) {
    private static final Pattern MONTH = Pattern.compile("[0-9]{4}-[0-9]{2}");

    public static final MonthRange ALL = new MonthRange(null, null);

    public static MonthRange of(YearMonth month) {
        return new MonthRange(month, month);
    }

    /** Parses {@code YYYY-MM} (year 0001–9999, month 01–12); null if malformed. */
    public static YearMonth parseMonth(String text) {
        if (!MONTH.matcher(text).matches()) {
            return null;
        }
        int year = Integer.parseInt(text.substring(0, 4));
        int month = Integer.parseInt(text.substring(5, 7));
        if (year < 1 || month < 1 || month > 12) {
            return null;
        }
        return YearMonth.of(year, month);
    }

    /** The first day of the range, or null if open. */
    public LocalDate firstDay() {
        return from == null ? null : from.atDay(1);
    }

    /** The last day of the range, or null if open. */
    public LocalDate lastDay() {
        return to == null ? null : to.atEndOfMonth();
    }
}
