package pqledger.config;

import java.util.List;
import java.util.regex.Pattern;

/**
 * A column reference of the import settings (spec §3.3): a 1-based position or a header name
 * (matched after trimming spaces and tabs, ASCII case-insensitively).
 *
 * @param position 1-based position, or 0 for a name reference
 * @param name     header name, or null for a position reference
 */
public record ColumnRef(int position, String name) {
    private static final Pattern DIGITS = Pattern.compile("[0-9]+");

    /** Parses a reference; null if invalid (empty, or a position that is 0 or too large). */
    public static ColumnRef parse(String text) {
        if (text.isEmpty()) {
            return null;
        }
        if (DIGITS.matcher(text).matches()) {
            String digits = text.replaceFirst("^0+", "");
            if (digits.isEmpty() || digits.length() > 9) {
                return null;
            }
            return new ColumnRef(Integer.parseInt(digits), null);
        }
        return new ColumnRef(0, text);
    }

    public boolean isName() {
        return name != null;
    }

    /**
     * The 0-based index of the referenced column in {@code header} (null if there is none), or
     * -1 if a name is not found.
     */
    public int resolve(List<String> header) {
        if (!isName()) {
            return position - 1;
        }
        for (int i = 0; i < header.size(); i++) {
            if (asciiEqualsIgnoreCase(LineSyntax.trim(header.get(i)), name)) {
                return i;
            }
        }
        return -1;
    }

    private static boolean asciiEqualsIgnoreCase(String a, String b) {
        if (a.length() != b.length()) {
            return false;
        }
        for (int i = 0; i < a.length(); i++) {
            char x = a.charAt(i);
            char y = b.charAt(i);
            if (x != y && lower(x) != lower(y)) {
                return false;
            }
        }
        return true;
    }

    private static char lower(char c) {
        return c >= 'A' && c <= 'Z' ? (char) (c + ('a' - 'A')) : c;
    }

    @Override
    public String toString() {
        return isName() ? name : Integer.toString(position);
    }
}
