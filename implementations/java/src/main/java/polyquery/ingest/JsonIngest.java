package polyquery.ingest;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import polyquery.json.JsonException;
import polyquery.json.JsonNumber;
import polyquery.json.JsonParser;
import polyquery.storage.ColumnSchema;
import polyquery.storage.ColumnVector;
import polyquery.storage.Table;
import polyquery.types.DataType;
import polyquery.types.DateTimes;
import polyquery.types.TextParsers;
import polyquery.types.TypeKind;

/** JSON array and JSON Lines ingestion (ingestion.md §2). */
public final class JsonIngest {
    private final IngestOptions opts;
    private final List<String> names = new ArrayList<>();
    private final Map<String, Integer> index = new HashMap<>();
    private final List<Object[]> rows = new ArrayList<>();

    private JsonIngest(IngestOptions opts) {
        this.opts = opts;
        if (opts.schema() != null) {
            List<String> schemaNames = new ArrayList<>();
            for (ColumnSchema c : opts.schema()) {
                schemaNames.add(c.name());
            }
            CsvIngest.checkNames(schemaNames);
            for (String n : schemaNames) {
                index.put(Table.key(n), names.size());
                names.add(n);
            }
        }
    }

    public static Table loadArray(String name, String text, IngestOptions opts) {
        JsonIngest ing = new JsonIngest(opts);
        try {
            JsonParser p = JsonParser.forArray(!text.isEmpty() && text.charAt(0) == '\uFEFF' ? text.substring(1) : text);
            long record = 0;
            while (true) {
                Object el = p.nextElement();
                if (el == JsonParser.END) {
                    break;
                }
                record++;
                ing.addRecord(el, record);
            }
        } catch (JsonException e) {
            throw IngestErrors.ingest("malformed JSON: " + e.getMessage(), 0);
        }
        return ing.build(name);
    }

    public static Table loadLines(String name, String text, IngestOptions opts) {
        JsonIngest ing = new JsonIngest(opts);
        int start = 0;
        long lineNo = 0;
        int n = text.length();
        if (n > 0 && text.charAt(0) == '﻿') {
            start = 1;
        }
        while (start <= n) {
            int end = text.indexOf('\n', start);
            if (end < 0) {
                end = n;
            }
            lineNo++;
            String line = text.substring(start, end).strip();
            start = end + 1;
            if (line.isEmpty()) {
                continue;
            }
            Object v;
            try {
                v = JsonParser.parse(line, true);
            } catch (JsonException e) {
                throw IngestErrors.ingest("malformed JSON on line " + lineNo + ": " + e.getMessage(), lineNo);
            }
            ing.addRecord(v, lineNo);
        }
        return ing.build(name);
    }

    private void addRecord(Object v, long record) {
        if (!(v instanceof Map<?, ?> obj)) {
            throw IngestErrors.ingest("JSON record is not an object", record);
        }
        if (rows.size() >= opts.maxRows()) {
            throw IngestErrors.tooManyRows(opts.maxRows());
        }
        Object[] row = new Object[Math.max(names.size(), obj.size())];
        boolean[] seen = new boolean[row.length];
        for (Map.Entry<?, ?> e : obj.entrySet()) {
            String key = (String) e.getKey();
            Object value = e.getValue();
            if (value instanceof Map || value instanceof List) {
                throw IngestErrors.ingest("nested value for key '" + key + "'", record);
            }
            Integer col = index.get(Table.key(key));
            if (col == null) {
                if (opts.schema() != null) {
                    throw IngestErrors.ingest("key '" + key + "' is not in the schema", record);
                }
                if (key.isEmpty()) {
                    throw IngestErrors.ingest("empty column name", record);
                }
                col = names.size();
                index.put(Table.key(key), col);
                names.add(key);
            } else if (opts.schema() == null && !names.get(col).equals(key)) {
                throw IngestErrors.ingest("duplicate column name '" + key + "'", record);
            }
            if (col >= row.length) {
                row = java.util.Arrays.copyOf(row, names.size());
                seen = java.util.Arrays.copyOf(seen, names.size());
            }
            if (seen[col]) {
                throw IngestErrors.ingest("duplicate key '" + key + "'", record);
            }
            seen[col] = true;
            row[col] = value;
        }
        rows.add(row);
    }

    private Table build(String name) {
        int ncols = names.size();
        List<ColumnSchema> schema = new ArrayList<>(ncols);
        ColumnVector[] vectors = new ColumnVector[ncols];
        for (int c = 0; c < ncols; c++) {
            DataType type = opts.schema() != null ? opts.schema().get(c).type() : infer(c);
            String colName = names.get(c);
            schema.add(new ColumnSchema(colName, type));
            ColumnVector.Builder b = ColumnVector.builder(type, rows.size());
            for (int r = 0; r < rows.size(); r++) {
                Object[] row = rows.get(r);
                Object v = c < row.length ? row[c] : null;
                b.append(v == null ? null : convert(v, type, colName, r + 1));
            }
            vectors[c] = b.build();
        }
        return new Table(name, schema, vectors, rows.size());
    }

    private DataType infer(int c) {
        boolean bools = false;
        boolean numbers = false;
        boolean strings = false;
        boolean allInt = true;
        boolean allDate = true;
        boolean allTemporal = true;
        for (Object[] row : rows) {
            Object v = c < row.length ? row[c] : null;
            switch (v) {
                case null -> {
                }
                case Boolean b -> bools = true;
                case JsonNumber n -> {
                    numbers = true;
                    if (allInt) {
                        if (!n.isIntegerLiteral()) {
                            allInt = false;
                        } else {
                            try {
                                TextParsers.parseInt64(n.text());
                            } catch (ArithmeticException e) {
                                allInt = false;
                            }
                        }
                    }
                }
                case String s -> {
                    strings = true;
                    if (allTemporal) {
                        if (DateTimes.parseDate(s) == null) {
                            allDate = false;
                            if (DateTimes.parseTimestamp(s, false) == null) {
                                allTemporal = false;
                            }
                        }
                    }
                }
                default -> throw IngestErrors.ingest("unsupported JSON value", 0);
            }
        }
        int kinds = (bools ? 1 : 0) + (numbers ? 1 : 0) + (strings ? 1 : 0);
        if (kinds > 1) {
            throw IngestErrors.ingest("column '" + names.get(c) + "' mixes JSON value types", 0);
        }
        if (bools) {
            return DataType.BOOLEAN;
        }
        if (numbers) {
            return allInt ? DataType.INT64 : DataType.FLOAT64;
        }
        if (strings && allTemporal) {
            return allDate ? DataType.DATE : DataType.TIMESTAMP;
        }
        return DataType.STRING;
    }

    private Object convert(Object v, DataType type, String column, long record) {
        TypeKind k = type.kind();
        Object result = null;
        switch (v) {
            case Boolean b -> {
                if (k == TypeKind.BOOLEAN) {
                    result = b;
                }
            }
            case JsonNumber n -> {
                if (k == TypeKind.INT64 || k == TypeKind.FLOAT64 || k == TypeKind.DECIMAL) {
                    result = ValueParsing.parse(n.text(), type);
                    if (result == null && opts.schema() == null) {
                        throw IngestErrors.ingest("number '" + n.text() + "' is out of range", record);
                    }
                }
            }
            case String s -> {
                if (k == TypeKind.STRING) {
                    result = s;
                } else if (k != TypeKind.BOOLEAN) {
                    String t = k == TypeKind.DATE || k == TypeKind.TIMESTAMP ? s : TextParsers.trimSpaceTab(s);
                    result = ValueParsing.parse(t, type);
                }
            }
            default -> {
            }
        }
        if (result == null) {
            throw IngestErrors.conversion(String.valueOf(v), column, type, record);
        }
        return result;
    }
}
