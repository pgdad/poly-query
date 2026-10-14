package pqledger.config;

import java.math.BigDecimal;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;
import pqledger.AppException;
import pqledger.Names;

/** Reads the budget file (spec §5.2). */
public final class BudgetFile {
    private static final Pattern AMOUNT = Pattern.compile("[0-9]{1,16}(\\.[0-9]{1,2})?");

    private BudgetFile() {
    }

    public static List<Budget> load(Path file) throws AppException {
        return parse(LineSyntax.read(file, "budget file"), file.toString());
    }

    public static List<Budget> parse(String text, String file) throws AppException {
        List<Budget> budgets = new ArrayList<>();
        Map<String, Integer> seen = new HashMap<>();
        for (LineSyntax.Line line : LineSyntax.parse(text, file)) {
            if (!(line instanceof LineSyntax.Assignment a)) {
                throw LineSyntax.error(file, line.number(), "sections are not allowed in a budget file");
            }
            if (!Names.isCategory(a.key())) {
                throw LineSyntax.error(file, a.number(), "invalid category name '" + a.key()
                        + "' (expected [a-z0-9_-]{1,32}, not 'uncategorized')");
            }
            Integer first = seen.putIfAbsent(a.key(), a.number());
            if (first != null) {
                throw LineSyntax.error(file, a.number(), "category '" + a.key() + "' already has a budget (line "
                        + first + ")");
            }
            if (!AMOUNT.matcher(a.value()).matches()) {
                throw LineSyntax.error(file, a.number(), "invalid amount '" + a.value()
                        + "' (expected digits with up to 2 decimals, at most 16 integer digits)");
            }
            budgets.add(new Budget(a.key(), new BigDecimal(a.value()).setScale(2)));
        }
        return budgets;
    }
}
