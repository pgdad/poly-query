package polyquery.json;

import java.util.List;
import java.util.Map;

/** Serializes JSON values (as produced by {@link JsonParser}, plus Java numbers) on one line. */
public final class JsonWriter {
    private JsonWriter() {
    }

    public static String write(Object v) {
        StringBuilder sb = new StringBuilder();
        write(sb, v);
        return sb.toString();
    }

    public static void write(StringBuilder sb, Object v) {
        switch (v) {
            case null -> sb.append("null");
            case String str -> writeString(sb, str);
            case Boolean b -> sb.append(b ? "true" : "false");
            case Long l -> sb.append(l.longValue());
            case Integer i -> sb.append(i.intValue());
            case Double d -> sb.append(d == 0.0 ? "0.0" : Double.toString(d));
            case JsonNumber n -> sb.append(n.text());
            case RawJson r -> sb.append(r.json());
            case Map<?, ?> m -> {
                sb.append('{');
                boolean first = true;
                for (Map.Entry<?, ?> e : m.entrySet()) {
                    if (!first) {
                        sb.append(',');
                    }
                    first = false;
                    writeString(sb, String.valueOf(e.getKey()));
                    sb.append(':');
                    write(sb, e.getValue());
                }
                sb.append('}');
            }
            case List<?> list -> {
                sb.append('[');
                for (int i = 0; i < list.size(); i++) {
                    if (i > 0) {
                        sb.append(',');
                    }
                    write(sb, list.get(i));
                }
                sb.append(']');
            }
            default -> writeString(sb, v.toString());
        }
    }

    /** Writes a JSON string literal; escapes quotes, backslashes, controls and lone surrogates. */
    public static void writeString(StringBuilder sb, String s) {
        sb.append('"');
        int n = s.length();
        for (int i = 0; i < n; i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"' -> sb.append("\\\"");
                case '\\' -> sb.append("\\\\");
                case '\n' -> sb.append("\\n");
                case '\r' -> sb.append("\\r");
                case '\t' -> sb.append("\\t");
                case '\b' -> sb.append("\\b");
                case '\f' -> sb.append("\\f");
                default -> {
                    if (c < 0x20 || c == 0x2028 || c == 0x2029) {
                        unicodeEscape(sb, c);
                    } else if (Character.isHighSurrogate(c)) {
                        if (i + 1 < n && Character.isLowSurrogate(s.charAt(i + 1))) {
                            sb.append(c).append(s.charAt(++i));
                        } else {
                            unicodeEscape(sb, c);
                        }
                    } else if (Character.isLowSurrogate(c)) {
                        unicodeEscape(sb, c);
                    } else {
                        sb.append(c);
                    }
                }
            }
        }
        sb.append('"');
    }

    private static void unicodeEscape(StringBuilder sb, char c) {
        sb.append("\\u");
        String h = Integer.toHexString(c);
        sb.repeat('0', 4 - h.length());
        sb.append(h);
    }

    /** Pre-serialized JSON fragment. */
    public record RawJson(String json) {
    }
}
