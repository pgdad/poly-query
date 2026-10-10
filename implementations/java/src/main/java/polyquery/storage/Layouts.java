package polyquery.storage;

import java.util.Arrays;
import java.util.BitSet;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import polyquery.types.TypeKind;

/** Conversions between physical table representations. */
public final class Layouts {
    /** Dictionary encoding policy for STRING columns of columnar tables. */
    public enum Dictionary {
        /** Encode when at most half of the values are distinct. */
        AUTO,
        /** Always encode. */
        ALWAYS,
        /** Never encode. */
        NEVER
    }

    private Layouts() {
    }

    /** Re-represents {@code data} in the requested layout (returns it unchanged when nothing to do). */
    public static TableData convert(TableData data, List<ColumnSchema> schema, Layout layout, Dictionary dictionary) {
        if (layout == Layout.ROW) {
            return data instanceof RowData ? data : toRows(data, schema);
        }
        if (data instanceof ColumnarData c && dictionary == Dictionary.NEVER) {
            return c;
        }
        ColumnVector[] cols = new ColumnVector[schema.size()];
        for (int c = 0; c < cols.length; c++) {
            ColumnVector v = data.groupCount() == 1 && !(data instanceof RowData)
                    ? data.chunk(0, c) : gather(data, schema, c);
            if (schema.get(c).type().kind() == TypeKind.STRING) {
                v = encodeStrings(v, dictionary);
            }
            cols[c] = v;
        }
        return new ColumnarData(cols, data.rowCount());
    }

    private static RowData toRows(TableData data, List<ColumnSchema> schema) {
        int width = schema.size();
        int n = data.rowCount();
        Object[][] rows = new Object[n][width];
        for (int g = 0; g < data.groupCount(); g++) {
            int start = data.groupStart(g);
            int size = data.groupSize(g);
            for (int c = 0; c < width; c++) {
                ColumnVector v = data.chunk(g, c);
                for (int i = 0; i < size; i++) {
                    rows[start + i][c] = v.get(i);
                }
            }
        }
        return new RowData(rows, schema);
    }

    /** Copies one column of all row groups into a single vector. */
    private static ColumnVector gather(TableData data, List<ColumnSchema> schema, int column) {
        ColumnVector.Builder b = ColumnVector.builder(schema.get(column).type(), data.rowCount());
        for (int g = 0; g < data.groupCount(); g++) {
            ColumnVector v = data.chunk(g, column);
            for (int i = 0; i < data.groupSize(g); i++) {
                b.append(v.get(i));
            }
        }
        return b.build();
    }

    /** Applies the dictionary policy to a STRING vector. */
    public static ColumnVector encodeStrings(ColumnVector v, Dictionary policy) {
        boolean isDict = v instanceof ColumnVector.DictStringVector;
        if (policy == Dictionary.NEVER) {
            return isDict ? plainStrings(v) : v;
        }
        if (isDict) {
            return v;
        }
        int n = v.size();
        if (policy == Dictionary.AUTO && n > 4 * SAMPLE && mostlyDistinct(v)) {
            return v;
        }
        Map<String, Integer> codes = new HashMap<>();
        String[] dict = new String[Math.max(16, Math.min(n, 1024))];
        int[] rowCodes = new int[n];
        BitSet nulls = new BitSet();
        int limit = policy == Dictionary.ALWAYS ? Integer.MAX_VALUE : n / 2;
        for (int i = 0; i < n; i++) {
            String s = (String) v.get(i);
            if (s == null) {
                nulls.set(i);
                continue;
            }
            Integer code = codes.get(s);
            if (code == null) {
                code = codes.size();
                if (code >= limit) {
                    return v;
                }
                codes.put(s, code);
                if (code == dict.length) {
                    dict = Arrays.copyOf(dict, dict.length * 2);
                }
                dict[code] = s;
            }
            rowCodes[i] = code;
        }
        return ColumnVector.ofDictionary(Arrays.copyOf(dict, codes.size()), rowCodes, nulls);
    }

    private static final int SAMPLE = 10_000;

    /** True if more than half of a prefix sample of the column is distinct (encoding will not pay off). */
    private static boolean mostlyDistinct(ColumnVector v) {
        Set<Object> seen = new HashSet<>();
        int nonNull = 0;
        for (int i = 0; i < SAMPLE; i++) {
            Object s = v.get(i);
            if (s != null) {
                nonNull++;
                seen.add(s);
            }
        }
        return seen.size() > nonNull / 2;
    }

    private static ColumnVector plainStrings(ColumnVector v) {
        String[] out = new String[v.size()];
        for (int i = 0; i < out.length; i++) {
            out[i] = (String) v.get(i);
        }
        return ColumnVector.ofStrings(out);
    }
}
