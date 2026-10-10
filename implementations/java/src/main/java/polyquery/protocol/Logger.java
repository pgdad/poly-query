package polyquery.protocol;

import java.io.PrintStream;
import java.time.Instant;
import java.util.Locale;
import java.util.Map;
import polyquery.json.JsonWriter;

/**
 * Structured logger: one JSON object per line on stderr with at least {@code ts} (RFC 3339
 * UTC), {@code level} and {@code msg}, plus event-specific fields (protocol.md §7.4).
 */
public final class Logger {
    public enum Level { DEBUG, INFO, WARN, ERROR, OFF }

    private final Level level;
    private final PrintStream out;

    public Logger(Level level, PrintStream out) {
        this.level = level;
        this.out = out;
    }

    public static Level parseLevel(String s) {
        try {
            return Level.valueOf(s.toUpperCase(Locale.ROOT));
        } catch (IllegalArgumentException e) {
            return null;
        }
    }

    public boolean enabled(Level l) {
        return level != Level.OFF && l != Level.OFF && l.ordinal() >= level.ordinal();
    }

    /** Logs {@code msg} with extra fields (values must be JSON-serializable by {@link JsonWriter}). */
    public void log(Level l, String msg, Map<String, Object> fields) {
        if (!enabled(l)) {
            return;
        }
        StringBuilder sb = new StringBuilder(128);
        sb.append("{\"ts\":\"").append(Instant.now()).append("\",\"level\":\"")
                .append(l.name().toLowerCase(Locale.ROOT)).append("\",\"msg\":");
        JsonWriter.writeString(sb, msg);
        for (Map.Entry<String, Object> f : fields.entrySet()) {
            sb.append(',');
            JsonWriter.writeString(sb, f.getKey());
            sb.append(':');
            JsonWriter.write(sb, f.getValue());
        }
        sb.append('}');
        synchronized (out) {
            out.println(sb);
            out.flush();
        }
    }

    public void debug(String msg) {
        log(Level.DEBUG, msg, Map.of());
    }

    public void info(String msg) {
        log(Level.INFO, msg, Map.of());
    }

    public void info(String msg, Map<String, Object> fields) {
        log(Level.INFO, msg, fields);
    }

    public void warn(String msg) {
        log(Level.WARN, msg, Map.of());
    }

    public void error(String msg) {
        log(Level.ERROR, msg, Map.of());
    }
}
