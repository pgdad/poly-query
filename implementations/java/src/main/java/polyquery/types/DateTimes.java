package polyquery.types;

import java.time.DateTimeException;
import java.time.LocalDate;

/** DATE (days since epoch) and TIMESTAMP (microseconds since epoch) parsing and formatting. */
public final class DateTimes {
    public static final long MICROS_PER_SECOND = 1_000_000L;
    public static final long MICROS_PER_DAY = 86_400L * MICROS_PER_SECOND;
    public static final int MIN_DAY = (int) LocalDate.of(1, 1, 1).toEpochDay();
    public static final int MAX_DAY = (int) LocalDate.of(9999, 12, 31).toEpochDay();

    private DateTimes() {
    }

    private static boolean digits(String s, int from, int to) {
        for (int i = from; i < to; i++) {
            char c = s.charAt(i);
            if (c < '0' || c > '9') {
                return false;
            }
        }
        return true;
    }

    private static int num(String s, int from, int to) {
        int v = 0;
        for (int i = from; i < to; i++) {
            v = v * 10 + (s.charAt(i) - '0');
        }
        return v;
    }

    /** Parses {@code YYYY-MM-DD}; returns null if the text is not a valid calendar date. */
    public static Integer parseDate(String s) {
        if (s.length() != 10 || s.charAt(4) != '-' || s.charAt(7) != '-'
                || !digits(s, 0, 4) || !digits(s, 5, 7) || !digits(s, 8, 10)) {
            return null;
        }
        return toEpochDay(num(s, 0, 4), num(s, 5, 7), num(s, 8, 10));
    }

    private static Integer toEpochDay(int y, int m, int d) {
        if (y < 1) {
            return null;
        }
        try {
            return (int) LocalDate.of(y, m, d).toEpochDay();
        } catch (DateTimeException e) {
            return null;
        }
    }

    /**
     * Parses {@code YYYY-MM-DD[ T]HH:MM:SS[.f{1,6}]}, and also a bare date if {@code allowDate}.
     * Returns null when the text is not a valid timestamp.
     */
    public static Long parseTimestamp(String s, boolean allowDate) {
        if (s.length() == 10) {
            if (!allowDate) {
                return null;
            }
            Integer d = parseDate(s);
            return d == null ? null : d * MICROS_PER_DAY;
        }
        if (s.length() < 19) {
            return null;
        }
        Integer day = parseDate(s.substring(0, 10));
        char sep = s.charAt(10);
        if (day == null || (sep != ' ' && sep != 'T') || s.charAt(13) != ':' || s.charAt(16) != ':'
                || !digits(s, 11, 13) || !digits(s, 14, 16) || !digits(s, 17, 19)) {
            return null;
        }
        int hh = num(s, 11, 13);
        int mm = num(s, 14, 16);
        int ss = num(s, 17, 19);
        if (hh > 23 || mm > 59 || ss > 59) {
            return null;
        }
        long micros = 0;
        if (s.length() > 19) {
            int fracLen = s.length() - 20;
            if (s.charAt(19) != '.' || fracLen < 1 || fracLen > 6 || !digits(s, 20, s.length())) {
                return null;
            }
            micros = num(s, 20, s.length()) * Decimals.pow10(6 - fracLen);
        }
        return day * MICROS_PER_DAY + ((hh * 60L + mm) * 60L + ss) * MICROS_PER_SECOND + micros;
    }

    public static boolean isDateSyntax(String s) {
        return parseDate(s) != null;
    }

    public static String formatDate(int epochDay) {
        LocalDate d = LocalDate.ofEpochDay(epochDay);
        StringBuilder sb = new StringBuilder(10);
        pad(sb, d.getYear(), 4).append('-');
        pad(sb, d.getMonthValue(), 2).append('-');
        pad(sb, d.getDayOfMonth(), 2);
        return sb.toString();
    }

    public static String formatTimestamp(long micros) {
        long day = Math.floorDiv(micros, MICROS_PER_DAY);
        long rem = Math.floorMod(micros, MICROS_PER_DAY);
        long secs = rem / MICROS_PER_SECOND;
        long frac = rem % MICROS_PER_SECOND;
        StringBuilder sb = new StringBuilder(26);
        sb.append(formatDate((int) day)).append(' ');
        pad(sb, (int) (secs / 3600), 2).append(':');
        pad(sb, (int) (secs / 60 % 60), 2).append(':');
        pad(sb, (int) (secs % 60), 2);
        if (frac != 0) {
            sb.append('.');
            pad(sb, (int) frac, 6);
        }
        return sb.toString();
    }

    private static StringBuilder pad(StringBuilder sb, int v, int width) {
        String s = Integer.toString(v);
        sb.repeat('0', width - s.length());
        return sb.append(s);
    }

    /** Date part (truncation) of a timestamp. */
    public static int dateOf(long micros) {
        return (int) Math.floorDiv(micros, MICROS_PER_DAY);
    }

    public static long timestampOf(int epochDay) {
        return epochDay * MICROS_PER_DAY;
    }
}
