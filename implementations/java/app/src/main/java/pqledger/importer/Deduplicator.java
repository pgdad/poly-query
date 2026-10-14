package pqledger.importer;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Duplicate detection (spec §6.4): of the {@code f} records of a file with one key (date,
 * amount, merchant — the account is fixed) of which the ledger already holds {@code l}, the
 * last {@code max(0, f − l)} are new.
 */
public final class Deduplicator {
    /**
     * The key of a transaction within one account.
     *
     * @param cents amount in cents
     */
    public record Key(LocalDate date, long cents, String merchant) {
        public static Key of(BankRecord r) {
            return new Key(r.date(), r.cents(), r.merchant());
        }
    }

    private Deduplicator() {
    }

    /** The new records of {@code records} in file order, given the ledger's count per key. */
    public static List<BankRecord> newRecords(List<BankRecord> records, Map<Key, Long> ledgerCounts) {
        Map<Key, Long> fileCounts = new HashMap<>();
        for (BankRecord r : records) {
            fileCounts.merge(Key.of(r), 1L, Long::sum);
        }
        Map<Key, Long> seen = new HashMap<>();
        List<BankRecord> out = new ArrayList<>();
        for (BankRecord r : records) {
            Key k = Key.of(r);
            long index = seen.merge(k, 1L, Long::sum) - 1;
            long skipped = Math.min(fileCounts.get(k), ledgerCounts.getOrDefault(k, 0L));
            if (index >= skipped) {
                out.add(r);
            }
        }
        return out;
    }
}
