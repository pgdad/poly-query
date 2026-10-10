package polyquery.exec;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import polyquery.plan.AggregateCall;

/**
 * Hash aggregation. Output rows are group keys followed by aggregate results. Without group
 * keys exactly one row is produced, even for empty input.
 */
public final class AggregateOperator implements Operator {
    private static final Object PRESENT = Boolean.TRUE;

    private final Operator input;
    private final Evaluator[] keys;
    private final List<AggregateCall> calls;
    private final Evaluator[] args;
    private final ExecContext ctx;
    private Iterator<Map.Entry<HashKeys.RowKey, Accumulator[]>> output;

    public AggregateOperator(Operator input, Evaluator[] keys, List<AggregateCall> calls, Evaluator[] args,
                             ExecContext ctx) {
        this.input = input;
        this.keys = keys;
        this.calls = calls;
        this.args = args;
        this.ctx = ctx;
    }

    private Accumulator[] newGroup() {
        Accumulator[] accs = new Accumulator[calls.size()];
        for (int i = 0; i < accs.length; i++) {
            accs[i] = Accumulator.create(calls.get(i));
        }
        return accs;
    }

    @Override
    public void open() {
        input.open();
        Map<HashKeys.RowKey, Accumulator[]> groups = new LinkedHashMap<>();
        if (keys.length == 0) {
            groups.put(new HashKeys.RowKey(new Object[0]), newGroup());
        }
        Object[] row;
        while ((row = input.next()) != null) {
            ctx.checkpoint();
            Accumulator[] accs;
            if (keys.length == 0) {
                accs = groups.values().iterator().next();
            } else {
                Object[] k = new Object[keys.length];
                for (int i = 0; i < k.length; i++) {
                    Object v = keys[i].eval(row);
                    k[i] = HashKeys.normalizeZero(v);
                }
                HashKeys.RowKey gk = new HashKeys.RowKey(k);
                accs = groups.get(gk);
                if (accs == null) {
                    accs = newGroup();
                    groups.put(gk, accs);
                    ctx.reserve(64 + 48L * accs.length + ExecContext.estimateRow(k));
                }
            }
            for (int i = 0; i < accs.length; i++) {
                accs[i].add(args[i] == null ? PRESENT : args[i].eval(row));
            }
        }
        output = new ArrayList<>(groups.entrySet()).iterator();
    }

    @Override
    public Object[] next() {
        if (!output.hasNext()) {
            return null;
        }
        Map.Entry<HashKeys.RowKey, Accumulator[]> e = output.next();
        Object[] k = e.getKey().values();
        Accumulator[] accs = e.getValue();
        Object[] out = Arrays.copyOf(k, k.length + accs.length);
        for (int i = 0; i < accs.length; i++) {
            out[k.length + i] = accs[i].result();
        }
        return out;
    }

    @Override
    public void close() {
        input.close();
    }
}
