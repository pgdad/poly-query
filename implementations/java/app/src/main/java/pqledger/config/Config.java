package pqledger.config;

import java.nio.file.Path;
import java.util.Map;
import pqledger.output.OutputFormat;

/**
 * The loaded configuration (spec §3). Paths are absolute.
 *
 * @param file           the configuration file
 * @param dataDir        the ledger directory
 * @param rulesFile      the rules file, or null
 * @param budgetFile     the budget file, or null
 * @param importDefaults the effective {@code [import]} settings
 * @param accounts       effective settings of the accounts with an {@code [account NAME]} section
 * @param format         {@code [output] format}
 * @param threads        {@code [engine] threads}, or null
 * @param memoryMb       {@code [engine] memory_mb}, or null
 */
public record Config(Path file, Path dataDir, Path rulesFile, Path budgetFile, ImportSettings importDefaults,
                     Map<String, ImportSettings> accounts, OutputFormat format, Integer threads, Long memoryMb) {
    public Config {
        accounts = Map.copyOf(accounts);
    }

    /** The effective import settings of {@code account}. */
    public ImportSettings importSettings(String account) {
        return accounts.getOrDefault(account, importDefaults);
    }
}
