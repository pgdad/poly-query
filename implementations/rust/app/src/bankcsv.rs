//! Reading bank-statement CSV exports (spec/apps/pqledger.md §6.2 steps 1–2):
//! RFC 4180 records that remember the physical line they start on.

/// One CSV record.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Record {
    /// 1-based physical line of the file on which the record starts.
    pub line: usize,
    pub fields: Vec<String>,
}

/// A malformed file: the line and what is wrong.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CsvError {
    pub line: usize,
    pub message: String,
}

/// Splits `text` into records: a leading BOM is ignored, the first
/// `skip_lines` physical lines are skipped, `\n` and `\r\n` end records,
/// empty lines are ignored, `"` quotes fields (`""` inside is a quote).
pub fn parse(text: &str, delimiter: u8, skip_lines: usize) -> Result<Vec<Record>, CsvError> {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let bytes = text.as_bytes();
    let mut pos = 0;
    let mut line = 1;
    while line <= skip_lines && pos < bytes.len() {
        match bytes[pos..].iter().position(|&b| b == b'\n') {
            Some(n) => pos += n + 1,
            None => pos = bytes.len(),
        }
        line += 1;
    }

    let mut records = Vec::new();
    while pos < bytes.len() {
        // Empty lines (zero characters before the terminator).
        if bytes[pos] == b'\n' {
            pos += 1;
            line += 1;
            continue;
        }
        if bytes[pos] == b'\r' && bytes.get(pos + 1) == Some(&b'\n') {
            pos += 2;
            line += 1;
            continue;
        }
        let start_line = line;
        let mut fields = Vec::new();
        let mut field: Vec<u8> = Vec::new();
        loop {
            // At the start of a field.
            if bytes.get(pos) == Some(&b'"') {
                pos += 1;
                loop {
                    match bytes.get(pos) {
                        None => {
                            return Err(CsvError {
                                line: start_line,
                                message: "unterminated quoted field".into(),
                            });
                        }
                        Some(b'"') if bytes.get(pos + 1) == Some(&b'"') => {
                            field.push(b'"');
                            pos += 2;
                        }
                        Some(b'"') => {
                            pos += 1;
                            break;
                        }
                        Some(&b) => {
                            if b == b'\n' {
                                line += 1;
                            }
                            field.push(b);
                            pos += 1;
                        }
                    }
                }
                match bytes.get(pos) {
                    None | Some(b'\n') => {}
                    Some(b'\r') if matches!(bytes.get(pos + 1), None | Some(b'\n')) => {}
                    Some(&b) if b == delimiter => {}
                    Some(_) => {
                        return Err(CsvError {
                            line,
                            message: "unexpected character after a closing quote".into(),
                        });
                    }
                }
            } else {
                while let Some(&b) = bytes.get(pos) {
                    if b == delimiter || b == b'\n' {
                        break;
                    }
                    if b == b'\r' && matches!(bytes.get(pos + 1), None | Some(b'\n')) {
                        break;
                    }
                    field.push(b);
                    pos += 1;
                }
            }
            // The input is valid UTF-8 and fields split at ASCII bytes.
            fields.push(String::from_utf8(std::mem::take(&mut field)).expect("UTF-8 field"));
            match bytes.get(pos) {
                Some(&b) if b == delimiter => pos += 1,
                Some(b'\r') => {
                    pos += if bytes.get(pos + 1) == Some(&b'\n') {
                        2
                    } else {
                        1
                    };
                    line += 1;
                    break;
                }
                Some(b'\n') => {
                    pos += 1;
                    line += 1;
                    break;
                }
                _ => break,
            }
        }
        records.push(Record {
            line: start_line,
            fields,
        });
    }
    Ok(records)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fields(records: &[Record]) -> Vec<(usize, Vec<&str>)> {
        records
            .iter()
            .map(|r| (r.line, r.fields.iter().map(String::as_str).collect()))
            .collect()
    }

    #[test]
    fn records_and_lines() {
        let text = "\u{feff}a,b\n1,\"x, y\"\n\n\"multi\nline\",\"q\"\"\"\r\n3,\r\n";
        let r = parse(text, b',', 0).unwrap();
        assert_eq!(
            fields(&r),
            [
                (1, vec!["a", "b"]),
                (2, vec!["1", "x, y"]),
                (4, vec!["multi\nline", "q\""]),
                (6, vec!["3", ""])
            ]
        );
    }

    #[test]
    fn preamble_and_delimiter() {
        let text = "Konto;;\r\nZeitraum\r\nTag;Betrag\r\n01.01.2026;1,00\r\n";
        let r = parse(text, b';', 2).unwrap();
        assert_eq!(
            fields(&r),
            [(3, vec!["Tag", "Betrag"]), (4, vec!["01.01.2026", "1,00"])]
        );
        assert!(parse("a\n", b',', 5).unwrap().is_empty());
    }

    #[test]
    fn no_final_terminator_and_tabs() {
        let r = parse("a\tb\n1\t2", b'\t', 0).unwrap();
        assert_eq!(fields(&r), [(1, vec!["a", "b"]), (2, vec!["1", "2"])]);
    }

    #[test]
    fn malformed() {
        assert_eq!(parse("a\n\"open\n", b',', 0).unwrap_err().line, 2);
        assert_eq!(parse("a\n\"x\"y\n", b',', 0).unwrap_err().line, 2);
    }
}
