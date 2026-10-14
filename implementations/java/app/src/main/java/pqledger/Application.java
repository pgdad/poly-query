package pqledger;

import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import polyquery.api.DatabaseException;
import pqledger.cli.Command;
import pqledger.cli.CommandLine;
import pqledger.cli.Invocation;
import pqledger.commands.Commands;
import pqledger.commands.Session;
import pqledger.config.Config;
import pqledger.config.ConfigLoader;

/**
 * One invocation of pqledger: parses the command line, loads the configuration, runs the
 * command and maps failures to exit statuses (spec §10). Standard output is written only
 * when the command succeeds (exit 0, or 3 for an over-budget {@code budget}).
 */
public final class Application {
    public static final String VERSION = "1.0.0";

    /** Text and exit status of an invocation. */
    public record Outcome(int status, String stdout, String stderr) {
    }

    private Application() {
    }

    public static Outcome run(List<String> args, Path cwd, Map<String, String> env) {
        try {
            Invocation inv = CommandLine.parse(args);
            if (inv.command() == Command.HELP) {
                return new Outcome(0, Usage.TEXT, "");
            }
            if (inv.command() == Command.VERSION) {
                return new Outcome(0, "pqledger " + VERSION + " (application spec 1.0.0, PolyQuery Java engine)\n",
                        "");
            }
            Config config = ConfigLoader.load(ConfigLoader.locate(inv.configPath(), env, cwd));
            Session session = new Session(inv, config, cwd);
            ExitCode code = Commands.run(session);
            return new Outcome(code.status(), session.output(), "");
        } catch (AppException e) {
            return failure(e.exitCode(), e.getMessage());
        } catch (DatabaseException e) {
            return failure(ExitCode.OTHER, e.code() + ": " + e.getMessage());
        } catch (StackOverflowError | OutOfMemoryError e) {
            return failure(ExitCode.OTHER, "out of resources: " + e);
        } catch (RuntimeException e) {
            return failure(ExitCode.OTHER, "internal error: " + e);
        }
    }

    private static Outcome failure(ExitCode code, String message) {
        return new Outcome(code.status(), "", "pqledger: error: " + message + "\n");
    }
}
