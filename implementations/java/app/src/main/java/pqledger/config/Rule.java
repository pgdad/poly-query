package pqledger.config;

/**
 * One pattern of the rules file.
 *
 * @param number   1, 2, … in file order (line order, then order within the line)
 * @param category the category assigned by the pattern
 * @param pattern  the pattern as written, ASCII letters upper-cased ({@code *} any sequence,
 *                 {@code ?} one character)
 */
public record Rule(int number, String category, String pattern) {
    /** The pattern as a SQL {@code LIKE} pattern ({@code *} → {@code %}, {@code ?} → {@code _}). */
    public String likePattern() {
        return pattern.replace('*', '%').replace('?', '_');
    }
}
