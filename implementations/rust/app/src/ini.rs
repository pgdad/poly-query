//! The line syntax shared by the configuration, rules and budget files
//! (spec/apps/pqledger.md §3.2): blank lines, `#`/`;` comments, `[SECTION]`
//! headers and `KEY = VALUE` assignments with optional `"…"` quoting.

/// One meaningful line of a file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Line {
    /// `[NAME]`: the text between the brackets.
    Section(String),
    /// `KEY = VALUE`, both trimmed, the value unquoted.
    Assignment { key: String, value: String },
}

/// A line with its 1-based line number.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Numbered {
    pub number: usize,
    pub line: Line,
}

/// Trims spaces and tabs (only those) from both ends.
pub fn trim_blanks(s: &str) -> &str {
    s.trim_matches([' ', '\t'])
}

/// Splits a file's text into its meaningful lines. Errors name the line
/// number.
pub fn parse(text: &str) -> Result<Vec<Numbered>, String> {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let mut lines = Vec::new();
    for (index, raw) in text.split('\n').enumerate() {
        let number = index + 1;
        let raw = raw.strip_suffix('\r').unwrap_or(raw);
        let line = trim_blanks(raw);
        if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
            continue;
        }
        let parsed = if let Some(inner) = line.strip_prefix('[') {
            match inner.strip_suffix(']') {
                Some(name) => Line::Section(name.to_string()),
                None => return Err(format!("line {number}: malformed section header")),
            }
        } else if let Some((key, value)) = line.split_once('=') {
            Line::Assignment {
                key: trim_blanks(key).to_string(),
                value: unquote(trim_blanks(value)),
            }
        } else {
            return Err(format!("line {number}: expected 'KEY = VALUE'"));
        };
        lines.push(Numbered {
            number,
            line: parsed,
        });
    }
    Ok(lines)
}

/// Removes surrounding `"` (if the value is at least 2 characters long and
/// starts and ends with one), unescaping `\"` and `\\` inside.
fn unquote(value: &str) -> String {
    let Some(inner) = value
        .strip_prefix('"')
        .and_then(|v| v.strip_suffix('"'))
        .filter(|_| value.len() >= 2)
    else {
        return value.to_string();
    };
    let mut out = String::with_capacity(inner.len());
    let mut chars = inner.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\\'
            && let Some(&next) = chars.peek()
            && (next == '"' || next == '\\')
        {
            out.push(next);
            chars.next();
            continue;
        }
        out.push(c);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assignment(key: &str, value: &str) -> Line {
        Line::Assignment {
            key: key.into(),
            value: value.into(),
        }
    }

    #[test]
    fn parses_sections_assignments_and_comments() {
        let text = "\u{feff}# comment\r\n; other\n\n[ledger]\n  data_dir =  books \t\nx=a=b\n";
        let lines = parse(text).unwrap();
        assert_eq!(lines.len(), 3);
        assert_eq!(lines[0].line, Line::Section("ledger".into()));
        assert_eq!(lines[0].number, 4);
        assert_eq!(lines[1].line, assignment("data_dir", "books"));
        assert_eq!(lines[2].line, assignment("x", "a=b"));
    }

    #[test]
    fn quoted_values() {
        let lines = parse("a = \"  x \"\nb = \"\"\nc = \"q\\\"\\\\\"\nd = \"\n").unwrap();
        assert_eq!(lines[0].line, assignment("a", "  x "));
        assert_eq!(lines[1].line, assignment("b", ""));
        assert_eq!(lines[2].line, assignment("c", "q\"\\"));
        assert_eq!(lines[3].line, assignment("d", "\""));
    }

    #[test]
    fn malformed_lines_name_the_line() {
        assert_eq!(
            parse("[ledger]\njunk\n").unwrap_err(),
            "line 2: expected 'KEY = VALUE'"
        );
        assert!(parse("[ledger\n").unwrap_err().starts_with("line 1:"));
    }
}
