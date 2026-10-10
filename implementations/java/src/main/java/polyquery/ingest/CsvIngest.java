package polyquery.ingest;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import polyquery.storage.ColumnSchema;
import polyquery.storage.ColumnVector;
import polyquery.storage.Table;
import polyquery.types.DataType;
import polyquery.types.TextParsers;
import polyquery.types.TypeKind;

/** CSV ingestion (ingestion.md §1). */
public final class CsvIngest {
    private final String src;
    private final char delim;
    private int pos;
    private long recordNo;

    private CsvIngest(String src, char delim) {
        this.src = src;
        this.delim = delim;
        this.pos = !src.isEmpty() && src.charAt(0) == '﻿' ? 1 : 0;
    }

    /**
     * Parses CSV text into a table. Raw fields are kept as strings per column: an unquoted
     * empty field is stored as {@code null}, a quoted empty field as {@code ""}.
     */
    public static Table load(String name, String text, IngestOptions opts) {
        CsvIngest p = new CsvIngest(text, opts.delimiter());
        List<ColumnSchema> schema = opts.schema();
        List<String> names;
        if (opts.header()) {
            String[] header = p.nextRecord(-1);
            if (header == null) {
                if (schema != null) {
                    return build(name, schema, new ColumnData[0], 0, true);
                }
                return new Table(name, List.of(), new ColumnVector[0], 0);
            }
            names = new ArrayList<>(header.length);
            for (String h : header) {
                names.add(h == null ? "" : h);
            }
            if (schema != null) {
                if (schema.size() != names.size()) {
                    throw IngestErrors.ingest("header has " + names.size() + " columns but schema has " + schema.size(), 1);
                }
                for (int i = 0; i < names.size(); i++) {
                    if (!names.get(i).equalsIgnoreCase(schema.get(i).name())) {
                        throw IngestErrors.ingest("header column '" + names.get(i) + "' does not match schema column '"
                                + schema.get(i).name() + "'", 1);
                    }
                }
            }
        } else {
            names = new ArrayList<>();
            for (ColumnSchema c : schema) {
                names.add(c.name());
            }
        }
        checkNames(names);
        int ncols = names.size();
        ColumnData[] cols = new ColumnData[ncols];
        for (int i = 0; i < ncols; i++) {
            cols[i] = new ColumnData();
        }
        int rows = 0;
        String[] rec;
        while ((rec = p.nextRecord(ncols)) != null) {
            if (rec.length != ncols) {
                throw IngestErrors.ingest("record has " + rec.length + " fields, expected " + ncols, p.recordNo);
            }
            if (rows >= opts.maxRows()) {
                throw IngestErrors.tooManyRows(opts.maxRows());
            }
            for (int i = 0; i < ncols; i++) {
                cols[i].add(rec[i]);
            }
            rows++;
        }
        List<ColumnSchema> finalSchema = new ArrayList<>(ncols);
        for (int i = 0; i < ncols; i++) {
            DataType t = schema != null ? schema.get(i).type() : cols[i].inferred();
            finalSchema.add(new ColumnSchema(schema != null ? schema.get(i).name() : names.get(i), t));
        }
        return build(name, finalSchema, cols, rows, opts.header());
    }

    static void checkNames(List<String> names) {
        Set<String> seen = new HashSet<>();
        for (String n : names) {
            if (n.isEmpty()) {
                throw IngestErrors.ingest("empty column name", 0);
            }
            if (!seen.add(Table.key(n))) {
                throw IngestErrors.ingest("duplicate column name '" + n + "'", 0);
            }
        }
    }

    private static Table build(String name, List<ColumnSchema> schema, ColumnData[] cols, int rows, boolean header) {
        ColumnVector[] vectors = new ColumnVector[schema.size()];
        long firstRecord = header ? 2 : 1;
        for (int c = 0; c < schema.size(); c++) {
            ColumnSchema cs = schema.get(c);
            DataType type = cs.type();
            ColumnVector.Builder b = ColumnVector.builder(type, rows);
            String[] raw = cols.length == 0 ? new String[0] : cols[c].values;
            for (int r = 0; r < rows; r++) {
                String v = raw[r];
                if (type.kind() == TypeKind.STRING) {
                    b.append(v);
                    continue;
                }
                if (v == null) {
                    b.appendNull();
                    continue;
                }
                String t = TextParsers.trimSpaceTab(v);
                if (t.isEmpty()) {
                    b.appendNull();
                    continue;
                }
                Object val = ValueParsing.parse(t, type);
                if (val == null) {
                    throw IngestErrors.conversion(v, cs.name(), type, firstRecord + r);
                }
                b.append(val);
            }
            vectors[c] = b.build();
            if (cols.length > 0) {
                cols[c].values = null;
            }
        }
        return new Table(name, schema, vectors, rows);
    }

    /** Raw field storage plus incremental type inference for one column. */
    private static final class ColumnData {
        String[] values = new String[64];
        int size;
        final TypeInference inference = new TypeInference();

        void add(String v) {
            if (size == values.length) {
                values = Arrays.copyOf(values, size * 2);
            }
            values[size++] = v;
            if (v != null && !v.isEmpty() && inference.stillNumericOrTemporal()) {
                String t = TextParsers.trimSpaceTab(v);
                if (!t.isEmpty()) {
                    inference.observe(t);
                }
            }
        }

        DataType inferred() {
            return inference.result();
        }
    }

    // ---------------------------------------------------------------- record parser

    /** Returns the next record's fields, or {@code null} at end of input. */
    private String[] nextRecord(int expected) {
        int n = src.length();
        while (pos < n) {
            char c = src.charAt(pos);
            if (c == '\n') {
                pos++;
                continue;
            }
            if (c == '\r' && pos + 1 < n && src.charAt(pos + 1) == '\n') {
                pos += 2;
                continue;
            }
            break;
        }
        if (pos >= n) {
            return null;
        }
        recordNo++;
        List<String> fields = new ArrayList<>(Math.max(expected, 4));
        StringBuilder sb = new StringBuilder();
        while (true) {
            String field;
            if (pos < n && src.charAt(pos) == '"') {
                pos++;
                sb.setLength(0);
                while (true) {
                    if (pos >= n) {
                        throw IngestErrors.ingest("unterminated quoted field", recordNo);
                    }
                    char c = src.charAt(pos++);
                    if (c == '"') {
                        if (pos < n && src.charAt(pos) == '"') {
                            sb.append('"');
                            pos++;
                        } else {
                            break;
                        }
                    } else {
                        sb.append(c);
                    }
                    if (sb.length() > IngestErrors.MAX_FIELD_CHARS) {
                        throw IngestErrors.ingest("field longer than 16 MiB", recordNo);
                    }
                }
                field = sb.toString();
                if (pos < n && src.charAt(pos) != delim && !atRecordEnd()) {
                    throw IngestErrors.ingest("unexpected character after closing quote", recordNo);
                }
            } else {
                int start = pos;
                while (pos < n) {
                    char c = src.charAt(pos);
                    if (c == delim || c == '\n' || (c == '\r' && atRecordEnd())) {
                        break;
                    }
                    if (c == '"') {
                        throw IngestErrors.ingest("quote character inside unquoted field", recordNo);
                    }
                    pos++;
                }
                if (pos - start > IngestErrors.MAX_FIELD_CHARS) {
                    throw IngestErrors.ingest("field longer than 16 MiB", recordNo);
                }
                field = pos == start ? null : src.substring(start, pos);
            }
            fields.add(field);
            if (pos < n && src.charAt(pos) == delim) {
                pos++;
                continue;
            }
            // end of record
            if (pos < n) {
                if (src.charAt(pos) == '\r') {
                    pos++;
                }
                if (pos < n && src.charAt(pos) == '\n') {
                    pos++;
                }
            }
            return fields.toArray(new String[0]);
        }
    }

    private boolean atRecordEnd() {
        int n = src.length();
        char c = src.charAt(pos);
        if (c == '\n') {
            return true;
        }
        return c == '\r' && (pos + 1 >= n || src.charAt(pos + 1) == '\n');
    }
}
