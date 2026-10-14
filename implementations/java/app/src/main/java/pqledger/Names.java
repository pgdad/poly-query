package pqledger;

import java.util.regex.Pattern;

/** Account and category names (spec §3.3). */
public final class Names {
    private static final Pattern NAME = Pattern.compile("[a-z0-9_-]{1,32}");

    /** The category of transactions without an override or matching rule. */
    public static final String UNCATEGORIZED = "uncategorized";

    private Names() {
    }

    public static boolean isAccount(String s) {
        return NAME.matcher(s).matches();
    }

    public static boolean isCategory(String s) {
        return NAME.matcher(s).matches() && !s.equals(UNCATEGORIZED);
    }
}
