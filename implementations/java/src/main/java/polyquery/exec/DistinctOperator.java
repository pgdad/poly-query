package polyquery.exec;

import java.util.HashSet;
import java.util.Set;

/** Removes duplicate rows (NULLs equal each other; types.md §7). */
public final class DistinctOperator implements Operator {
    private final Operator input;
    private final ExecContext ctx;
    private Set<HashKeys.RowKey> seen;
    private long reserved;

    public DistinctOperator(Operator input, ExecContext ctx) {
        this.input = input;
        this.ctx = ctx;
    }

    @Override
    public void open() {
        seen = new HashSet<>();
        input.open();
    }

    @Override
    public Object[] next() {
        Object[] row;
        while ((row = input.next()) != null) {
            ctx.checkpoint();
            Object[] key = new Object[row.length];
            for (int i = 0; i < key.length; i++) {
                key[i] = HashKeys.normalizeZero(row[i]);
            }
            if (seen.add(new HashKeys.RowKey(key))) {
                long size = ExecContext.estimateRow(row) + 32;
                ctx.reserve(size);
                reserved += size;
                return row;
            }
        }
        return null;
    }

    @Override
    public void close() {
        input.close();
        seen = null;
        ctx.release(reserved);
        reserved = 0;
    }
}
