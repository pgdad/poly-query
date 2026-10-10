package polyquery.index;

import java.util.ArrayList;
import java.util.List;
import java.util.TreeSet;

/**
 * A predicate on a single column expressed in its key domain ({@link KeyDomain}); it never
 * matches NULL. Produced by the planner from conjuncts such as {@code col = c},
 * {@code col IN (…)}, {@code col < c} or {@code col BETWEEN a AND b}.
 */
public sealed interface KeyPredicate {
    /** Matches exactly the given keys (sorted, distinct). */
    record Points(List<Object> keys) implements KeyPredicate {
        public static Points of(List<Object> keys) {
            TreeSet<Object> set = new TreeSet<>(KeyDomain::compare);
            set.addAll(keys);
            return new Points(List.copyOf(set));
        }

        /** The keys that also satisfy {@code other}. */
        KeyPredicate filter(KeyPredicate other) {
            List<Object> kept = new ArrayList<>();
            for (Object k : keys) {
                boolean match = switch (other) {
                    case Empty e -> false;
                    case Range r -> r.contains(k);
                    case Points p -> p.keys().stream().anyMatch(x -> KeyDomain.compare(x, k) == 0);
                };
                if (match) {
                    kept.add(k);
                }
            }
            return kept.isEmpty() ? new Empty() : new Points(kept);
        }
    }

    /** Matches keys between the bounds; a null bound is unbounded. */
    record Range(Object lower, boolean lowerInclusive, Object upper, boolean upperInclusive) implements KeyPredicate {
        public boolean contains(Object key) {
            if (lower != null) {
                int c = KeyDomain.compare(key, lower);
                if (c < 0 || (c == 0 && !lowerInclusive)) {
                    return false;
                }
            }
            if (upper != null) {
                int c = KeyDomain.compare(key, upper);
                return c < 0 || (c == 0 && upperInclusive);
            }
            return true;
        }
    }

    /** Matches nothing. */
    record Empty() implements KeyPredicate {
    }

    /** True if the predicate matches some key in {@code [min, max]}. */
    default boolean overlaps(Object min, Object max) {
        return switch (this) {
            case Empty e -> false;
            case Points p -> {
                for (Object k : p.keys()) {
                    if (KeyDomain.compare(k, min) >= 0 && KeyDomain.compare(k, max) <= 0) {
                        yield true;
                    }
                }
                yield false;
            }
            case Range r -> {
                if (r.lower() != null) {
                    int c = KeyDomain.compare(max, r.lower());
                    if (c < 0 || (c == 0 && !r.lowerInclusive())) {
                        yield false;
                    }
                }
                if (r.upper() != null) {
                    int c = KeyDomain.compare(min, r.upper());
                    if (c > 0 || (c == 0 && !r.upperInclusive())) {
                        yield false;
                    }
                }
                yield true;
            }
        };
    }

    /** Conjunction of two predicates on the same column. */
    default KeyPredicate and(KeyPredicate other) {
        if (this instanceof Empty || other instanceof Empty) {
            return new Empty();
        }
        if (this instanceof Points p) {
            return p.filter(other);
        }
        if (other instanceof Points p) {
            return p.filter(this);
        }
        Range a = (Range) this;
        Range b = (Range) other;
        Object lo = a.lower();
        boolean loInc = a.lowerInclusive();
        if (b.lower() != null) {
            int c = lo == null ? -1 : KeyDomain.compare(lo, b.lower());
            if (c < 0 || (c == 0 && !b.lowerInclusive())) {
                lo = b.lower();
                loInc = b.lowerInclusive();
            }
        }
        Object hi = a.upper();
        boolean hiInc = a.upperInclusive();
        if (b.upper() != null) {
            int c = hi == null ? 1 : KeyDomain.compare(hi, b.upper());
            if (c > 0 || (c == 0 && !b.upperInclusive())) {
                hi = b.upper();
                hiInc = b.upperInclusive();
            }
        }
        if (lo != null && hi != null) {
            int c = KeyDomain.compare(lo, hi);
            if (c > 0 || (c == 0 && !(loInc && hiInc))) {
                return new Empty();
            }
        }
        return new Range(lo, loInc, hi, hiInc);
    }
}
