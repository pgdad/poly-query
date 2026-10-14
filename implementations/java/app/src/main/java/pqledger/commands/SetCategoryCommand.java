package pqledger.commands;

import java.math.BigInteger;
import pqledger.AppException;
import pqledger.ExitCode;
import pqledger.ledger.Ledger;
import pqledger.ledger.LedgerQueries;

/** {@code pqledger set-category ID CATEGORY} and {@code set-category ID --clear} (spec §8.3). */
final class SetCategoryCommand {
    private SetCategoryCommand() {
    }

    static ExitCode run(Session s) throws AppException {
        BigInteger requested = s.invocation().id();
        String category = s.invocation().clear() ? null : s.invocation().category();
        s.rules();
        try (Ledger ledger = s.openLedger()) {
            if (requested.bitLength() > 63 || ledger.query(LedgerQueries.countId(requested.longValue()))
                    .getLong(0, 0) == 0) {
                throw AppException.ledgerState("no transaction with id " + requested);
            }
            long id = requested.longValue();
            ledger.replaceTable(Ledger.OVERRIDES, LedgerQueries.overridesWith(id, category));
            ledger.save(Ledger.OVERRIDES);
            s.println("transaction " + id + ": category " + (category == null ? "cleared" : category));
        }
        return ExitCode.SUCCESS;
    }
}
