package pqledger.output;

import java.util.ArrayList;
import java.util.List;
import polyquery.api.ColumnType;

/** Prints a {@link Tabular} in one of the output formats (spec §7). */
public final class Renderer {
    private Renderer() {
    }

    public static String render(Tabular t, OutputFormat format) {
        return switch (format) {
            case TABLE -> table(t);
            case CSV -> csv(t);
            case JSON -> json(t);
        };
    }

    // ---------------------------------------------------------------- table

    static String table(Tabular t) {
        int n = t.columns().size();
        List<String[]> cells = new ArrayList<>(t.rows().size());
        int[] width = new int[n];
        boolean[] right = new boolean[n];
        for (int c = 0; c < n; c++) {
            width[c] = codePoints(t.columns().get(c).name());
            right[c] = t.columns().get(c).type().isNumeric();
        }
        for (List<Object> row : t.rows()) {
            String[] texts = new String[n];
            for (int c = 0; c < n; c++) {
                texts[c] = ValueText.of(row.get(c), t.columns().get(c).type());
                width[c] = Math.max(width[c], codePoints(texts[c]));
            }
            cells.add(texts);
        }
        StringBuilder sb = new StringBuilder();
        String[] names = new String[n];
        String[] rules = new String[n];
        for (int c = 0; c < n; c++) {
            names[c] = t.columns().get(c).name();
            rules[c] = "-".repeat(width[c]);
        }
        line(sb, names, width, right);
        line(sb, rules, width, right);
        for (String[] texts : cells) {
            line(sb, texts, width, right);
        }
        int rows = t.rows().size();
        sb.append(rows == 1 ? "(1 row)" : "(" + rows + " rows)").append('\n');
        return sb.toString();
    }

    private static void line(StringBuilder sb, String[] texts, int[] width, boolean[] right) {
        int start = sb.length();
        for (int c = 0; c < texts.length; c++) {
            if (c > 0) {
                sb.append("  ");
            }
            int pad = width[c] - codePoints(texts[c]);
            if (right[c]) {
                sb.repeat(' ', pad).append(texts[c]);
            } else {
                sb.append(texts[c]).repeat(' ', pad);
            }
        }
        int end = sb.length();
        while (end > start && sb.charAt(end - 1) == ' ') {
            end--;
        }
        sb.setLength(end);
        sb.append('\n');
    }

    private static int codePoints(String s) {
        return s.codePointCount(0, s.length());
    }

    // ---------------------------------------------------------------- csv

    static String csv(Tabular t) {
        StringBuilder sb = new StringBuilder();
        int n = t.columns().size();
        for (int c = 0; c < n; c++) {
            if (c > 0) {
                sb.append(',');
            }
            csvField(sb, t.columns().get(c).name());
        }
        sb.append('\n');
        for (List<Object> row : t.rows()) {
            for (int c = 0; c < n; c++) {
                if (c > 0) {
                    sb.append(',');
                }
                Object v = row.get(c);
                if (v != null) {
                    csvField(sb, ValueText.of(v, t.columns().get(c).type()));
                }
            }
            sb.append('\n');
        }
        return sb.toString();
    }

    private static void csvField(StringBuilder sb, String s) {
        boolean quote = s.isEmpty() || s.startsWith(" ") || s.endsWith(" ");
        for (int i = 0; i < s.length() && !quote; i++) {
            char c = s.charAt(i);
            quote = c == ',' || c == '"' || c == '\r' || c == '\n';
        }
        if (!quote) {
            sb.append(s);
            return;
        }
        sb.append('"');
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '"') {
                sb.append('"');
            }
            sb.append(c);
        }
        sb.append('"');
    }

    // ---------------------------------------------------------------- json

    static String json(Tabular t) {
        StringBuilder sb = new StringBuilder();
        int n = t.columns().size();
        for (List<Object> row : t.rows()) {
            sb.append('{');
            for (int c = 0; c < n; c++) {
                if (c > 0) {
                    sb.append(',');
                }
                jsonString(sb, t.columns().get(c).name());
                sb.append(':');
                jsonValue(sb, row.get(c), t.columns().get(c).type());
            }
            sb.append("}\n");
        }
        return sb.toString();
    }

    private static void jsonValue(StringBuilder sb, Object v, ColumnType type) {
        if (v == null) {
            sb.append("null");
            return;
        }
        switch (type.kind()) {
            case INT64, FLOAT64, BOOLEAN -> sb.append(ValueText.of(v, type));
            case STRING, DECIMAL, DATE, TIMESTAMP -> jsonString(sb, ValueText.of(v, type));
        }
    }

    private static void jsonString(StringBuilder sb, String s) {
        sb.append('"');
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"' -> sb.append("\\\"");
                case '\\' -> sb.append("\\\\");
                case '\b' -> sb.append("\\b");
                case '\t' -> sb.append("\\t");
                case '\n' -> sb.append("\\n");
                case '\f' -> sb.append("\\f");
                case '\r' -> sb.append("\\r");
                default -> {
                    if (c < 0x20) {
                        sb.append(String.format("\\u%04x", (int) c));
                    } else {
                        sb.append(c);
                    }
                }
            }
        }
        sb.append('"');
    }
}
