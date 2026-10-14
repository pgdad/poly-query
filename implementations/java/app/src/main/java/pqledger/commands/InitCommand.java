package pqledger.commands;

import pqledger.AppException;
import pqledger.ExitCode;
import pqledger.ledger.Ledger;

/** {@code pqledger init} (spec §6.1). */
final class InitCommand {
    private InitCommand() {
    }

    static ExitCode run(Session s) throws AppException {
        Ledger.create(s.config());
        s.println("initialized ledger");
        return ExitCode.SUCCESS;
    }
}
