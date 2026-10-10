package polyquery.index;

/** The lookup structure of an index over one column. Immutable, safe for concurrent readers. */
public sealed interface IndexStructure permits HashIndex, OrderedIndex {
    /** True if {@link #lookup} can evaluate the predicate. */
    boolean supports(KeyPredicate predicate);

    /** Ascending ids of the rows whose (non-null) key satisfies the predicate. */
    int[] lookup(KeyPredicate predicate);

    /** Number of distinct keys. */
    int distinctKeys();
}
