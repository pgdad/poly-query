package pqledger.importer;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import pqledger.AppException;
import pqledger.config.ColumnRef;
import pqledger.config.ImportSettings;
import pqledger.config.LineSyntax;

/**
 * Converts the text of a bank export into {@link BankRecord}s with the account's import
 * settings (spec §6.2). Any failure is an import data error naming the file and, for a bad
 * record, the physical line it starts on ({@code FILE:LINE: …}).
 */
public final class StatementParser {
    private final ImportSettings settings;
    private final String fileName;
    private final AmountParser amounts;

    public StatementParser(ImportSettings settings, String fileName) {
        this.settings = settings;
        this.fileName = fileName;
        this.amounts = new AmountParser(settings);
    }

    /** Parses {@code text} (decoded UTF-8, BOM removed). */
    public List<BankRecord> parse(String text) throws AppException {
        if (!settings.header()) {
            for (ColumnRef ref : settings.referencedColumns()) {
                if (ref.isName()) {
                    throw AppException.config("column reference '" + ref + "' is a header name but header = false");
                }
            }
        }
        List<CsvRecord> records;
        try {
            records = BankCsvReader.read(text, settings.delimiter(), settings.skipLines());
        } catch (BankCsvReader.CsvException e) {
            throw error(e.line(), e.getMessage());
        }
        if (records.isEmpty()) {
            for (ColumnRef ref : settings.referencedColumns()) {
                if (ref.isName()) {
                    throw AppException.importData(fileName + ": no header record (column '" + ref + "')");
                }
            }
            return List.of();
        }
        int width = records.getFirst().fields().size();
        List<String> header = settings.header() ? records.getFirst().fields() : List.of();
        int date = column(settings.dateColumn(), header, width, "date_column");
        int description = column(settings.descriptionColumn(), header, width, "description_column");
        boolean signed = settings.amountMode() == ImportSettings.AmountMode.SIGNED;
        int amount = signed ? column(settings.amountColumn(), header, width, "amount_column") : -1;
        int debit = signed ? -1 : column(settings.debitColumn(), header, width, "debit_column");
        int credit = signed ? -1 : column(settings.creditColumn(), header, width, "credit_column");

        List<BankRecord> out = new ArrayList<>(records.size());
        for (int i = settings.header() ? 1 : 0; i < records.size(); i++) {
            CsvRecord r = records.get(i);
            List<String> f = r.fields();
            if (f.size() != width) {
                throw error(r.line(), "record has " + f.size() + " fields, expected " + width);
            }
            String dateText = LineSyntax.trim(f.get(date));
            LocalDate d = settings.dateFormat().parse(dateText);
            if (d == null) {
                throw error(r.line(), "invalid date '" + dateText + "' (expected " + settings.dateFormat() + ")");
            }
            String desc = LineSyntax.trim(f.get(description));
            long cents;
            try {
                cents = signed ? amounts.parse(f.get(amount)) : debitCredit(f.get(debit), f.get(credit));
            } catch (IllegalArgumentException | ArithmeticException e) {
                throw error(r.line(), e.getMessage());
            }
            if (settings.invertSign()) {
                cents = -cents;
            }
            out.add(new BankRecord(r.line(), d, desc, Merchants.normalize(desc), cents));
        }
        return out;
    }

    private long debitCredit(String debit, String credit) {
        boolean noDebit = AmountParser.isBlank(debit);
        boolean noCredit = AmountParser.isBlank(credit);
        if (noDebit && noCredit) {
            throw new IllegalArgumentException("both debit and credit are empty");
        }
        long d = noDebit ? 0 : amounts.parse(debit);
        long c = noCredit ? 0 : amounts.parse(credit);
        return Math.subtractExact(c, d);
    }

    private int column(ColumnRef ref, List<String> header, int width, String key) throws AppException {
        int index = ref.resolve(header);
        if (index < 0) {
            throw AppException.importData(fileName + ": the header has no column '" + ref + "' (" + key + ")");
        }
        if (index >= width) {
            throw AppException.importData(fileName + ": column " + ref + " (" + key + ") is beyond the "
                    + width + " columns of the file");
        }
        return index;
    }

    private AppException error(int line, String message) {
        return AppException.importData(fileName + ":" + line + ": " + message);
    }
}
