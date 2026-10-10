package polyquery.protocol;

import java.io.PrintStream;
import java.time.Instant;
import java.util.Locale;
import polyquery.json.JsonWriter;

/** Minimal structured (JSON lines) logger writing to stderr. */
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

    private void log(Level l, String msg) {
        if (level == Level.OFF || l.ordinal() < level.ordinal()) {
            return;
        }
        StringBuilder sb = new StringBuilder();
        sb.append("{\"ts\":\"").append(Instant.now()).append("\",\"level\":\"")
                .append(l.name().toLowerCase(Locale.ROOT)).append("\",\"msg\":");
        JsonWriter.writeString(sb, msg);
        sb.append('}');
        synchronized (out) {
            out.println(sb);
            out.flush();
        }
    }

    public void debug(String msg) {
        log(Level.DEBUG, msg);
    }

    public void info(String msg) {
        log(Level.INFO, msg);
    }

    public void warn(String msg) {
        log(Level.WARN, msg);
    }

    public void error(String msg) {
        log(Level.ERROR, msg);
    }
}
