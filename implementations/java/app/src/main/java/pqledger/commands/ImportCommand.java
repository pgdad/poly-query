package pqledger.commands;

import java.io.IOException;
import java.math.BigDecimal;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.InvalidPathException;
import java.nio.file.NoSuchFileException;
import java.nio.file.Path;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import polyquery.api.Result;
import pqledger.AppException;
import pqledger.ExitCode;
import pqledger.importer.BankRecord;
import pqledger.importer.Deduplicator;
import pqledger.importer.StatementParser;
import pqledger.ledger.Ledger;
import pqledger.ledger.LedgerQueries;

/** {@code pqledger import FILE --account NAME} (spec §6.2–§6.4). */
final class ImportCommand {
    private static final String NEW_TRANSACTIONS = "new_transactions";
    private static final String NEW_BATCH = "new_batch";

    private ImportCommand() {
    }

    static ExitCode run(Session s) throws AppException {
        String file = s.invocation().file();
        String account = s.invocation().account();
        s.rules(); // read by every ledger command: an invalid rules file is reported here too
        try (Ledger ledger = s.openLedger()) {
            Path path = resolve(s.cwd(), file);
            List<BankRecord> records = new StatementParser(s.config().importSettings(account), file)
                    .parse(read(path, file));
            List<BankRecord> fresh = Deduplicator.newRecords(records, ledgerCounts(ledger, account, records));
            Result maxima = ledger.query(LedgerQueries.maxima());
            long nextId = maxima.getLong(0, 0) + 1;
            long batch = maxima.getLong(0, 1) + 1;
            if (!fresh.isEmpty()) {
                List<List<Object>> rows = new ArrayList<>(fresh.size());
                for (BankRecord r : fresh) {
                    rows.add(List.of(nextId++, account, r.date(), r.description(), r.merchant(),
                            BigDecimal.valueOf(r.cents(), 2), batch));
                }
                ledger.database().createTable(NEW_TRANSACTIONS, Ledger.TRANSACTION_COLUMNS, rows, false);
                ledger.replaceTable(Ledger.TRANSACTIONS, LedgerQueries.append(Ledger.TRANSACTIONS, NEW_TRANSACTIONS,
                        "id"));
            }
            int duplicates = records.size() - fresh.size();
            String baseName = path.getFileName().toString();
            ledger.database().createTable(NEW_BATCH, Ledger.BATCH_COLUMNS,
                    List.of(List.of(batch, account, baseName, (long) fresh.size(), (long) duplicates)), false);
            ledger.replaceTable(Ledger.BATCHES, LedgerQueries.append(Ledger.BATCHES, NEW_BATCH, "batch"));
            if (!fresh.isEmpty()) {
                ledger.save(Ledger.TRANSACTIONS);
            }
            ledger.save(Ledger.BATCHES);
            s.println("batch " + batch + ": imported " + fresh.size() + ", duplicates " + duplicates);
        }
        return ExitCode.SUCCESS;
    }

    private static Path resolve(Path cwd, String file) throws AppException {
        try {
            return cwd.resolve(file).normalize();
        } catch (InvalidPathException e) {
            throw AppException.importData(file + ": invalid file name");
        }
    }

    /** The file as UTF-8 text without a leading BOM. */
    private static String read(Path path, String file) throws AppException {
        byte[] bytes;
        try {
            if (Files.isDirectory(path)) {
                throw AppException.importData(file + ": is a directory");
            }
            bytes = Files.readAllBytes(path);
        } catch (NoSuchFileException e) {
            throw AppException.importData(file + ": no such file");
        } catch (IOException | SecurityException e) {
            throw AppException.importData(file + ": cannot read: " + e.getMessage());
        }
        try {
            String text = StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes)).toString();
            return text.startsWith("﻿") ? text.substring(1) : text;
        } catch (CharacterCodingException e) {
            throw AppException.importData(file + ": not valid UTF-8");
        }
    }

    /** How many transactions of {@code account} the ledger holds per key, for the file's date range. */
    private static Map<Deduplicator.Key, Long> ledgerCounts(Ledger ledger, String account, List<BankRecord> records) {
        if (records.isEmpty()) {
            return Map.of();
        }
        LocalDate from = records.stream().map(BankRecord::date).min(Comparator.naturalOrder()).orElseThrow();
        LocalDate to = records.stream().map(BankRecord::date).max(Comparator.naturalOrder()).orElseThrow();
        Result r = ledger.query(LedgerQueries.keyCounts(account, from, to));
        Map<Deduplicator.Key, Long> counts = new HashMap<>();
        for (int i = 0; i < r.rowCount(); i++) {
            long cents = r.getDecimal(i, 1).unscaledValue().longValueExact();
            counts.put(new Deduplicator.Key(r.getDate(i, 0), cents, r.getString(i, 2)), r.getLong(i, 3));
        }
        return counts;
    }
}
