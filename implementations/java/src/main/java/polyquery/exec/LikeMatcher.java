package polyquery.exec;

/**
 * SQL LIKE matching (semantics.md §11): {@code %} matches any sequence of code points,
 * {@code _} exactly one; case-sensitive, whole string, no escape character.
 */
public final class LikeMatcher {
    private final int[] pattern;

    public LikeMatcher(String pattern) {
        this.pattern = pattern.codePoints().toArray();
    }

    public boolean matches(String s) {
        int[] str = s.codePoints().toArray();
        int n = str.length;
        int m = pattern.length;
        int si = 0;
        int pi = 0;
        int starP = -1;
        int starS = 0;
        while (si < n) {
            if (pi < m && pattern[pi] == '%') {
                starP = pi++;
                starS = si;
            } else if (pi < m && (pattern[pi] == '_' || pattern[pi] == str[si])) {
                si++;
                pi++;
            } else if (starP >= 0) {
                // Let the last '%' absorb one more code point and retry.
                pi = starP + 1;
                si = ++starS;
            } else {
                return false;
            }
        }
        while (pi < m && pattern[pi] == '%') {
            pi++;
        }
        return pi == m;
    }
}
