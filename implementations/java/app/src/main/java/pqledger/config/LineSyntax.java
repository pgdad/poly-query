package pqledger.config;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import pqledger.AppException;

/**
 * The line syntax shared by the configuration, rules and budget files (spec §3.2): blank lines,
 * comments, section headers and {@code KEY = VALUE} assignments.
 */
public final class LineSyntax {
    /** A non-blank, non-comment line. */
    public sealed interface Line permits Section, Assignment {
        int number();
    }

    /** {@code [NAME]}; {@code name} is the text between the brackets. */
    public record Section(int number, String name) implements Line {
    }

    /** {@code KEY = VALUE} with the key trimmed and the value trimmed and unquoted. */
    public record Assignment(int number, String key, String value) implements Line {
    }

    private LineSyntax() {
    }

    /** Reads {@code path} as UTF-8; a missing, unreadable or non-UTF-8 file is a configuration error. */
    public static String read(Path path, String what) throws AppException {
        byte[] bytes;
        try {
            bytes = Files.readAllBytes(path);
        } catch (IOException | SecurityException e) {
            throw AppException.config("cannot read " + what + " " + path + ": " + reason(e));
        }
        try {
            String text = StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes)).toString();
            return text.startsWith("﻿") ? text.substring(1) : text;
        } catch (CharacterCodingException e) {
            throw AppException.config(what + " " + path + " is not valid UTF-8");
        }
    }

    static String reason(Exception e) {
        return e instanceof java.nio.file.NoSuchFileException ? "no such file"
                : e instanceof java.nio.file.AccessDeniedException ? "permission denied"
                : String.valueOf(e.getMessage());
    }

    /**
     * Splits {@code text} into lines. {@code file} prefixes error messages
     * ({@code FILE:LINE: …}).
     */
    public static List<Line> parse(String text, String file) throws AppException {
        List<Line> out = new ArrayList<>();
        String[] lines = text.split("\n", -1);
        for (int i = 0; i < lines.length; i++) {
            int number = i + 1;
            String line = lines[i].endsWith("\r") ? lines[i].substring(0, lines[i].length() - 1) : lines[i];
            String t = trim(line);
            if (t.isEmpty() || t.startsWith("#") || t.startsWith(";")) {
                continue;
            }
            if (t.startsWith("[") && t.endsWith("]")) {
                out.add(new Section(number, t.substring(1, t.length() - 1)));
                continue;
            }
            int eq = t.indexOf('=');
            if (eq < 0) {
                throw error(file, number, "expected KEY = VALUE, a [section] or a comment");
            }
            String key = trim(t.substring(0, eq));
            if (key.isEmpty()) {
                throw error(file, number, "missing key before '='");
            }
            out.add(new Assignment(number, key, unquote(trim(t.substring(eq + 1)))));
        }
        return out;
    }

    /** Removes surrounding double quotes, resolving {@code \"} and {@code \\} inside them. */
    static String unquote(String v) {
        if (v.length() < 2 || !v.startsWith("\"") || !v.endsWith("\"")) {
            return v;
        }
        String inner = v.substring(1, v.length() - 1);
        StringBuilder sb = new StringBuilder(inner.length());
        for (int i = 0; i < inner.length(); i++) {
            char c = inner.charAt(i);
            if (c == '\\' && i + 1 < inner.length() && (inner.charAt(i + 1) == '"' || inner.charAt(i + 1) == '\\')) {
                sb.append(inner.charAt(++i));
            } else {
                sb.append(c);
            }
        }
        return sb.toString();
    }

    /** Removes leading and trailing spaces and tabs. */
    public static String trim(String s) {
        int start = 0;
        int end = s.length();
        while (start < end && (s.charAt(start) == ' ' || s.charAt(start) == '\t')) {
            start++;
        }
        while (end > start && (s.charAt(end - 1) == ' ' || s.charAt(end - 1) == '\t')) {
            end--;
        }
        return s.substring(start, end);
    }

    public static AppException error(String file, int line, String message) {
        return AppException.config(file + ":" + line + ": " + message);
    }
}
