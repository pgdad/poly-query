package pqledger.config;

import java.nio.file.InvalidPathException;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;
import pqledger.AppException;
import pqledger.Names;
import pqledger.output.OutputFormat;

/** Locates and parses the configuration file (spec §3.1–§3.3). */
public final class ConfigLoader {
    /** The environment variable naming the configuration file. */
    public static final String ENV_VAR = "PQLEDGER_CONFIG";
    /** The configuration file looked for in the current directory. */
    public static final String DEFAULT_FILE = "pqledger.conf";

    private static final Set<String> LEDGER_KEYS = Set.of("data_dir", "rules_file", "budget_file");
    private static final Pattern POSITIVE = Pattern.compile("0*[1-9][0-9]*");

    private ConfigLoader() {
    }

    /**
     * The configuration file to use: {@code --config}, else {@code $PQLEDGER_CONFIG} (if
     * non-empty), else {@code ./pqledger.conf}; relative paths are resolved against {@code cwd}.
     */
    public static Path locate(String configOption, Map<String, String> env, Path cwd) throws AppException {
        String chosen = configOption;
        if (chosen == null) {
            String fromEnv = env.get(ENV_VAR);
            chosen = fromEnv != null && !fromEnv.isEmpty() ? fromEnv : DEFAULT_FILE;
        }
        return resolve(cwd, chosen, "configuration file path");
    }

    private static Path resolve(Path base, String path, String what) throws AppException {
        try {
            return base.resolve(path).toAbsolutePath().normalize();
        } catch (InvalidPathException e) {
            throw AppException.config("invalid " + what + " '" + path + "'");
        }
    }

    /** Reads and validates the configuration file {@code file}. */
    public static Config load(Path file) throws AppException {
        String name = file.toString();
        List<LineSyntax.Line> lines = LineSyntax.parse(LineSyntax.read(file, "configuration file"), name);
        Map<String, Map<String, String>> sections = new LinkedHashMap<>();
        Map<String, Integer> sectionLines = new HashMap<>();
        Map<String, String> current = null;
        String currentName = null;
        for (LineSyntax.Line line : lines) {
            switch (line) {
                case LineSyntax.Section s -> {
                    checkSectionName(s, name);
                    if (sections.containsKey(s.name())) {
                        throw LineSyntax.error(name, s.number(), "section [" + s.name() + "] repeated (first on line "
                                + sectionLines.get(s.name()) + ")");
                    }
                    current = new LinkedHashMap<>();
                    currentName = s.name();
                    sections.put(s.name(), current);
                    sectionLines.put(s.name(), s.number());
                }
                case LineSyntax.Assignment a -> {
                    if (current == null) {
                        throw LineSyntax.error(name, a.number(), "assignment before the first section header");
                    }
                    if (current.containsKey(a.key())) {
                        throw LineSyntax.error(name, a.number(), "key '" + a.key() + "' repeated in section ["
                                + currentName + "]");
                    }
                    checkKey(currentName, a, name);
                    current.put(a.key(), a.value());
                }
            }
        }
        return build(file, sections, lineNumbers(lines, sectionLines));
    }

    /** Line of each (section, key) for error messages. */
    private static Map<String, Integer> lineNumbers(List<LineSyntax.Line> lines, Map<String, Integer> sectionLines) {
        Map<String, Integer> out = new HashMap<>();
        String section = null;
        for (LineSyntax.Line line : lines) {
            if (line instanceof LineSyntax.Section s) {
                section = s.name();
            } else if (line instanceof LineSyntax.Assignment a) {
                out.put(section + "\0" + a.key(), a.number());
            }
        }
        sectionLines.forEach((s, n) -> out.put(s, n));
        return out;
    }

    private static void checkSectionName(LineSyntax.Section s, String file) throws AppException {
        String n = s.name();
        if (n.equals("ledger") || n.equals("import") || n.equals("output") || n.equals("engine")) {
            return;
        }
        if (n.startsWith("account ")) {
            String account = n.substring("account ".length());
            if (!Names.isAccount(account)) {
                throw LineSyntax.error(file, s.number(), "invalid account name '" + account
                        + "' (expected [a-z0-9_-]{1,32})");
            }
            return;
        }
        throw LineSyntax.error(file, s.number(), "unknown section [" + n + "]");
    }

    private static void checkKey(String section, LineSyntax.Assignment a, String file) throws AppException {
        boolean known = switch (section) {
            case "ledger" -> LEDGER_KEYS.contains(a.key());
            case "output" -> a.key().equals("format");
            case "engine" -> a.key().equals("threads") || a.key().equals("memory_mb");
            default -> ImportSettings.KEYS.contains(a.key());
        };
        if (!known) {
            throw LineSyntax.error(file, a.number(), "unknown key '" + a.key() + "' in section [" + section + "]");
        }
    }

    private static Config build(Path file, Map<String, Map<String, String>> sections, Map<String, Integer> lines)
            throws AppException {
        String name = file.toString();
        Path dir = file.getParent();
        Map<String, String> ledger = sections.get("ledger");
        if (ledger == null) {
            throw AppException.config(name + ": missing [ledger] section");
        }
        String dataDir = ledger.get("data_dir");
        if (dataDir == null) {
            throw LineSyntax.error(name, lines.get("ledger"), "[ledger] needs data_dir");
        }
        Path data = path(dir, ledger, "data_dir", name, lines);
        Path rules = ledger.containsKey("rules_file") ? path(dir, ledger, "rules_file", name, lines) : null;
        Path budget = ledger.containsKey("budget_file") ? path(dir, ledger, "budget_file", name, lines) : null;

        ImportSettings defaults = apply(ImportSettings.DEFAULTS, "import", sections, name, lines);
        Map<String, ImportSettings> accounts = new HashMap<>();
        for (String section : sections.keySet()) {
            if (section.startsWith("account ")) {
                accounts.put(section.substring("account ".length()), apply(defaults, section, sections, name, lines));
            }
        }

        OutputFormat format = OutputFormat.TABLE;
        Map<String, String> output = sections.getOrDefault("output", Map.of());
        if (output.containsKey("format")) {
            format = OutputFormat.fromName(output.get("format"));
            if (format == null) {
                throw LineSyntax.error(name, lines.get("output\0format"), "format must be table, csv or json, got '"
                        + output.get("format") + "'");
            }
        }
        Map<String, String> engine = sections.getOrDefault("engine", Map.of());
        Integer threads = null;
        Long memoryMb = null;
        if (engine.containsKey("threads")) {
            threads = (int) Math.min(positive(engine, "threads", name, lines), 1024);
        }
        if (engine.containsKey("memory_mb")) {
            memoryMb = positive(engine, "memory_mb", name, lines);
        }
        return new Config(file, data, rules, budget, defaults, accounts, format, threads, memoryMb);
    }

    private static Path path(Path dir, Map<String, String> section, String key, String file,
                             Map<String, Integer> lines) throws AppException {
        String v = section.get(key);
        if (v.isEmpty()) {
            throw LineSyntax.error(file, lines.get("ledger\0" + key), key + " must not be empty");
        }
        return resolve(dir, v, key);
    }

    private static long positive(Map<String, String> section, String key, String file, Map<String, Integer> lines)
            throws AppException {
        String v = section.get(key);
        if (!POSITIVE.matcher(v).matches()) {
            throw LineSyntax.error(file, lines.get("engine\0" + key), key + " must be an integer >= 1, got '" + v
                    + "'");
        }
        String digits = v.replaceFirst("^0+", "");
        return digits.length() > 18 ? Long.MAX_VALUE : Long.parseLong(digits);
    }

    /** Applies the keys of {@code section} (if present) on top of {@code base} and validates the result. */
    private static ImportSettings apply(ImportSettings base, String section, Map<String, Map<String, String>> sections,
                                        String file, Map<String, Integer> lines) throws AppException {
        ImportSettings s = base;
        for (Map.Entry<String, String> e : sections.getOrDefault(section, Map.of()).entrySet()) {
            try {
                s = s.with(e.getKey(), e.getValue());
            } catch (IllegalArgumentException ex) {
                throw LineSyntax.error(file, lines.get(section + "\0" + e.getKey()), ex.getMessage());
            }
        }
        try {
            s.validate();
        } catch (IllegalArgumentException ex) {
            Integer line = lines.get(section);
            throw line == null ? AppException.config(file + ": " + ex.getMessage())
                    : LineSyntax.error(file, line, "[" + section + "]: " + ex.getMessage());
        }
        return s;
    }
}
