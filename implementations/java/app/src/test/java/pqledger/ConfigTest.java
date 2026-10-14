package pqledger;

import static pqledger.Check.eq;
import static pqledger.Check.fails;
import static pqledger.Check.isTrue;

import java.io.IOException;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import pqledger.config.Budget;
import pqledger.config.BudgetFile;
import pqledger.config.Config;
import pqledger.config.ConfigLoader;
import pqledger.config.DateFormat;
import pqledger.config.ImportSettings;
import pqledger.config.Rule;
import pqledger.config.RulesFile;
import pqledger.output.OutputFormat;

/** The configuration, rules and budget files (spec §3, §5). */
final class ConfigTest {
    private ConfigTest() {
    }

    private static Config load(String text) throws Exception {
        Path dir = Files.createTempDirectory("pqledger-config");
        Path file = dir.resolve("pqledger.conf");
        Files.writeString(file, text, StandardCharsets.UTF_8);
        try {
            return ConfigLoader.load(file);
        } finally {
            delete(dir);
        }
    }

    static void delete(Path p) throws IOException {
        if (Files.isDirectory(p)) {
            try (var children = Files.list(p)) {
                for (Path c : children.toList()) {
                    delete(c);
                }
            }
        }
        Files.deleteIfExists(p);
    }

    static void testCompleteConfiguration() throws Exception {
        Config c = load("﻿# comment\r\n[ledger]\r\ndata_dir = ledger\r\nrules_file = \"rules.conf\"\n"
                + "; another comment\n[import]\ndelimiter = tab\nskip_lines = 2\n"
                + "[account visa]\ndate_format = MM/DD/YYYY\ninvert_sign = true\ncurrency_symbol = \" $\\\" \"\n"
                + "[output]\nformat = json\n[engine]\nthreads = 2\nmemory_mb = 512\n");
        eq("ledger", c.dataDir().getFileName().toString());
        isTrue(c.dataDir().isAbsolute(), "data_dir is resolved against the configuration's directory");
        eq("rules.conf", c.rulesFile().getFileName().toString());
        eq(null, c.budgetFile());
        eq(OutputFormat.JSON, c.format());
        eq(2, c.threads());
        eq(512L, c.memoryMb());
        ImportSettings visa = c.importSettings("visa");
        eq('\t', visa.delimiter());
        eq(2, visa.skipLines());
        eq(DateFormat.US, visa.dateFormat());
        eq(true, visa.invertSign());
        eq(" $\" ", visa.currencySymbol());
        ImportSettings other = c.importSettings("checking");
        eq(false, other.invertSign());
        eq(DateFormat.ISO, other.dateFormat());
    }

    static void testConfigurationErrorsAreExit2WithLineNumbers() throws Exception {
        String ledger = "[ledger]\ndata_dir = d\n";
        List<String> bad = List.of(
                "data_dir = d\n[ledger]\n",
                "[ledger]\n",
                ledger + "[ledger]\n",
                ledger + "[import]\nheader = yes\n",
                ledger + "[import]\nskip_lines = -1\n",
                ledger + "[import]\ndecimal_separator = ,\nthousands_separator = ,\n",
                ledger + "[import]\nthousands_separator = .\n[account x]\ndecimal_separator = .\n",
                ledger + "[import]\ndate_format = YYYY/MM/DD\n",
                ledger + "[import]\nfoo = 1\n",
                ledger + "[import]\nheader = true\nheader = false\n",
                ledger + "[account Bad]\n",
                ledger + "[account  x]\n",
                ledger + "[accounts]\n",
                ledger + "[output]\nformat = xml\n",
                ledger + "[engine]\nthreads = 0\n",
                ledger + "[import]\ndate_column = 0\n",
                ledger + "[import]\ndelimiter = ;;\n",
                ledger + "no equals sign\n");
        for (String text : bad) {
            AppException e = fails(ExitCode.CONFIG, () -> load(text));
            isTrue(e.getMessage().contains("pqledger.conf"), "message names the file: " + e.getMessage());
        }
        AppException e = fails(ExitCode.CONFIG, () -> load(ledger + "[import]\nheader = maybe\n"));
        isTrue(e.getMessage().contains(":4:"), "message names line 4: " + e.getMessage());
    }

    static void testLocatingTheFile() throws Exception {
        Path cwd = Path.of("/work");
        eq(Path.of("/work/a.conf"), ConfigLoader.locate("a.conf", Map.of("PQLEDGER_CONFIG", "/b.conf"), cwd));
        eq(Path.of("/b.conf"), ConfigLoader.locate(null, Map.of("PQLEDGER_CONFIG", "/b.conf"), cwd));
        eq(Path.of("/work/pqledger.conf"), ConfigLoader.locate(null, Map.of("PQLEDGER_CONFIG", ""), cwd));
        eq(Path.of("/work/pqledger.conf"), ConfigLoader.locate(null, Map.of(), cwd));
        fails(ExitCode.CONFIG, () -> ConfigLoader.load(Path.of("/nonexistent/pqledger.conf")));
    }

    static void testRules() throws Exception {
        List<Rule> rules = RulesFile.parse("# rules\ngroceries = whole foods*, Trader Joe?s\n\nfuel = SHELL*\n"
                + "groceries = *Market\n", "rules.conf");
        eq(4, rules.size());
        eq(new Rule(1, "groceries", "WHOLE FOODS*"), rules.get(0));
        eq(new Rule(2, "groceries", "TRADER JOE?S"), rules.get(1));
        eq("TRADER JOE_S", rules.get(1).likePattern());
        eq(new Rule(4, "groceries", "*MARKET"), rules.get(3));
        eq("%MARKET", rules.get(3).likePattern());
        for (String bad : List.of("Groceries = x\n", "uncategorized = x\n", "a = x,\n", "a = 100%\n", "a = a_b\n",
                "[x]\n", "a =\n")) {
            fails(ExitCode.CONFIG, () -> RulesFile.parse(bad, "rules.conf"));
        }
    }

    static void testBudgets() throws Exception {
        List<Budget> budgets = BudgetFile.parse("groceries = 400\nfuel = 120.5\n", "b.conf");
        eq(new Budget("groceries", new BigDecimal("400.00")), budgets.get(0));
        eq(new BigDecimal("120.50"), budgets.get(1).amount());
        for (String bad : List.of("a = 1\na = 2\n", "a = -1\n", "a = 1.234\n", "a = 12345678901234567\n",
                "a = 1,5\n", "A = 1\n")) {
            fails(ExitCode.CONFIG, () -> BudgetFile.parse(bad, "b.conf"));
        }
    }
}
