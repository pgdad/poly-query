package pqledger.config;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import pqledger.AppException;
import pqledger.Names;

/** Reads the category rules file (spec §5.1). */
public final class RulesFile {
    private RulesFile() {
    }

    /** The rules of {@code file}, or none if {@code file} is null. */
    public static List<Rule> load(Path file) throws AppException {
        if (file == null) {
            return List.of();
        }
        return parse(LineSyntax.read(file, "rules file"), file.toString());
    }

    public static List<Rule> parse(String text, String file) throws AppException {
        List<Rule> rules = new ArrayList<>();
        for (LineSyntax.Line line : LineSyntax.parse(text, file)) {
            if (!(line instanceof LineSyntax.Assignment a)) {
                throw LineSyntax.error(file, line.number(), "sections are not allowed in a rules file");
            }
            if (!Names.isCategory(a.key())) {
                throw LineSyntax.error(file, a.number(), "invalid category name '" + a.key()
                        + "' (expected [a-z0-9_-]{1,32}, not 'uncategorized')");
            }
            for (String part : a.value().split(",", -1)) {
                String pattern = LineSyntax.trim(part);
                if (pattern.isEmpty()) {
                    throw LineSyntax.error(file, a.number(), "empty pattern");
                }
                if (pattern.indexOf('%') >= 0 || pattern.indexOf('_') >= 0) {
                    throw LineSyntax.error(file, a.number(), "pattern '" + pattern + "' contains '%' or '_'");
                }
                rules.add(new Rule(rules.size() + 1, a.key(), asciiUpper(pattern)));
            }
        }
        return rules;
    }

    /** Upper-cases ASCII letters only. */
    public static String asciiUpper(String s) {
        StringBuilder sb = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            sb.append(c >= 'a' && c <= 'z' ? (char) (c - ('a' - 'A')) : c);
        }
        return sb.toString();
    }
}
