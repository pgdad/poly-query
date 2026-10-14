package pqledger.cli;

import java.math.BigInteger;
import pqledger.output.OutputFormat;

/**
 * A parsed and validated command line. Fields that a command does not use are null (or
 * defaults).
 *
 * @param configPath    {@code --config} value, or null
 * @param format        {@code --format} value, or null
 * @param command       the command
 * @param filters       filter options (commands with filters), else {@link Filters#NONE}
 * @param account       {@code --account} of {@code import} / {@code budget}, or null
 * @param file          {@code import} FILE
 * @param top           {@code report merchants --top} (default 10)
 * @param category      {@code list --category} or the {@code set-category} CATEGORY, or null
 * @param uncategorized {@code list --uncategorized}
 * @param id            {@code set-category} ID
 * @param clear         {@code set-category --clear}
 * @param sql           {@code query} SQL
 */
public record Invocation(String configPath, OutputFormat format, Command command, Filters filters, String account,
                         String file, long top, String category, boolean uncategorized, BigInteger id, boolean clear,
                         String sql) {
}
