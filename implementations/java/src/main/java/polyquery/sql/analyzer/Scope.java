package polyquery.sql.analyzer;

import java.util.ArrayList;
import java.util.List;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.plan.BoundExpr;
import polyquery.storage.ColumnSchema;

/**
 * Name-resolution scope of one query level: the range variables of its FROM clause, laid out
 * consecutively in the input row.
 */
final class Scope {
    record RangeVar(String name, List<ColumnSchema> columns, int offset) {
    }

    private final List<RangeVar> rangeVars = new ArrayList<>();
    private int width;

    static Scope empty() {
        return new Scope();
    }

    void add(String name, List<ColumnSchema> columns) {
        for (RangeVar rv : rangeVars) {
            if (rv.name().equalsIgnoreCase(name)) {
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

    RangeVar find(String name) {
        for (RangeVar rv : rangeVars) {
            if (rv.name().equalsIgnoreCase(name)) {
                return rv;
            }
        }
        return null;
    }

    /** Resolves a (possibly qualified) column reference. */
    BoundExpr.ColumnRef resolve(String qualifier, String name) {
        if (qualifier != null) {
            RangeVar rv = find(qualifier);
            if (rv == null) {
                throw PolyQueryException.of(ErrorCode.SEMANTIC_ERROR, "unknown table or alias '%s'", qualifier);
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
        if (found == null) {
            throw PolyQueryException.of(ErrorCode.SEMANTIC_ERROR, "unknown column '%s'", name);
        }
        return found;
    }

    private static BoundExpr.ColumnRef lookup(RangeVar rv, String name) {
        BoundExpr.ColumnRef found = null;
        for (int i = 0; i < rv.columns().size(); i++) {
            ColumnSchema c = rv.columns().get(i);
            if (c.name().equalsIgnoreCase(name)) {
                if (found != null) {
                    throw PolyQueryException.of(ErrorCode.SEMANTIC_ERROR, "ambiguous column '%s'", name);
                }
                found = new BoundExpr.ColumnRef(rv.offset() + i, c.type(), c.name());
            }
        }
        return found;
    }
}
