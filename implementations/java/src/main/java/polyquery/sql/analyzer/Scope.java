package polyquery.sql.analyzer;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import polyquery.common.ErrorCode;
import polyquery.common.Names;
import polyquery.common.PolyQueryException;
import polyquery.plan.BoundExpr;
import polyquery.storage.ColumnSchema;

/**
 * Name-resolution scope of one query level: the range variables of its FROM clause, laid out
 * consecutively in the input row, plus a link to the enclosing level for correlated references.
 *
 * <p>Every level owns a correlation {@code frame} id. A column found in an enclosing level is
 * bound as an {@link BoundExpr.OuterRef} to that level's frame, and the reference is recorded
 * in every level between the reference and its target ({@link #externalRefs()}), so each
 * subquery knows exactly which outer values its result depends on.
 */
final class Scope {
    record RangeVar(String name, List<ColumnSchema> columns, int offset) {
    }

    private final Scope parent;
    private final boolean barrier;
    private final int frame;
    private final List<RangeVar> rangeVars = new ArrayList<>();
    private final Set<BoundExpr.OuterRef> externalRefs = new LinkedHashSet<>();
    private int width;

    /**
     * @param parent  enclosing level, or null
     * @param barrier true if the range variables of {@code parent} are not visible from this level
     *                (derived tables and CTE bodies); levels further out remain visible
     * @param frame   correlation frame id of this level
     */
    Scope(Scope parent, boolean barrier, int frame) {
        this.parent = parent;
        this.barrier = barrier;
        this.frame = frame;
    }

    /** A scope without columns and without enclosing levels (constant expressions). */
    static Scope empty() {
        return new Scope(null, false, -1);
    }

    int frame() {
        return frame;
    }

    void add(String name, List<ColumnSchema> columns) {
        for (RangeVar rv : rangeVars) {
            if (Names.equal(rv.name(), name)) {
                throw PolyQueryException.of(ErrorCode.SEMANTIC_ERROR, "duplicate range variable '%s'", name);
            }
        }
        rangeVars.add(new RangeVar(name, columns, width));
        width += columns.size();
    }

    List<RangeVar> rangeVars() {
        return rangeVars;
    }

    boolean isEmpty() {
        return rangeVars.isEmpty();
    }

    int width() {
        return width;
    }

    /** References to enclosing levels made from this level or levels nested in it. */
    List<BoundExpr.OuterRef> externalRefs() {
        return List.copyOf(externalRefs);
    }

    RangeVar find(String name) {
        for (RangeVar rv : rangeVars) {
            if (Names.equal(rv.name(), name)) {
                return rv;
            }
        }
        return null;
    }

    /** Resolves a (possibly qualified) column reference, searching enclosing levels if needed. */
    BoundExpr resolve(String qualifier, String name) {
        BoundExpr.ColumnRef local = resolveLocal(qualifier, name);
        if (local != null) {
            return local;
        }
        boolean skip = barrier;
        for (Scope s = parent; s != null; s = s.parent) {
            if (!skip) {
                BoundExpr.ColumnRef r = s.resolveLocal(qualifier, name);
                if (r != null) {
                    BoundExpr.OuterRef ref = new BoundExpr.OuterRef(s.frame, r.index(), r.type(), r.name());
                    markExternal(ref);
                    return ref;
                }
            }
            skip = s.barrier;
        }
        if (qualifier != null) {
            throw PolyQueryException.of(ErrorCode.SEMANTIC_ERROR, "unknown table or alias '%s'", qualifier);
        }
        throw PolyQueryException.of(ErrorCode.SEMANTIC_ERROR, "unknown column '%s'", name);
    }

    /** Records that {@code ref} (to an enclosing level) is used from within this level. */
    void markExternal(BoundExpr.OuterRef ref) {
        for (Scope s = this; s != null && s.frame != ref.frame(); s = s.parent) {
            s.externalRefs.add(ref);
        }
    }

    /**
     * Resolves against this level only: null if not found here; SEMANTIC_ERROR if the qualifier
     * names a range variable of this level that lacks the column, or if the name is ambiguous.
     */
    BoundExpr.ColumnRef resolveLocal(String qualifier, String name) {
        if (qualifier != null) {
            RangeVar rv = find(qualifier);
            if (rv == null) {
                return null;
            }
            BoundExpr.ColumnRef ref = lookup(rv, name);
            if (ref == null) {
                throw PolyQueryException.of(ErrorCode.SEMANTIC_ERROR, "unknown column '%s.%s'", qualifier, name);
            }
            return ref;
        }
        BoundExpr.ColumnRef found = null;
        for (RangeVar rv : rangeVars) {
            BoundExpr.ColumnRef ref = lookup(rv, name);
            if (ref != null) {
                if (found != null) {
                    throw PolyQueryException.of(ErrorCode.SEMANTIC_ERROR, "ambiguous column '%s'", name);
                }
                found = ref;
            }
        }
        return found;
    }

    private static BoundExpr.ColumnRef lookup(RangeVar rv, String name) {
        BoundExpr.ColumnRef found = null;
        for (int i = 0; i < rv.columns().size(); i++) {
            ColumnSchema c = rv.columns().get(i);
            if (Names.equal(c.name(), name)) {
                if (found != null) {
                    throw PolyQueryException.of(ErrorCode.SEMANTIC_ERROR, "ambiguous column '%s'", name);
                }
                found = new BoundExpr.ColumnRef(rv.offset() + i, c.type(), c.name());
            }
        }
        return found;
    }
}
