package polyquery.physical;

import java.lang.reflect.Array;
import java.lang.reflect.RecordComponent;
import java.util.ArrayList;
import java.util.List;
import polyquery.plan.BoundExpr;
import polyquery.plan.Subquery;

/**
 * Structural identity of physical subplans, for reusing a subplan's result within one query
 * (e.g. a CTE referenced twice is inlined twice and planned the same way both times).
 */
public final class PlanKeys {
    private PlanKeys() {
    }

    /** Thrown internally when a plan is not invariant. */
    private static final class Variant extends Exception {
        Variant() {
            super(null, null, false, false);
        }
    }

    /**
     * A key equal for two subplans exactly when they are structurally identical (same nodes,
     * expressions, tables and indexes — tables of the query's catalog snapshot compare by
     * identity), or null if the subplan's result may differ between two executions in one
     * query: it refers to enclosing query levels, contains subqueries or calls PQ_SLEEP.
     */
    public static Object resultKey(PhysicalPlan plan) {
        try {
            return key(plan);
        } catch (Variant | ReflectiveOperationException | RuntimeException e) {
            return null;
        }
    }

    private static Object key(Object v) throws Variant, ReflectiveOperationException {
        if (v == null || v instanceof String || v instanceof Number || v instanceof Boolean || v instanceof Enum<?>) {
            return v;
        }
        if (v instanceof BoundExpr.OuterRef || v instanceof Subquery
                || v instanceof BoundExpr.Function f && f.name().equals("PQ_SLEEP")) {
            throw new Variant();
        }
        if (v instanceof Record r) {
            RecordComponent[] parts = r.getClass().getRecordComponents();
            List<Object> out = new ArrayList<>(parts.length + 1);
            out.add(r.getClass());
            for (RecordComponent c : parts) {
                var accessor = c.getAccessor();
                accessor.setAccessible(true);
                out.add(key(accessor.invoke(r)));
            }
            return out;
        }
        if (v instanceof List<?> list) {
            List<Object> out = new ArrayList<>(list.size());
            for (Object x : list) {
                out.add(key(x));
            }
            return out;
        }
        if (v.getClass().isArray()) {
            int n = Array.getLength(v);
            List<Object> out = new ArrayList<>(n + 1);
            out.add(v.getClass());
            for (int i = 0; i < n; i++) {
                out.add(key(Array.get(v, i)));
            }
            return out;
        }
        return new Identity(v); // tables, indexes, types: their own identity
    }

    /** Wraps an object compared by identity. */
    private record Identity(Object value) {
        @Override
        public boolean equals(Object o) {
            return o instanceof Identity i && i.value == value;
        }

        @Override
        public int hashCode() {
            return System.identityHashCode(value);
        }
    }
}
