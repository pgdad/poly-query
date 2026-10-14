package pqledger.importer;

/** Merchant normalization (spec §6.3). */
public final class Merchants {
    private Merchants() {
    }

    /**
     * Upper-cases ASCII letters, collapses runs of spaces and tabs into one space, trims, and
     * removes a trailing store-number token ({@code #123} or three or more digits) once.
     */
    public static String normalize(String description) {
        StringBuilder sb = new StringBuilder(description.length());
        boolean space = false;
        for (int i = 0; i < description.length(); i++) {
            char c = description.charAt(i);
            if (c == ' ' || c == '\t') {
                space = true;
                continue;
            }
            if (space && !sb.isEmpty()) {
                sb.append(' ');
            }
            space = false;
            sb.append(c >= 'a' && c <= 'z' ? (char) (c - ('a' - 'A')) : c);
        }
        String s = sb.toString();
        int last = s.lastIndexOf(' ');
        if (last >= 0 && isStoreNumber(s.substring(last + 1))) {
            return s.substring(0, last);
        }
        return s;
    }

    private static boolean isStoreNumber(String token) {
        int digitsFrom = token.startsWith("#") ? 1 : 0;
        int digits = token.length() - digitsFrom;
        if (digits < (digitsFrom == 1 ? 1 : 3)) {
            return false;
        }
        for (int i = digitsFrom; i < token.length(); i++) {
            if (token.charAt(i) < '0' || token.charAt(i) > '9') {
                return false;
            }
        }
        return true;
    }
}
