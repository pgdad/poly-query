package pqledger;

import static pqledger.Check.eq;
import static pqledger.Check.fails;
import static pqledger.Check.invalid;

import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import pqledger.config.DateFormat;
import pqledger.config.ImportSettings;
import pqledger.importer.AmountParser;
import pqledger.importer.BankCsvReader;
import pqledger.importer.BankRecord;
import pqledger.importer.CsvRecord;
import pqledger.importer.Deduplicator;
import pqledger.importer.Merchants;
import pqledger.importer.StatementParser;

/** Bank CSV reading, amount and date conversion, merchant normalization and duplicates (spec §6). */
final class ImporterTest {
    private ImporterTest() {
    }

    static void testMerchantNormalization() {
        eq("WHOLE FOODS MARKET", Merchants.normalize("Whole Foods Market #10234"));
        eq("SQ *BLUE BOTTLE", Merchants.normalize("SQ *Blue  Bottle 4421"));
        eq("RENT", Merchants.normalize("Rent 2026"));
        eq("7-ELEVEN 12", Merchants.normalize("7-Eleven 12"));
        eq("#123", Merchants.normalize("#123"));
        eq("CAFé", Merchants.normalize(" \tCafé\t "));
        eq("A 123", Merchants.normalize("a 123 456"));
        eq("SHOP #", Merchants.normalize("shop #"));
        eq("", Merchants.normalize(""));
    }

    private static AmountParser amounts(String... keyValues) {
        ImportSettings s = ImportSettings.DEFAULTS;
        for (int i = 0; i < keyValues.length; i += 2) {
            s = s.with(keyValues[i], keyValues[i + 1]);
        }
        return new AmountParser(s);
    }

    static void testSignedAmounts() {
        AmountParser p = amounts();
        eq(-1250L, p.parse(" -12.5 "));
        eq(1200L, p.parse("+12"));
        eq(-1999L, p.parse("(19.99)"));
        eq(0L, p.parse("-0.00"));
        eq(999_999_999_999_999_999L, p.parse("9999999999999999.99"));
        invalid(() -> p.parse("12.345"));
        invalid(() -> p.parse("1,000.00"));
        invalid(() -> p.parse(""));
        invalid(() -> p.parse("--1"));
        invalid(() -> p.parse("12345678901234567"));
        invalid(() -> p.parse(".5"));
    }

    static void testLocalizedAmounts() {
        AmountParser de = amounts("decimal_separator", ",", "thousands_separator", ".", "currency_symbol", "€");
        eq(123456L, de.parse("1.234,56 €"));
        eq(-123456L, de.parse("-€1.234,56"));
        AmountParser us = amounts("thousands_separator", ",", "currency_symbol", "$");
        eq(-123400L, us.parse("($1,234.00)"));
        AmountParser ch = amounts("thousands_separator", "'");
        eq(100000000L, ch.parse("1'000'000"));
        AmountParser fr = amounts("decimal_separator", ",", "thousands_separator", "space");
        eq(123450L, fr.parse("1 234,5"));
    }

    static void testDateFormats() {
        eq(LocalDate.of(2026, 9, 3), DateFormat.ISO.parse("2026-09-03"));
        eq(null, DateFormat.ISO.parse("2026-9-3"));
        eq(LocalDate.of(2026, 9, 3), DateFormat.COMPACT.parse("20260903"));
        eq(LocalDate.of(2026, 9, 3), DateFormat.US.parse("9/3/2026"));
        eq(LocalDate.of(2026, 3, 9), DateFormat.EUROPEAN.parse("9/3/2026"));
        eq(LocalDate.of(2024, 2, 29), DateFormat.GERMAN.parse("29.02.2024"));
        eq(null, DateFormat.GERMAN.parse("29.02.2026"));
        eq(null, DateFormat.US.parse("13/01/2026"));
        eq(null, DateFormat.ISO.parse("0000-01-01"));
        eq(null, DateFormat.US.parse("1/1/26"));
    }

    static void testCsvRecordsAndLines() throws Exception {
        String text = "preamble\n\"x\";y\nDate;Amount\r\n\r\n2026-01-01;\"multi\nline\"\n2026-01-02;\"a \"\"q\"\"\"";
        List<CsvRecord> records = BankCsvReader.read(text, ';', 2);
        eq(3, records.size());
        eq(3, records.get(0).line());
        eq(List.of("Date", "Amount"), records.get(0).fields());
        eq(5, records.get(1).line());
        eq("multi\nline", records.get(1).fields().get(1));
        eq(7, records.get(2).line());
        eq("a \"q\"", records.get(2).fields().get(1));
        try {
            BankCsvReader.read("a,b\n1,\"open\n", ',', 0);
            throw new AssertionError("unterminated quote accepted");
        } catch (BankCsvReader.CsvException e) {
            eq(2, e.line());
        }
    }

    static void testStatementParser() throws Exception {
        ImportSettings s = ImportSettings.DEFAULTS.with("amount_mode", "debit_credit").with("date_format", "DD.MM.YYYY")
                .with("decimal_separator", ",").with("description_column", "2");
        String text = "DATE,Text,Debit,Credit\n1.2.2026,  Shop  #12 ,\"5,00\",\n02.02.2026,Salary,,\"100\"\n";
        List<BankRecord> records = new StatementParser(s, "f.csv").parse(text);
        eq(2, records.size());
        eq(new BankRecord(2, LocalDate.of(2026, 2, 1), "Shop  #12", "SHOP", -500), records.get(0));
        eq(10000L, records.get(1).cents());

        AppException e = fails(ExitCode.IMPORT_DATA,
                () -> new StatementParser(s, "f.csv").parse("Date,Text,Debit,Credit\n01.02.2026,x,,\n"));
        eq("f.csv:2: both debit and credit are empty", e.getMessage());
        fails(ExitCode.IMPORT_DATA, () -> new StatementParser(ImportSettings.DEFAULTS, "f.csv")
                .parse("Date,Description\n2026-01-01,x\n"));
        fails(ExitCode.IMPORT_DATA, () -> new StatementParser(ImportSettings.DEFAULTS, "f.csv")
                .parse("Date,Description,Amount\n2026-01-01,x\n"));
        fails(ExitCode.IMPORT_DATA, () -> new StatementParser(ImportSettings.DEFAULTS.with("invert_sign", "true"),
                "f.csv").parse("Date,Description,Amount\n2026-02-30,x,1\n"));
        List<BankRecord> inverted = new StatementParser(ImportSettings.DEFAULTS.with("invert_sign", "true"), "f.csv")
                .parse("Date,Description,Amount\n2026-02-03,x,1.5\n");
        eq(-150L, inverted.getFirst().cents());
    }

    static void testDuplicatesKeepTheLastRecords() {
        LocalDate d = LocalDate.of(2026, 1, 1);
        BankRecord a1 = new BankRecord(2, d, "A", "A", -100);
        BankRecord a2 = new BankRecord(3, d, "a", "A", -100);
        BankRecord a3 = new BankRecord(4, d, "a ", "A", -100);
        BankRecord b = new BankRecord(5, d, "B", "B", -100);
        List<BankRecord> file = List.of(a1, a2, b, a3);
        eq(file, Deduplicator.newRecords(file, Map.of()));
        eq(List.of(a2, b, a3), Deduplicator.newRecords(file, Map.of(new Deduplicator.Key(d, -100, "A"), 1L)));
        eq(List.of(b), Deduplicator.newRecords(file, Map.of(new Deduplicator.Key(d, -100, "A"), 5L)));
        eq(List.of(a1, a2, a3), Deduplicator.newRecords(file, Map.of(Deduplicator.Key.of(b), 1L)));
    }
}
