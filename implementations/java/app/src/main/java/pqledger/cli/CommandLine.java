package pqledger.cli;

import java.math.BigInteger;
import java.time.YearMonth;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;
import pqledger.AppException;
import pqledger.Names;
import pqledger.output.OutputFormat;

/** Parses and validates the command line (spec §2); every problem is a usage error. */
public final class CommandLine {
    /** An argument of this form is an option; anything else is a positional argument. */
    private static final Pattern OPTION = Pattern.compile("--[A-Za-z0-9][A-Za-z0-9_-]*");
    private static final Pattern DIGITS = Pattern.compile("[0-9]+");
    private static final long DEFAULT_TOP = 10;

    private CommandLine() {
    }

    public static Invocation parse(List<String> args) throws AppException {
        String configPath = null;
        OutputFormat format = null;
        int i = 0;
        // global options, only before the command
        while (i < args.size() && OPTION.matcher(args.get(i)).matches()) {
            String opt = args.get(i);
            switch (opt) {
                case "--help" -> {
                    if (i + 1 < args.size()) {
                        throw AppException.usage("unexpected argument after --help: '" + args.get(i + 1) + "'");
                    }
                    return simple(configPath, format, Command.HELP);
                }
                case "--config" -> {
                    if (configPath != null) {
                        throw AppException.usage("option --config given twice");
                    }
                    configPath = value(args, i, opt);
                    if (configPath.isEmpty()) {
                        throw AppException.usage("option --config needs a non-empty path");
                    }
                }
                case "--format" -> {
                    if (format != null) {
                        throw AppException.usage("option --format given twice");
                    }
                    String v = value(args, i, opt);
                    format = OutputFormat.fromName(v);
                    if (format == null) {
                        throw AppException.usage("invalid --format '" + v + "' (expected table, csv or json)");
                    }
                }
                default -> throw AppException.usage("unknown global option '" + opt + "'");
            }
            i += 2;
        }
        if (i >= args.size()) {
            throw AppException.usage("missing command (try 'pqledger help')");
        }
        String name = args.get(i++);
        Command command = switch (name) {
            case "init" -> Command.INIT;
            case "import" -> Command.IMPORT;
            case "report" -> report(args, i++);
            case "budget" -> Command.BUDGET;
            case "accounts" -> Command.ACCOUNTS;
            case "list" -> Command.LIST;
            case "export" -> Command.EXPORT;
            case "set-category" -> Command.SET_CATEGORY;
            case "query" -> Command.QUERY;
            case "help" -> Command.HELP;
            case "version" -> Command.VERSION;
            default -> throw AppException.usage("unknown command '" + name + "' (try 'pqledger help')");
        };
        return commandArguments(configPath, format, command, args.subList(i, args.size()));
    }

    private static Command report(List<String> args, int i) throws AppException {
        if (i >= args.size()) {
            throw AppException.usage("report needs a kind: monthly, categories or merchants");
        }
        return switch (args.get(i)) {
            case "monthly" -> Command.REPORT_MONTHLY;
            case "categories" -> Command.REPORT_CATEGORIES;
            case "merchants" -> Command.REPORT_MERCHANTS;
            default -> throw AppException.usage("unknown report '" + args.get(i)
                    + "' (expected monthly, categories or merchants)");
        };
    }

    private static String value(List<String> args, int i, String option) throws AppException {
        if (i + 1 >= args.size()) {
            throw AppException.usage("option " + option + " needs a value");
        }
        return args.get(i + 1);
    }

    private static Invocation simple(String configPath, OutputFormat format, Command command) {
        return new Invocation(configPath, format, command, Filters.NONE, null, null, DEFAULT_TOP, null, false, null,
                false, null);
    }

    private static Invocation commandArguments(String configPath, OutputFormat format, Command command,
                                               List<String> rest) throws AppException {
        Map<String, String> options = new HashMap<>();
        Set<String> flags = new HashSet<>();
        List<String> positionals = new ArrayList<>();
        for (int i = 0; i < rest.size(); i++) {
            String arg = rest.get(i);
            if (!OPTION.matcher(arg).matches()) {
                positionals.add(arg);
                continue;
            }
            if (options.containsKey(arg) || flags.contains(arg)) {
                throw AppException.usage("option " + arg + " given twice");
            }
            if (command.flags().contains(arg)) {
                flags.add(arg);
            } else if (command.valueOptions().contains(arg)) {
                options.put(arg, value(rest, i, arg));
                i++;
            } else {
                throw AppException.usage("unknown option '" + arg + "' for " + command.displayName());
            }
        }
        if (positionals.size() > command.maxPositionals()) {
            throw AppException.usage("unexpected argument '" + positionals.get(command.maxPositionals()) + "'");
        }
        if (positionals.size() < command.minPositionals()) {
            throw AppException.usage(command.displayName() + ": missing argument (try 'pqledger help')");
        }
        Filters filters = filters(command, options);
        String account = null;
        String file = null;
        long top = DEFAULT_TOP;
        String category = null;
        BigInteger id = null;
        String sql = null;
        switch (command) {
            case IMPORT -> {
                file = positionals.getFirst();
                account = requiredAccount(options);
                if (file.isEmpty()) {
                    throw AppException.usage("import needs a file name");
                }
            }
            case BUDGET -> {
                if (!options.containsKey("--month")) {
                    throw AppException.usage("budget needs --month YYYY-MM");
                }
            }
            case REPORT_MERCHANTS -> {
                String t = options.get("--top");
                if (t != null) {
                    top = positiveNumber(t, "--top");
                }
            }
            case LIST -> {
                category = options.get("--category");
                if (category != null && !category.matches("[a-z0-9_-]{1,32}")) {
                    throw AppException.usage("invalid category name '" + category + "'");
                }
                if (category != null && flags.contains("--uncategorized")) {
                    throw AppException.usage("--category and --uncategorized cannot be combined");
                }
            }
            case SET_CATEGORY -> {
                id = transactionId(positionals.getFirst());
                boolean clear = flags.contains("--clear");
                if (clear && positionals.size() != 1) {
                    throw AppException.usage("set-category ID --clear takes no category");
                }
                if (!clear) {
                    if (positionals.size() != 2) {
                        throw AppException.usage("set-category needs ID and CATEGORY (or --clear)");
                    }
                    category = positionals.get(1);
                    if (!Names.isCategory(category)) {
                        throw AppException.usage("invalid category name '" + category
                                + "' (expected [a-z0-9_-]{1,32}, not 'uncategorized')");
                    }
                }
            }
            case QUERY -> sql = positionals.getFirst();
            default -> {
            }
        }
        return new Invocation(configPath, format, command, filters, account, file, top, category,
                flags.contains("--uncategorized"), id, flags.contains("--clear"), sql);
    }

    private static Filters filters(Command command, Map<String, String> options) throws AppException {
        YearMonth month = month(options, "--month");
        YearMonth from = month(options, "--from");
        YearMonth to = month(options, "--to");
        if (month != null && (from != null || to != null)) {
            throw AppException.usage("--month cannot be combined with --from or --to");
        }
        if (from != null && to != null && from.isAfter(to)) {
            throw AppException.usage("--from " + from + " is later than --to " + to);
        }
        String account = options.get("--account");
        if (account != null && !Names.isAccount(account)) {
            throw AppException.usage("invalid account name '" + account + "' (expected [a-z0-9_-]{1,32})");
        }
        if (command == Command.IMPORT) {
            return Filters.NONE;
        }
        return new Filters(month != null ? MonthRange.of(month) : new MonthRange(from, to), account);
    }

    private static YearMonth month(Map<String, String> options, String option) throws AppException {
        String v = options.get(option);
        if (v == null) {
            return null;
        }
        YearMonth m = MonthRange.parseMonth(v);
        if (m == null) {
            throw AppException.usage("invalid " + option + " '" + v + "' (expected YYYY-MM)");
        }
        return m;
    }

    private static String requiredAccount(Map<String, String> options) throws AppException {
        String account = options.get("--account");
        if (account == null) {
            throw AppException.usage("import needs --account NAME");
        }
        return account;
    }

    private static long positiveNumber(String v, String option) throws AppException {
        if (!DIGITS.matcher(v).matches()) {
            throw AppException.usage("invalid " + option + " '" + v + "' (expected a positive integer)");
        }
        BigInteger n = new BigInteger(v);
        if (n.signum() <= 0) {
            throw AppException.usage("invalid " + option + " '" + v + "' (expected a positive integer)");
        }
        return n.bitLength() < 63 ? n.longValue() : Long.MAX_VALUE;
    }

    private static BigInteger transactionId(String v) throws AppException {
        if (!DIGITS.matcher(v).matches() || new BigInteger(v).signum() <= 0) {
            throw AppException.usage("invalid transaction id '" + v + "' (expected a positive integer)");
        }
        return new BigInteger(v);
    }
}
