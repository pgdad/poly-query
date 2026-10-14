package pqledger;

import static pqledger.Check.eq;
import static pqledger.Check.fails;

import java.math.BigInteger;
import java.time.YearMonth;
import java.util.List;
import pqledger.cli.Command;
import pqledger.cli.CommandLine;
import pqledger.cli.Invocation;
import pqledger.output.OutputFormat;

/** Command-line parsing (spec §2). */
final class CliTest {
    private CliTest() {
    }

    private static Invocation parse(String... args) throws AppException {
        return CommandLine.parse(List.of(args));
    }

    static void testGlobalOptionsAndCommands() throws Exception {
        Invocation inv = parse("--config", "x.conf", "--format", "csv", "report", "merchants", "--top", "3",
                "--from", "2026-01");
        eq("x.conf", inv.configPath());
        eq(OutputFormat.CSV, inv.format());
        eq(Command.REPORT_MERCHANTS, inv.command());
        eq(3L, inv.top());
        eq(YearMonth.of(2026, 1), inv.filters().months().from());
        eq(null, inv.filters().months().to());
        eq(Command.HELP, parse("--help").command());
        eq(10L, parse("report", "merchants").top());
    }

    static void testOptionsInAnyOrderAmongPositionals() throws Exception {
        Invocation inv = parse("import", "--account", "visa", "card.csv");
        eq("card.csv", inv.file());
        eq("visa", inv.account());
        inv = parse("set-category", "--clear", "12");
        eq(BigInteger.valueOf(12), inv.id());
        eq(true, inv.clear());
        inv = parse("set-category", "7", "dining");
        eq("dining", inv.category());
        inv = parse("list", "--uncategorized", "--month", "2026-02", "--account", "chk");
        eq(true, inv.uncategorized());
        eq(YearMonth.of(2026, 2), inv.filters().months().to());
        eq("SELECT 1", parse("query", "SELECT 1").sql());
    }

    static void testUsageErrors() {
        List<List<String>> bad = List.of(
                List.of(),
                List.of("frobnicate"),
                List.of("report"),
                List.of("report", "weekly"),
                List.of("init", "extra"),
                List.of("import", "f.csv"),
                List.of("import", "f.csv", "--account"),
                List.of("import", "f.csv", "--account", "Visa"),
                List.of("list", "--month", "2026-1"),
                List.of("list", "--month", "2026-13"),
                List.of("list", "--month", "0000-01"),
                List.of("list", "--month", "2026-01", "--from", "2026-01"),
                List.of("list", "--from", "2026-03", "--to", "2026-02"),
                List.of("list", "--month", "2026-01", "--month", "2026-01"),
                List.of("list", "--category", "Food"),
                List.of("list", "--category", "a", "--uncategorized"),
                List.of("list", "--top", "3"),
                List.of("report", "merchants", "--top", "0"),
                List.of("report", "merchants", "--top", "-1"),
                List.of("budget"),
                List.of("budget", "--month", "2026-01", "--from", "2026-01"),
                List.of("set-category", "0", "x"),
                List.of("set-category", "1"),
                List.of("set-category", "1", "uncategorized"),
                List.of("set-category", "1", "x", "--clear"),
                List.of("query"),
                List.of("query", "SELECT 1", "SELECT 2"),
                List.of("--format", "xml", "accounts"),
                List.of("accounts", "--format", "csv"),
                List.of("--config", "a", "--config", "b", "accounts"),
                List.of("--verbose", "accounts"));
        for (List<String> args : bad) {
            fails(ExitCode.USAGE, () -> CommandLine.parse(args));
        }
    }
}
