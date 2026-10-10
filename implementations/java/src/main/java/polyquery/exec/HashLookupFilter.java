package polyquery.exec;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import polyquery.types.DataType;

/**
 * Filter of a correlated subquery that is executed once per outer row: the input is read and
 * hashed on the inner key expressions only the first time; every execution then probes the
 * table with the current outer-reference values (see PhysicalPlan.HashLookupFilter).
 */
public final class HashLookupFilter implements Operator {
    private static final Object[] NO_ROW = new Object[0];

    private final Operator input;
    private final Evaluator[] innerKeys;
    private final Evaluator[] outerKeys;
    private final DataType[] innerTypes;
    private final DataType[] outerTypes;
    private final Evaluator staticPredicate;
    private final Evaluator dynamicPredicate;
    private final ExecContext ctx;
    private Map<Object, List<Object[]>> table;
    private List<Object[]> matches;
    private int next;

    public HashLookupFilter(Operator input, Evaluator[] innerKeys, Evaluator[] outerKeys, DataType[] innerTypes,
                            DataType[] outerTypes, Evaluator staticPredicate, Evaluator dynamicPredicate,
                            ExecContext ctx) {
        this.input = input;
        this.innerKeys = innerKeys;
        this.outerKeys = outerKeys;
        this.innerTypes = innerTypes;
        this.outerTypes = outerTypes;
        this.staticPredicate = staticPredicate;
        this.dynamicPredicate = dynamicPredicate;
        this.ctx = ctx;
    }

    private static Object key(Object[] row, Evaluator[] keys, DataType[] types) {
        if (keys.length == 1) {
            return HashKeys.normalize(keys[0].eval(row), types[0]);
        }
        Object[] k = new Object[keys.length];
        for (int i = 0; i < k.length; i++) {
            Object v = keys[i].eval(row);
            if (v == null) {
                return null;
            }
            k[i] = HashKeys.normalize(v, types[i]);
        }
        return new HashKeys.RowKey(k);
    }

    private void build() {
        table = new HashMap<>();
        input.open();
        try {
            Object[] row;
            while ((row = input.next()) != null) {
                ctx.checkpoint();
                if (staticPredicate != null && !Boolean.TRUE.equals(staticPredicate.eval(row))) {
                    continue;
                }
                Object k = key(row, innerKeys, innerTypes);
                if (k != null) {
                    ctx.reserve(ExecContext.estimateRow(row) + 32);
                    table.computeIfAbsent(k, x -> new ArrayList<>(2)).add(row);
                }
            }
        } finally {
            input.close();
        }
    }

    @Override
    public void open() {
        if (table == null) {
            build();
        }
        Object k = key(NO_ROW, outerKeys, outerTypes);
        matches = k == null ? List.of() : table.getOrDefault(k, List.of());
        next = 0;
    }

    @Override
    public Object[] next() {
        while (next < matches.size()) {
            Object[] row = matches.get(next++);
            if (dynamicPredicate == null || Boolean.TRUE.equals(dynamicPredicate.eval(row))) {
                return row;
            }
        }
        return null;
    }
}
