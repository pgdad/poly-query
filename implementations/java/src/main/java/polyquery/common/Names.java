package polyquery.common;

/** Identifier matching: ASCII case-insensitive (non-ASCII characters must match exactly). */
public final class Names {
    private Names() {
    }

    /** Lookup key: ASCII letters lower-cased, everything else unchanged. */
    public static String key(String name) {
        int n = name.length();
        int i = 0;
        while (i < n && !(name.charAt(i) >= 'A' && name.charAt(i) <= 'Z')) {
            i++;
        }
        if (i == n) {
            return name;
        }
        char[] cs = name.toCharArray();
        for (; i < n; i++) {
            char c = cs[i];
            if (c >= 'A' && c <= 'Z') {
                cs[i] = (char) (c + ('a' - 'A'));
            }
        }
        return new String(cs);
    }

    public static boolean equal(String a, String b) {
        if (a.length() != b.length()) {
            return false;
        }
        for (int i = 0; i < a.length(); i++) {
            char x = a.charAt(i);
            char y = b.charAt(i);
            if (x != y) {
                if (x >= 'A' && x <= 'Z') {
                    x = (char) (x + ('a' - 'A'));
                }
                if (y >= 'A' && y <= 'Z') {
                    y = (char) (y + ('a' - 'A'));
                }
                if (x != y) {
                    return false;
                }
            }
        }
        return true;
    }
}
