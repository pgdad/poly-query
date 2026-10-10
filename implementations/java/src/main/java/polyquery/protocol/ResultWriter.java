package polyquery.protocol;

import java.util.List;
import polyquery.json.JsonWriter;
import polyquery.storage.ColumnSchema;
import polyquery.types.DataType;
import polyquery.types.DateTimes;
import polyquery.types.Decimals;
import polyquery.types.Values;

/** Canonical JSON serialization of result values (types.md §9). */
public final class ResultWriter {
    private ResultWriter() {
    }

    public static void writeColumns(StringBuilder sb, List<ColumnSchema> columns) {
        sb.append('[');
        for (int i = 0; i < columns.size(); i++) {
            if (i > 0) {
                sb.append(',');
            }
            sb.append("{\"name\":");
            JsonWriter.writeString(sb, columns.get(i).name());
            sb.append(",\"type\":\"").append(columns.get(i).type()).append("\"}");
        }
        sb.append(']');
    }

    public static void writeRows(StringBuilder sb, List<ColumnSchema> columns, List<Object[]> rows) {
        int n = columns.size();
        DataType[] types = new DataType[n];
        for (int i = 0; i < n; i++) {
            types[i] = columns.get(i).type();
        }
        sb.append('[');
        for (int r = 0; r < rows.size(); r++) {
            if (r > 0) {
                sb.append(',');
            }
            Object[] row = rows.get(r);
            sb.append('[');
            for (int c = 0; c < n; c++) {
                if (c > 0) {
                    sb.append(',');
                }
                writeValue(sb, row[c], types[c]);
            }
            sb.append(']');
        }
        sb.append(']');
    }

    public static void writeValue(StringBuilder sb, Object v, DataType type) {
        if (v == null) {
            sb.append("null");
            return;
        }
        switch (type.kind()) {
            case BOOLEAN -> sb.append(((Boolean) v) ? "true" : "false");
            case INT64 -> sb.append((long) (Long) v);
            case FLOAT64 -> sb.append(Values.formatDouble((Double) v));
            case DECIMAL -> sb.append('"').append(Decimals.toString((Long) v, type.scale())).append('"');
            case STRING -> JsonWriter.writeString(sb, (String) v);
            case DATE -> sb.append('"').append(DateTimes.formatDate((Integer) v)).append('"');
            case TIMESTAMP -> sb.append('"').append(DateTimes.formatTimestamp((Long) v)).append('"');
            case NULL -> sb.append("null");
        }
    }
}
