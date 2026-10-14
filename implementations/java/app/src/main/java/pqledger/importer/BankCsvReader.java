package pqledger.importer;

import java.util.ArrayList;
import java.util.List;

/**
 * Splits the text of a bank export into CSV records (spec §6.2 steps 1–2, ingestion.md §1):
 * RFC 4180 with a configurable delimiter, quote {@code "}, {@code \n} or {@code \r\n} line
 * ends; completely empty lines are ignored. The first {@code skipLines} physical lines are
 * skipped. Every record remembers the physical line it starts on.
 */
public final class BankCsvReader {
    private final String text;
    private final char delimiter;
    private int pos;
    private int line = 1;

    private BankCsvReader(String text, char delimiter) {
        this.text = text;
        this.delimiter = delimiter;
    }

    /**
     * Parses {@code text} (BOM already removed).
     *
     * @throws CsvException for a quoted field that is not closed or is followed by other text
     */
    public static List<CsvRecord> read(String text, char delimiter, int skipLines) throws CsvException {
        BankCsvReader r = new BankCsvReader(text, delimiter);
        r.skip(skipLines);
        List<CsvRecord> records = new ArrayList<>();
        CsvRecord rec;
        while ((rec = r.next()) != null) {
            records.add(rec);
        }
        return records;
    }

    /** A malformed record; {@link #line()} is where it starts. */
    public static final class CsvException extends Exception {
        private static final long serialVersionUID = 1L;
        private final int line;

        CsvException(int line, String message) {
            super(message);
            this.line = line;
        }

        public int line() {
            return line;
        }
    }

    private void skip(int lines) {
        for (int i = 0; i < lines && pos < text.length(); i++) {
            int nl = text.indexOf('\n', pos);
            pos = nl < 0 ? text.length() : nl + 1;
            line++;
        }
    }

    /** True if a record terminator ({@code \n} or {@code \r\n}) starts at {@code pos}. */
    private boolean atLineEnd() {
        return pos < text.length() && (text.charAt(pos) == '\n'
                || text.charAt(pos) == '\r' && pos + 1 < text.length() && text.charAt(pos + 1) == '\n');
    }

    private void consumeLineEnd() {
        pos += text.charAt(pos) == '\r' ? 2 : 1;
        line++;
    }

    private CsvRecord next() throws CsvException {
        while (atLineEnd()) {
            consumeLineEnd(); // empty line
        }
        if (pos >= text.length()) {
            return null;
        }
        int start = line;
        List<String> fields = new ArrayList<>();
        while (true) {
            fields.add(pos < text.length() && text.charAt(pos) == '"' ? quoted(start) : unquoted());
            if (pos >= text.length()) {
                break;
            }
            if (atLineEnd()) {
                consumeLineEnd();
                break;
            }
            pos++; // delimiter
        }
        return new CsvRecord(start, fields);
    }

    private String unquoted() {
        int from = pos;
        while (pos < text.length() && text.charAt(pos) != delimiter && !atLineEnd()) {
            pos++;
        }
        return text.substring(from, pos);
    }

    private String quoted(int recordLine) throws CsvException {
        StringBuilder sb = new StringBuilder();
        pos++;
        while (true) {
            if (pos >= text.length()) {
                throw new CsvException(recordLine, "unterminated quoted field");
            }
            char c = text.charAt(pos++);
            if (c == '"') {
                if (pos < text.length() && text.charAt(pos) == '"') {
                    sb.append('"');
                    pos++;
                    continue;
                }
                if (pos < text.length() && text.charAt(pos) != delimiter && !atLineEnd()) {
                    throw new CsvException(recordLine, "unexpected text after a closing quote");
                }
                return sb.toString();
            }
            if (c == '\n') {
                line++;
            }
            sb.append(c);
        }
    }
}
