package pqledger.config;

import java.time.DateTimeException;
import java.time.LocalDate;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** The date formats of bank exports (spec §3.3, §6.2). */
public enum DateFormat {
    ISO("YYYY-MM-DD", "([0-9]{4})-([0-9]{2})-([0-9]{2})", 1, 2, 3),
    COMPACT("YYYYMMDD", "([0-9]{4})([0-9]{2})([0-9]{2})", 1, 2, 3),
    US("MM/DD/YYYY", "([0-9]{1,2})/([0-9]{1,2})/([0-9]{4})", 3, 1, 2),
    EUROPEAN("DD/MM/YYYY", "([0-9]{1,2})/([0-9]{1,2})/([0-9]{4})", 3, 2, 1),
    GERMAN("DD.MM.YYYY", "([0-9]{1,2})\\.([0-9]{1,2})\\.([0-9]{4})", 3, 2, 1);

    private final String text;
    private final Pattern pattern;
    private final int yearGroup;
    private final int monthGroup;
    private final int dayGroup;

    DateFormat(String text, String regex, int yearGroup, int monthGroup, int dayGroup) {
        this.text = text;
        this.pattern = Pattern.compile(regex);
        this.yearGroup = yearGroup;
        this.monthGroup = monthGroup;
        this.dayGroup = dayGroup;
    }

    /** The format written as in the configuration, e.g. {@code MM/DD/YYYY}; null if unknown. */
    public static DateFormat fromText(String text) {
        for (DateFormat f : values()) {
            if (f.text.equals(text)) {
                return f;
            }
        }
        return null;
    }

    /** Parses an (already trimmed) date; null unless it has this format and is a valid date ≥ 0001-01-01. */
    public LocalDate parse(String s) {
        Matcher m = pattern.matcher(s);
        if (!m.matches()) {
            return null;
        }
        int year = Integer.parseInt(m.group(yearGroup));
        if (year < 1) {
            return null;
        }
        try {
            return LocalDate.of(year, Integer.parseInt(m.group(monthGroup)), Integer.parseInt(m.group(dayGroup)));
        } catch (DateTimeException e) {
            return null;
        }
    }

    @Override
    public String toString() {
        return text;
    }
}
