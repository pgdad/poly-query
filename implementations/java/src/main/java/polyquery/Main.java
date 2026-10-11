package polyquery;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.engine.Engine;
import polyquery.engine.EngineConfig;
import polyquery.engine.Version;
import polyquery.ffi.NativeKernels;
import polyquery.ffi.NativeLoadException;
import polyquery.json.JsonException;
import polyquery.json.JsonParser;
import polyquery.json.JsonWriter;
import polyquery.protocol.Logger;
import polyquery.protocol.RequestHandler;
import polyquery.server.HttpServer;
import polyquery.server.ServerConfig;

/** Command-line entry point (protocol.md §2). */
public final class Main {
    private static final Set<String> VALUE_OPTIONS = Set.of(
            "--data-dir", "--max-query-memory-mb", "--max-ingest-bytes", "--max-table-rows", "--max-join-rows",
            "--threads", "--log-level", "--native-kernels", "--request", "--host", "--port", "--workers",
            "--queue-depth", "--query-timeout-ms", "--shutdown-grace-ms", "--max-request-bytes");
    private static final Set<String> FLAG_OPTIONS = Set.of("--enable-test-functions");
    private static final long STACK_SIZE = 512L << 20;

    private Main() {
    }

    private static final class UsageException extends Exception {
        UsageException(String msg) {
            super(msg);
        }
    }

    public static void main(String[] args) {
        int[] exit = {0};
        Thread t = new Thread(null, () -> exit[0] = run(args), "polyquery-main", STACK_SIZE);
        t.start();
        try {
            t.join();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
        System.exit(exit[0]);
    }

    static int run(String[] args) {
        PrintStream stdout = new PrintStream(System.out, false, StandardCharsets.UTF_8);
        if (args.length == 0) {
            System.err.println("usage: polyquery (version|capabilities|session|exec|serve) [options]");
            return 2;
        }
        String mode = args[0];
        Map<String, String> opts;
        try {
            opts = parseOptions(args);
            if (!List.of("version", "capabilities", "session", "exec", "serve").contains(mode)) {
                throw new UsageException("unknown command '" + mode + "'");
            }
            switch (mode) {
                case "version" -> {
                    stdout.println(JsonWriter.write(withOk(Version.versionFields())));
                    stdout.flush();
                    return 0;
                }
                case "capabilities" -> {
                    stdout.println(JsonWriter.write(withOk(Version.capabilityFields())));
                    stdout.flush();
                    return 0;
                }
                default -> {
                }
            }
            Logger.Level level = Logger.parseLevel(opts.getOrDefault("--log-level", "info"));
            if (level == null) {
                throw new UsageException("invalid --log-level");
            }
            Logger log = new Logger(level, System.err);
            EngineConfig config = config(opts);
            if (!Files.isDirectory(config.dataDir())) {
                System.err.println("data directory does not exist: " + config.dataDir());
                return 1;
            }
            String nativePath = opts.get("--native-kernels");
            if (nativePath != null) {
                config = config.withNativeKernels(loadNativeKernels(nativePath, log));
            }
            if (mode.equals("serve")) {
                return serve(new Engine(config), serverConfig(opts), log, stdout);
            }
            RequestHandler handler = new RequestHandler(new Engine(config), log);
            if (mode.equals("session")) {
                return session(handler, stdout);
            }
            String request = opts.get("--request");
            if (request == null) {
                throw new UsageException("exec requires --request FILE");
            }
            return exec(handler, request, stdout);
        } catch (UsageException e) {
            System.err.println("polyquery: " + e.getMessage());
            return 2;
        }
    }

    /**
     * Loads the native kernel library; native kernels are optional, so a library that cannot be
     * loaded is logged and the engine runs on its own code paths (returns null).
     */
    private static NativeKernels loadNativeKernels(String path, Logger log) {
        try {
            NativeKernels kernels = NativeKernels.load(Path.of(path));
            Map<String, Object> fields = new LinkedHashMap<>();
            fields.put("path", path);
            fields.put("variant", kernels.variant());
            fields.put("available", kernels.availableVariants());
            log.log(Logger.Level.INFO, "native kernels loaded", fields);
            return kernels;
        } catch (NativeLoadException | java.nio.file.InvalidPathException e) {
            Map<String, Object> fields = new LinkedHashMap<>();
            fields.put("path", path);
            fields.put("error", String.valueOf(e.getMessage()));
            log.log(Logger.Level.WARN, "native kernels unavailable; using the engine's own code paths", fields);
            return null;
        }
    }

    private static Map<String, Object> withOk(Map<String, Object> fields) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("ok", true);
        m.putAll(fields);
        return m;
    }

    private static Map<String, String> parseOptions(String[] args) throws UsageException {
        Map<String, String> opts = new HashMap<>();
        for (int i = 1; i < args.length; i++) {
            String a = args[i];
            String value = null;
            int eq = a.indexOf('=');
            if (a.startsWith("--") && eq > 0) {
                value = a.substring(eq + 1);
                a = a.substring(0, eq);
            }
            if (FLAG_OPTIONS.contains(a)) {
                if (value != null) {
                    throw new UsageException("option " + a + " takes no value");
                }
                opts.put(a, "true");
            } else if (VALUE_OPTIONS.contains(a)) {
                if (value == null) {
                    if (i + 1 >= args.length) {
                        throw new UsageException("option " + a + " requires a value");
                    }
                    value = args[++i];
                }
                opts.put(a, value);
            } else {
                throw new UsageException("unknown option '" + args[i] + "'");
            }
        }
        return opts;
    }

    private static long longOpt(Map<String, String> opts, String name, long dflt, long min) throws UsageException {
        String v = opts.get(name);
        if (v == null) {
            return dflt;
        }
        try {
            long x = Long.parseLong(v.trim());
            if (x < min) {
                throw new UsageException("option " + name + " must be >= " + min);
            }
            return x;
        } catch (NumberFormatException e) {
            throw new UsageException("option " + name + " requires an integer");
        }
    }

    private static EngineConfig config(Map<String, String> opts) throws UsageException {
        Path dataDir = Path.of(opts.getOrDefault("--data-dir", ".")).toAbsolutePath().normalize();
        long memMb = longOpt(opts, "--max-query-memory-mb", EngineConfig.DEFAULT_QUERY_MEMORY_MB, 1);
        long memBytes = Math.min(memMb << 20, (long) (Runtime.getRuntime().maxMemory() * 0.7));
        return new EngineConfig(dataDir, opts.containsKey("--enable-test-functions"), memBytes,
                longOpt(opts, "--max-ingest-bytes", EngineConfig.DEFAULT_INGEST_BYTES, 0),
                longOpt(opts, "--max-table-rows", EngineConfig.DEFAULT_TABLE_ROWS, 0),
                longOpt(opts, "--max-join-rows", EngineConfig.DEFAULT_JOIN_ROWS, 0),
                (int) longOpt(opts, "--threads", Runtime.getRuntime().availableProcessors(), 1));
    }

    private static ServerConfig serverConfig(Map<String, String> opts) throws UsageException {
        if (!opts.containsKey("--port")) {
            throw new UsageException("serve requires --port N");
        }
        long port = longOpt(opts, "--port", 0, 0);
        if (port > 65535) {
            throw new UsageException("option --port must be <= 65535");
        }
        long workers = longOpt(opts, "--workers", Runtime.getRuntime().availableProcessors(), 1);
        long queueDepth = longOpt(opts, "--queue-depth", ServerConfig.DEFAULT_QUEUE_DEPTH, 0);
        return new ServerConfig(opts.getOrDefault("--host", "127.0.0.1"), (int) port,
                (int) Math.min(workers, 1 << 16), (int) Math.min(queueDepth, 1 << 20),
                longOpt(opts, "--query-timeout-ms", 0, 0),
                longOpt(opts, "--shutdown-grace-ms", ServerConfig.DEFAULT_SHUTDOWN_GRACE_MS, 0),
                longOpt(opts, "--max-request-bytes", ServerConfig.DEFAULT_MAX_REQUEST_BYTES, 0));
    }

    /** {@code serve}: runs the HTTP server until SIGTERM/SIGINT, then shuts down gracefully and exits 0. */
    private static int serve(Engine engine, ServerConfig serverConfig, Logger log, PrintStream out) {
        HttpServer server = new HttpServer(serverConfig, engine, log, STACK_SIZE);
        int port;
        try {
            port = server.start();
        } catch (IOException | IllegalArgumentException | SecurityException e) {
            log.error("cannot listen on " + serverConfig.host() + ":" + serverConfig.port() + ": " + e.getMessage());
            return 1;
        }
        // The JVM runs shutdown hooks on SIGTERM/SIGINT; halting from the hook makes the exit status 0.
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            server.shutdown();
            out.flush();
            System.err.flush();
            Runtime.getRuntime().halt(0);
        }, "polyquery-shutdown"));
        Map<String, Object> listening = new LinkedHashMap<>();
        listening.put("event", "listening");
        listening.put("host", serverConfig.host());
        listening.put("port", (long) port);
        writeLine(out, JsonWriter.write(listening));
        while (true) {
            try {
                Thread.sleep(Long.MAX_VALUE);
            } catch (InterruptedException e) {
                // keep serving until a signal triggers the shutdown hook
            }
        }
    }

    private static int session(RequestHandler handler, PrintStream out) {
        try (BufferedReader in = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8), 1 << 16)) {
            String line;
            while ((line = in.readLine()) != null) {
                if (line.isBlank()) {
                    continue;
                }
                writeLine(out, handler.handleLine(line));
            }
        } catch (IOException e) {
            System.err.println("polyquery: I/O error on stdin: " + e.getMessage());
            return 1;
        }
        return 0;
    }

    private static int exec(RequestHandler handler, String request, PrintStream out) {
        String text;
        try {
            byte[] bytes = request.equals("-") ? System.in.readAllBytes() : Files.readAllBytes(Path.of(request));
            text = new String(bytes, StandardCharsets.UTF_8);
        } catch (IOException e) {
            System.err.println("polyquery: cannot read request: " + e.getMessage());
            return 1;
        }
        Object parsed;
        try {
            parsed = JsonParser.parse(text);
        } catch (JsonException e) {
            writeLine(out, RequestHandler.error(null,
                    new PolyQueryException(ErrorCode.INVALID_REQUEST, "malformed JSON: " + e.getMessage())));
            return 0;
        }
        if (parsed instanceof List<?> list) {
            for (Object req : list) {
                writeLine(out, handler.handle(req));
            }
        } else {
            writeLine(out, handler.handle(parsed));
        }
        return 0;
    }

    private static void writeLine(PrintStream out, String line) {
        out.print(line);
        out.print('\n');
        out.flush();
    }
}
