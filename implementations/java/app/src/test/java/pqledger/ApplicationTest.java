package pqledger;

import static pqledger.Check.eq;
import static pqledger.Check.isTrue;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;

/** End-to-end invocations of {@link Application} on a temporary ledger (spec §6–§10). */
final class ApplicationTest {
    private ApplicationTest() {
    }

    /** A temporary working directory with a configuration, rules, budgets and one statement. */
    private static final class Workspace implements AutoCloseable {
        final Path dir;

        Workspace() throws Exception {
            dir = Files.createTempDirectory("pqledger-app");
            write("pqledger.conf", """
                    [ledger]
                    data_dir = data/ledger
                    rules_file = rules.conf
                    budget_file = budgets.conf

                    [account visa]
                    date_format = MM/DD/YYYY
                    invert_sign = true
                    """);
            write("rules.conf", "groceries = WHOLE FOODS*, *MARKET\nrent = RENT\n");
            write("budgets.conf", "groceries = 100\nrent = 1000\n");
            write("checking.csv", """
                    Date,Description,Amount
                    2026-08-01,Rent 2026,-1200.00
                    2026-08-03,Whole Foods Market #10234,-45.10
                    2026-08-15,Salary,100.00
                    2026-08-15,Salary,100.00
                    2026-09-02,Corner Market,-60.00
                    """);
        }

        void write(String name, String text) throws Exception {
            Files.writeString(dir.resolve(name), text, StandardCharsets.UTF_8);
        }

        Application.Outcome run(String... args) {
            return Application.run(List.of(args), dir, Map.of());
        }

        /** Runs and checks the exit status; returns stdout. */
        String ok(int status, String... args) {
            Application.Outcome o = run(args);
            if (o.status() != status) {
                throw new AssertionError(String.join(" ", args) + ": expected exit " + status + " but got "
                        + o.status() + ": " + o.stderr());
            }
            return o.stdout();
        }

        @Override
        public void close() throws Exception {
            ConfigTest.delete(dir);
        }
    }

    static void testImportReportsAndBudgets() throws Exception {
        try (Workspace w = new Workspace()) {
            eq(6, w.run("accounts").status());
            eq("initialized ledger\n", w.ok(0, "init"));
            eq(6, w.run("init").status());
            eq("batch 1: imported 5, duplicates 0\n", w.ok(0, "import", "checking.csv", "--account", "chk"));
            eq("batch 2: imported 0, duplicates 5\n", w.ok(0, "import", "checking.csv", "--account", "chk"));
            eq("""
                    month,income,expenses,net,transactions
                    2026-08,200.00,1245.10,-1045.10,4
                    2026-09,0.00,60.00,-60.00,1
                    """, w.ok(0, "--format", "csv", "report", "monthly"));
            eq("""
                    category,spent,share,transactions
                    rent,1200.00,91.9,1
                    groceries,105.10,8.1,2
                    """, w.ok(0, "--format", "csv", "report", "categories"));
            eq("""
                    category    budget    spent  remaining  status
                    ---------  -------  -------  ---------  ------
                    groceries   100.00    45.10      54.90  ok
                    rent       1000.00  1200.00    -200.00  over
                    (2 rows)
                    """, w.ok(3, "budget", "--month", "2026-08"));
            eq("transaction 2: category dining\n", w.ok(0, "set-category", "2", "dining"));
            eq("{\"id\":2,\"category\":\"dining\"}\n",
                    w.ok(0, "--format", "json", "query", "SELECT id, category FROM ledger WHERE id = 2"));
            eq(6, w.run("set-category", "99", "dining").status());
            eq("transaction 2: category cleared\n", w.ok(0, "set-category", "2", "--clear"));
            eq("merchant,spent,transactions\nRENT,1200.00,1\n",
                    w.ok(0, "--format", "csv", "report", "merchants", "--top", "1"));
            eq("id,date,account,description,amount,category\n5,2026-09-02,chk,Corner Market,-60.00,groceries\n",
                    w.ok(0, "--format", "csv", "list", "--month", "2026-09"));
        }
    }

    static void testFailuresLeaveTheLedgerUnchanged() throws Exception {
        try (Workspace w = new Workspace()) {
            w.ok(0, "init");
            w.write("bad.csv", "Date,Description,Amount\n2026-08-01,ok,-1.00\n2026-08-02,bad,1.234\n");
            Application.Outcome o = w.run("import", "bad.csv", "--account", "chk");
            eq(4, o.status());
            eq("", o.stdout());
            isTrue(o.stderr().startsWith("pqledger: error: bad.csv:3: "), o.stderr());
            eq("batch,imported\n", w.ok(0, "--format", "csv", "query", "SELECT batch, imported FROM batches"));

            o = w.run("query", "SELECT nope FROM transactions");
            eq(5, o.status());
            isTrue(o.stderr().startsWith("pqledger: error: "), o.stderr());

            w.write("rules.conf", "Bad Category = X\n");
            eq(2, w.run("accounts").status());
            eq(1, w.run("accounts", "extra").status());
        }
    }

    static void testHelpAndVersionNeedNoConfiguration() throws Exception {
        try (Workspace w = new Workspace()) {
            Files.delete(w.dir.resolve("pqledger.conf"));
            isTrue(w.ok(0, "version").startsWith("pqledger "), "version line");
            isTrue(!w.ok(0, "help").isEmpty(), "help text");
            eq(2, w.run("init").status());
        }
    }
}
