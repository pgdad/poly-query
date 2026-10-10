package polyquery.index;

/** Index structures (indexes-and-planning.md §2). */
public enum IndexKind {
    /** Equality lookups. */
    HASH,
    /** Ordered structure (sorted permutation): equality and range lookups. */
    BTREE
}
