package polyquery.plan;

/** Sort on column {@code column} of the input row. */
public record SortKey(int column, boolean descending, boolean nullsFirst) {
}
