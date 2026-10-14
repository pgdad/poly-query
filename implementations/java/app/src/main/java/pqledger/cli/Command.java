package pqledger.cli;

import java.util.Set;

/**
 * The commands of pqledger with the options and number of positional arguments each accepts
 * (spec §2). {@code valueOptions} take the next argument as value; {@code flags} take none.
 */
public enum Command {
    INIT("init", Set.of(), Set.of(), 0, 0),
    IMPORT("import", Set.of("--account"), Set.of(), 1, 1),
    REPORT_MONTHLY("report monthly", Filters.OPTIONS, Set.of(), 0, 0),
    REPORT_CATEGORIES("report categories", Filters.OPTIONS, Set.of(), 0, 0),
    REPORT_MERCHANTS("report merchants", with(Filters.OPTIONS, "--top"), Set.of(), 0, 0),
    BUDGET("budget", Set.of("--month", "--account"), Set.of(), 0, 0),
    ACCOUNTS("accounts", Set.of(), Set.of(), 0, 0),
    LIST("list", with(Filters.OPTIONS, "--category"), Set.of("--uncategorized"), 0, 0),
    EXPORT("export", Filters.OPTIONS, Set.of(), 0, 0),
    SET_CATEGORY("set-category", Set.of(), Set.of("--clear"), 1, 2),
    QUERY("query", Set.of(), Set.of(), 1, 1),
    HELP("help", Set.of(), Set.of(), 0, 0),
    VERSION("version", Set.of(), Set.of(), 0, 0);

    private final String displayName;
    private final Set<String> valueOptions;
    private final Set<String> flags;
    private final int minPositionals;
    private final int maxPositionals;

    Command(String displayName, Set<String> valueOptions, Set<String> flags, int minPositionals, int maxPositionals) {
        this.displayName = displayName;
        this.valueOptions = valueOptions;
        this.flags = flags;
        this.minPositionals = minPositionals;
        this.maxPositionals = maxPositionals;
    }

    private static Set<String> with(Set<String> base, String extra) {
        java.util.HashSet<String> s = new java.util.HashSet<>(base);
        s.add(extra);
        return Set.copyOf(s);
    }

    public String displayName() {
        return displayName;
    }

    Set<String> valueOptions() {
        return valueOptions;
    }

    Set<String> flags() {
        return flags;
    }

    int minPositionals() {
        return minPositionals;
    }

    int maxPositionals() {
        return maxPositionals;
    }

    /** True if the command works on an existing ledger (all but init, help and version). */
    public boolean needsLedger() {
        return this != INIT && this != HELP && this != VERSION;
    }

    /** True if the command needs a configuration file (all but help and version). */
    public boolean needsConfig() {
        return this != HELP && this != VERSION;
    }
}
