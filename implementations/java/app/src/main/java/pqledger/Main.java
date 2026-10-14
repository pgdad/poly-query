package pqledger;

import java.io.IOException;
import java.io.OutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.List;

/** Command-line entry point of pqledger. */
public final class Main {
    /** Deeply nested SQL in {@code pqledger query} needs a large stack for parsing and planning. */
    private static final long STACK_SIZE = 512L << 20;

    private Main() {
    }

    public static void main(String[] args) {
        Application.Outcome[] outcome = new Application.Outcome[1];
        Thread t = new Thread(null, () -> outcome[0] = Application.run(List.of(args),
                Path.of("").toAbsolutePath(), System.getenv()), "pqledger-main", STACK_SIZE);
        t.start();
        try {
            t.join();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
        Application.Outcome o = outcome[0];
        if (o == null) {
            o = new Application.Outcome(ExitCode.OTHER.status(), "", "pqledger: error: internal error\n");
        }
        write(System.out, o.stdout());
        write(System.err, o.stderr());
        System.exit(o.status());
    }

    private static void write(PrintStream stream, String text) {
        if (text.isEmpty()) {
            return;
        }
        try {
            OutputStream out = stream;
            out.write(text.getBytes(StandardCharsets.UTF_8));
            out.flush();
        } catch (IOException e) {
            // nowhere left to report it
        }
    }
}
