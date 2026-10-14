package demo;

import java.io.PrintStream;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.time.LocalDateTime;
import java.util.List;
import polyquery.api.ColumnType;
import polyquery.api.Database;
import polyquery.api.DatabaseConfig;
import polyquery.api.DatabaseException;
import polyquery.api.LoadOptions;
import polyquery.api.Result;

/**
 * The minimal embedding example (spec/apps/embedding.md §5):
 *
 * <pre>
 * pq-embed-demo DATA_DIR CSV_FILE SQL
 * </pre>
 *
 * Creates an engine instance on DATA_DIR, loads CSV_FILE (relative to DATA_DIR, header row,
 * inferred schema) as table {@code t}, runs SQL and prints the result as CSV. Uses only the
 * public API {@code polyquery.api}.
 */
public final class EmbedDemo {
    private EmbedDemo() {
    }

    public static void main(String[] args) {
        PrintStream out = new PrintStream(System.out, false, StandardCharsets.UTF_8);
        PrintStream err = new PrintStream(System.err, true, StandardCharsets.UTF_8);
        if (args.length != 3) {
            err.println("usage: pq-embed-demo DATA_DIR CSV_FILE SQL");
            System.exit(2);
        }
        try (Database db = Database.create(DatabaseConfig.of(Path.of(args[0])))) {
            db.loadFile("t", args[1], LoadOptions.csv());
            Result result = db.query(args[2]);
            out.print(toCsv(result));
            out.flush();
        } catch (DatabaseException e) {
            err.println("error: " + e.code() + ": " + e.getMessage());
            System.exit(1);
        }
    }

    /** The result in the {@code csv} format of pqledger (spec/apps/pqledger.md §7). */
    static String toCsv(Result result) {
        StringBuilder sb = new StringBuilder();
        List<String> names = result.columnNames();
        for (int c = 0; c < names.size(); c++) {
            sb.append(c > 0 ? "," : "").append(field(names.get(c)));
        }
        sb.append('\n');
        for (int r = 0; r < result.rowCount(); r++) {
            for (int c = 0; c < result.columnCount(); c++) {
                if (c > 0) {
                    sb.append(',');
                }
                Object v = result.get(r, c);
                if (v != null) { // NULL is an empty unquoted field
                    sb.append(field(text(v, result.columnTypes().get(c))));
                }
            }
            sb.append('\n');
        }
        return sb.toString();
    }

    /** The value text: DECIMAL with its scale, FLOAT64 like printf("%.6f"), DATE/TIMESTAMP ISO. */
    static String text(Object v, ColumnType type) {
        return switch (type.kind()) {
            case DECIMAL -> ((BigDecimal) v).toPlainString();
            case FLOAT64 -> new BigDecimal((Double) v).setScale(6, RoundingMode.HALF_EVEN).toPlainString();
            case TIMESTAMP -> {
                LocalDateTime t = (LocalDateTime) v;
                String s = t.toLocalDate() + String.format(" %02d:%02d:%02d", t.getHour(), t.getMinute(),
                        t.getSecond());
                yield t.getNano() == 0 ? s : s + String.format(".%06d", t.getNano() / 1000);
            }
            default -> v.toString(); // INT64, STRING, BOOLEAN, DATE (yyyy-mm-dd)
        };
    }

    /** A CSV field, quoted if empty or if it contains , " CR LF or starts/ends with a space. */
    static String field(String s) {
        boolean quote = s.isEmpty() || s.startsWith(" ") || s.endsWith(" ")
                || s.chars().anyMatch(ch -> ch == ',' || ch == '"' || ch == '\r' || ch == '\n');
        return quote ? '"' + s.replace("\"", "\"\"") + '"' : s;
    }
}
