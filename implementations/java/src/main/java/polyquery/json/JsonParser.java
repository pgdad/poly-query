package polyquery.json;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Strict RFC 8259 JSON parser. Produces {@code Map<String,Object>} (insertion ordered),
 * {@code List<Object>}, {@link String}, {@link Boolean}, {@link JsonNumber} and {@code null}.
 */
public final class JsonParser {
    private static final int MAX_DEPTH = 512;

    private final String s;
    private final boolean rejectDuplicateKeys;
    private int pos;
    private int depth;

    private JsonParser(String s, boolean rejectDuplicateKeys) {
        this.s = s;
        this.rejectDuplicateKeys = rejectDuplicateKeys;
    }

    /** Parses a complete document; duplicate object keys: last one wins. */
    public static Object parse(String text) throws JsonException {
        return parse(text, false);
    }

    public static Object parse(String text, boolean rejectDuplicateKeys) throws JsonException {
        JsonParser p = new JsonParser(text, rejectDuplicateKeys);
        p.skipWs();
        Object v = p.value();
        p.skipWs();
        if (p.pos != text.length()) {
            throw p.error("unexpected trailing characters");
        }
        return v;
    }

    /** Streaming access for large arrays of objects: parses one element at a time. */
    public static JsonParser forArray(String text) throws JsonException {
        JsonParser p = new JsonParser(text, true);
        p.skipWs();
        if (p.pos >= text.length() || text.charAt(p.pos) != '[') {
            throw p.error("expected a JSON array");
        }
        p.pos++;
        return p;
    }

    private boolean firstElement = true;

    /**
     * Returns the next array element, or a sentinel {@link #END} at the end of the array
     * (after verifying there is no trailing content).
     */
    public Object nextElement() throws JsonException {
        skipWs();
        if (pos < s.length() && s.charAt(pos) == ']' && firstElement) {
            pos++;
            finish();
            return END;
        }
        if (!firstElement) {
            if (pos < s.length() && s.charAt(pos) == ']') {
                pos++;
                finish();
                return END;
            }
            expect(',');
            skipWs();
        }
        firstElement = false;
        return value();
    }

    public static final Object END = new Object();

    private void finish() throws JsonException {
        skipWs();
        if (pos != s.length()) {
            throw error("unexpected trailing characters");
        }
    }

    private JsonException error(String msg) {
        int line = 1;
        int col = 1;
        for (int i = 0; i < Math.min(pos, s.length()); i++) {
            if (s.charAt(i) == '\n') {
                line++;
                col = 1;
            } else {
                col++;
            }
        }
        return new JsonException(msg + " at line " + line + ", column " + col);
    }

    private void skipWs() {
        while (pos < s.length()) {
            char c = s.charAt(pos);
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
                pos++;
            } else {
                break;
            }
        }
    }

    private void expect(char c) throws JsonException {
        if (pos >= s.length() || s.charAt(pos) != c) {
            throw error("expected '" + c + "'");
        }
        pos++;
    }

    private Object value() throws JsonException {
        if (pos >= s.length()) {
            throw error("unexpected end of input");
        }
        char c = s.charAt(pos);
        return switch (c) {
            case '{' -> object();
            case '[' -> array();
            case '"' -> string();
            case 't' -> literal("true", Boolean.TRUE);
            case 'f' -> literal("false", Boolean.FALSE);
            case 'n' -> literal("null", null);
            default -> {
                if (c == '-' || (c >= '0' && c <= '9')) {
                    yield number();
                }
                throw error("unexpected character '" + c + "'");
            }
        };
    }

    private Object literal(String word, Object v) throws JsonException {
        if (!s.startsWith(word, pos)) {
            throw error("invalid literal");
        }
        pos += word.length();
        return v;
    }

    private Map<String, Object> object() throws JsonException {
        if (++depth > MAX_DEPTH) {
            throw error("nesting too deep");
        }
        pos++;
        Map<String, Object> m = new LinkedHashMap<>();
        skipWs();
        if (pos < s.length() && s.charAt(pos) == '}') {
            pos++;
            depth--;
            return m;
        }
        while (true) {
            skipWs();
            if (pos >= s.length() || s.charAt(pos) != '"') {
                throw error("expected object key");
            }
            String key = string();
            skipWs();
            expect(':');
            skipWs();
            Object v = value();
            if (m.containsKey(key) && rejectDuplicateKeys) {
                throw error("duplicate key '" + key + "'");
            }
            m.put(key, v);
            skipWs();
            if (pos < s.length() && s.charAt(pos) == ',') {
                pos++;
                continue;
            }
            expect('}');
            depth--;
            return m;
        }
    }

    private List<Object> array() throws JsonException {
        if (++depth > MAX_DEPTH) {
            throw error("nesting too deep");
        }
        pos++;
        List<Object> list = new ArrayList<>();
        skipWs();
        if (pos < s.length() && s.charAt(pos) == ']') {
            pos++;
            depth--;
            return list;
        }
        while (true) {
            skipWs();
            list.add(value());
            skipWs();
            if (pos < s.length() && s.charAt(pos) == ',') {
                pos++;
                continue;
            }
            expect(']');
            depth--;
            return list;
        }
    }

    private String string() throws JsonException {
        pos++;
        int start = pos;
        while (pos < s.length()) {
            char c = s.charAt(pos);
            if (c == '"') {
                return s.substring(start, pos++);
            }
            if (c == '\\' || c < 0x20) {
                break;
            }
            pos++;
        }
        StringBuilder sb = new StringBuilder(s.substring(start, pos));
        while (true) {
            if (pos >= s.length()) {
                throw error("unterminated string");
            }
            char c = s.charAt(pos++);
            if (c == '"') {
                return sb.toString();
            }
            if (c < 0x20) {
                throw error("control character in string");
            }
            if (c != '\\') {
                sb.append(c);
                continue;
            }
            if (pos >= s.length()) {
                throw error("unterminated string");
            }
            char e = s.charAt(pos++);
            switch (e) {
                case '"' -> sb.append('"');
                case '\\' -> sb.append('\\');
                case '/' -> sb.append('/');
                case 'b' -> sb.append('\b');
                case 'f' -> sb.append('\f');
                case 'n' -> sb.append('\n');
                case 'r' -> sb.append('\r');
                case 't' -> sb.append('\t');
                case 'u' -> {
                    if (pos + 4 > s.length()) {
                        throw error("invalid unicode escape");
                    }
                    int cp = 0;
                    for (int i = 0; i < 4; i++) {
                        int d = Character.digit(s.charAt(pos + i), 16);
                        if (d < 0) {
                            throw error("invalid unicode escape");
                        }
                        cp = cp * 16 + d;
                    }
                    pos += 4;
                    sb.append((char) cp);
                }
                default -> throw error("invalid escape");
            }
        }
    }

    private JsonNumber number() throws JsonException {
        int start = pos;
        if (s.charAt(pos) == '-') {
            pos++;
        }
        if (pos >= s.length()) {
            throw error("invalid number");
        }
        if (s.charAt(pos) == '0') {
            pos++;
        } else if (s.charAt(pos) >= '1' && s.charAt(pos) <= '9') {
            while (pos < s.length() && Character.isDigit(s.charAt(pos)) && s.charAt(pos) < 128) {
                pos++;
            }
        } else {
            throw error("invalid number");
        }
        if (pos < s.length() && s.charAt(pos) == '.') {
            pos++;
            int d = pos;
            while (pos < s.length() && s.charAt(pos) >= '0' && s.charAt(pos) <= '9') {
                pos++;
            }
            if (pos == d) {
                throw error("invalid number");
            }
        }
        if (pos < s.length() && (s.charAt(pos) == 'e' || s.charAt(pos) == 'E')) {
            pos++;
            if (pos < s.length() && (s.charAt(pos) == '+' || s.charAt(pos) == '-')) {
                pos++;
            }
            int d = pos;
            while (pos < s.length() && s.charAt(pos) >= '0' && s.charAt(pos) <= '9') {
                pos++;
            }
            if (pos == d) {
                throw error("invalid number");
            }
        }
        return new JsonNumber(s.substring(start, pos));
    }
}
