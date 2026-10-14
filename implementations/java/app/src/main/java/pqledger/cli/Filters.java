package pqledger.cli;

import java.util.Set;

/**
 * The common filter options {@code --month}, {@code --from}, {@code --to} and
 * {@code --account} (spec §2).
 *
 * @param months  the month range (open ends allowed)
 * @param account the account name, or null for all accounts
 */
public record Filters(MonthRange months, String account) {
    static final Set<String> OPTIONS = Set.of("--month", "--from", "--to", "--account");

    public static final Filters NONE = new Filters(MonthRange.ALL, null);
}
