package pqledger.commands;

import java.nio.file.Path;
import java.util.List;
import pqledger.AppException;
import pqledger.cli.Invocation;
import pqledger.config.Budget;
import pqledger.config.BudgetFile;
import pqledger.config.Config;
import pqledger.config.Rule;
import pqledger.config.RulesFile;
import pqledger.ledger.Ledger;
import pqledger.output.OutputFormat;
import pqledger.output.Renderer;
import pqledger.output.Tabular;

/**
 * Everything a command works with: the parsed command line, the configuration, the current
 * directory and the buffered standard output (printed only if the command succeeds).
 */
public final class Session {
    private final Invocation invocation;
    private final Config config;
    private final Path cwd;
    private final OutputFormat format;
    private final StringBuilder out = new StringBuilder();
    private List<Rule> rules;

    public Session(Invocation invocation, Config config, Path cwd) {
        this.invocation = invocation;
        this.config = config;
        this.cwd = cwd;
        this.format = invocation.format() != null ? invocation.format() : config.format();
    }

    public Invocation invocation() {
        return invocation;
    }

    public Config config() {
        return config;
    }

    public Path cwd() {
        return cwd;
    }

    /** The text written to stdout so far. */
    public String output() {
        return out.toString();
    }

    /** Prints a result in the selected output format. */
    public void print(Tabular t) {
        out.append(Renderer.render(t, format));
    }

    public void println(String line) {
        out.append(line).append('\n');
    }

    /** The category rules (read once per invocation; none without a rules file). */
    public List<Rule> rules() throws AppException {
        if (rules == null) {
            rules = RulesFile.load(config.rulesFile());
        }
        return rules;
    }

    /** The budgets of the budget file, or none if {@code required} is false and no file is configured. */
    public List<Budget> budgets(boolean required) throws AppException {
        if (config.budgetFile() == null) {
            if (required) {
                throw AppException.config("no budget_file configured in [ledger] of " + config.file());
            }
            return List.of();
        }
        return BudgetFile.load(config.budgetFile());
    }

    /** Opens the ledger (exit 6 if there is none). */
    public Ledger openLedger() throws AppException {
        return Ledger.open(config);
    }
}
