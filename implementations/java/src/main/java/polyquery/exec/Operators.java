package polyquery.exec;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;

/** Basic physical operators. */
public final class Operators {
    private Operators() {
    }

    /** One empty row (SELECT without FROM). */
    public static final class SingleRow implements Operator {
        private boolean done;

        @Override
        public void open() {
            done = false;
        }

        @Override
        public Object[] next() {
            if (done) {
                return null;
            }
            done = true;
            return new Object[0];
        }
    }

    public static final class Filter implements Operator {
        private final Operator input;
        private final Evaluator predicate;
        private final ExecContext ctx;

        public Filter(Operator input, Evaluator predicate, ExecContext ctx) {
            this.input = input;
            this.predicate = predicate;
            this.ctx = ctx;
        }

        @Override
        public void open() {
            input.open();
        }

        @Override
        public Object[] next() {
            Object[] row;
            while ((row = input.next()) != null) {
                if (Boolean.TRUE.equals(predicate.eval(row))) {
                    return row;
                }
                ctx.checkpoint();
            }
            return null;
        }

        @Override
        public void close() {
            input.close();
        }
    }

    public static final class Project implements Operator {
        private final Operator input;
        private final Evaluator[] exprs;

        public Project(Operator input, Evaluator[] exprs) {
            this.input = input;
            this.exprs = exprs;
        }

        @Override
        public void open() {
            input.open();
        }

        @Override
        public Object[] next() {
            Object[] row = input.next();
            if (row == null) {
                return null;
            }
            Object[] out = new Object[exprs.length];
            for (int i = 0; i < exprs.length; i++) {
                out[i] = exprs[i].eval(row);
            }
            return out;
        }

        @Override
        public void close() {
            input.close();
        }
    }

    /** Blocking sort; materializes its input under the memory budget. */
    public static final class Sort implements Operator {
        private final Operator input;
        private final Comparator<Object[]> comparator;
        private final ExecContext ctx;
        private List<Object[]> rows;
        private long reserved;
        private int pos;

        public Sort(Operator input, Comparator<Object[]> comparator, ExecContext ctx) {
            this.input = input;
            this.comparator = comparator;
            this.ctx = ctx;
        }

        @Override
        public void open() {
            input.open();
            rows = new ArrayList<>();
            Object[] row;
            while ((row = input.next()) != null) {
                long size = ExecContext.estimateRow(row);
                ctx.reserve(size);
                reserved += size;
                rows.add(row);
            }
            ctx.checkNow();
            rows.sort((a, b) -> {
                ctx.checkpoint(); // keeps long sorts cancellable
                return comparator.compare(a, b);
            });
            pos = 0;
        }

        @Override
        public Object[] next() {
            if (pos >= rows.size()) {
                return null;
            }
            return rows.get(pos++);
        }

        @Override
        public void close() {
            input.close();
            rows = null;
            ctx.release(reserved);
            reserved = 0;
        }
    }

    /** Skips {@code offset} rows, then returns at most {@code limit} rows (limit < 0 = unlimited). */
    public static final class Limit implements Operator {
        private final Operator input;
        private final long offset;
        private final long limit;
        private long produced;

        public Limit(Operator input, long offset, long limit) {
            this.input = input;
            this.offset = offset;
            this.limit = limit;
        }

        @Override
        public void open() {
            produced = 0;
            if (limit != 0) {
                input.open();
                for (long i = 0; i < offset; i++) {
                    if (input.next() == null) {
                        break;
                    }
                }
            }
        }

        @Override
        public Object[] next() {
            if (limit >= 0 && produced >= limit) {
                return null;
            }
            Object[] row = input.next();
            if (row != null) {
                produced++;
            }
            return row;
        }

        @Override
        public void close() {
            input.close();
        }
    }
}
