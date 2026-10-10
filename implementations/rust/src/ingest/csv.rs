//! CSV reader (RFC 4180 with the specifics of ingestion.md §1).

use std::borrow::Cow;

use super::{
    IngestOptions, MAX_FIELD_BYTES, TextInference, at_record, check_row_limit, convert_text,
    validate_names,
};
use crate::error::{Error, Result};
use crate::storage::{ColumnBuilder, Field, Table};
use crate::types::{DataType, Value};

/// One raw CSV field.
#[derive(Debug, Clone, PartialEq)]
pub struct RawField<'a> {
    pub text: Cow<'a, str>,
    pub quoted: bool,
}

/// Splits CSV text into records of raw fields. Completely empty lines are
/// skipped; a leading UTF-8 BOM is ignored.
pub fn parse_records(text: &str, delimiter: u8) -> Result<Vec<Vec<RawField<'_>>>> {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let b = text.as_bytes();
    let n = b.len();
    let mut pos = 0;
    let mut records = Vec::new();
    while pos < n {
        if b[pos] == b'\n' {
            pos += 1;
            continue;
        }
        if b[pos] == b'\r' && (pos + 1 == n || b[pos + 1] == b'\n') {
            pos += if pos + 1 == n { 1 } else { 2 };
            continue;
        }
        let record_no = records.len() + 1;
        let mut record = Vec::new();
        loop {
            // One field starting at `pos`.
            let field = if pos < n && b[pos] == b'"' {
                pos += 1;
                let mut owned: Option<String> = None;
                let mut seg_start = pos;
                loop {
                    let Some(off) = b[pos..].iter().position(|&c| c == b'"') else {
                        return Err(Error::ingest(format!(
                            "record {record_no}: unterminated quoted field"
                        )));
                    };
                    let q = pos + off;
                    if q + 1 < n && b[q + 1] == b'"' {
                        owned
                            .get_or_insert_with(String::new)
                            .push_str(&text[seg_start..=q]);
                        pos = q + 2;
                        seg_start = pos;
                        continue;
                    }
                    let value = match owned {
                        Some(mut s) => {
                            s.push_str(&text[seg_start..q]);
                            Cow::Owned(s)
                        }
                        None => Cow::Borrowed(&text[seg_start..q]),
                    };
                    pos = q + 1;
                    break RawField {
                        text: value,
                        quoted: true,
                    };
                }
            } else {
                let start = pos;
                while pos < n && b[pos] != delimiter && b[pos] != b'\n' {
                    pos += 1;
                }
                let mut end = pos;
                if end > start && b[end - 1] == b'\r' && (pos == n || b[pos] == b'\n') {
                    end -= 1;
                }
                RawField {
                    text: Cow::Borrowed(&text[start..end]),
                    quoted: false,
                }
            };
            if field.text.len() > MAX_FIELD_BYTES {
                return Err(Error::ingest(format!(
                    "record {record_no}: field exceeds 16 MiB"
                )));
            }
            record.push(field);
            if pos >= n {
                break;
            }
            match b[pos] {
                c if c == delimiter => pos += 1,
                b'\n' => {
                    pos += 1;
                    break;
                }
                b'\r' if pos + 1 == n || b[pos + 1] == b'\n' => {
                    pos += if pos + 1 == n { 1 } else { 2 };
                    break;
                }
                _ => {
                    return Err(Error::ingest(format!(
                        "record {record_no}: unexpected character after closing quote"
                    )));
                }
            }
            // A delimiter at the very end of input starts an empty field,
            // which the next iteration produces.
        }
        records.push(record);
    }
    Ok(records)
}

fn is_blank(c: char) -> bool {
    c == ' ' || c == '\t'
}

/// Loads CSV text into a table.
pub fn load(name: &str, text: &str, opts: &IngestOptions) -> Result<Table> {
    let mut records = parse_records(text, opts.delimiter)?.into_iter();

    // Determine column names and (optionally) declared types.
    let (names, declared): (Vec<String>, Option<Vec<DataType>>) = match (&opts.schema, opts.header)
    {
        (Some(schema), header) => {
            if header {
                let Some(head) = records.next() else {
                    return Err(Error::ingest("missing header record"));
                };
                if head.len() != schema.len()
                    || head
                        .iter()
                        .zip(schema)
                        .any(|(h, f)| !h.text.eq_ignore_ascii_case(&f.name))
                {
                    return Err(Error::ingest(
                        "CSV header does not match the explicit schema",
                    ));
                }
            }
            (
                schema.iter().map(|f| f.name.clone()).collect(),
                Some(schema.iter().map(|f| f.data_type).collect()),
            )
        }
        (None, true) => {
            let Some(head) = records.next() else {
                return Err(Error::ingest("missing header record"));
            };
            let names: Vec<String> = head.into_iter().map(|f| f.text.into_owned()).collect();
            validate_names(names.iter().map(|s| s.as_str()))?;
            (names, None)
        }
        (None, false) => {
            return Err(Error::invalid_request(
                "header=false requires an explicit schema",
            ));
        }
    };
    let ncols = names.len();
    let first_data_record = if opts.header { 2 } else { 1 };

    // Column-major raw fields.
    let mut cols: Vec<Vec<RawField<'_>>> = (0..ncols).map(|_| Vec::new()).collect();
    let mut nrows = 0;
    for (i, rec) in records.enumerate() {
        if rec.len() != ncols {
            return Err(Error::ingest(format!(
                "record {}: expected {ncols} fields, found {}",
                i + first_data_record,
                rec.len()
            )));
        }
        for (c, f) in rec.into_iter().enumerate() {
            cols[c].push(f);
        }
        nrows += 1;
        check_row_limit(nrows, opts.max_rows)?;
    }

    let mut fields = Vec::with_capacity(ncols);
    let mut columns = Vec::with_capacity(ncols);
    for (c, raw) in cols.into_iter().enumerate() {
        let ty = match &declared {
            Some(types) => types[c],
            None => {
                // Whitespace-only fields are empty for the non-string
                // candidates; if nothing remains the column is STRING.
                let mut inf = TextInference::default();
                for f in &raw {
                    let t = f.text.trim_matches(is_blank);
                    if !t.is_empty() {
                        inf.observe(t);
                    }
                }
                inf.result()
            }
        };
        let mut builder = ColumnBuilder::new(ty);
        for (r, f) in raw.iter().enumerate() {
            if ty == DataType::String {
                // Unquoted empty is NULL; quoted empty is ''; text is kept raw.
                if f.text.is_empty() && !f.quoted {
                    builder.push_null();
                } else {
                    builder.push(Value::str(&f.text));
                }
                continue;
            }
            let t = f.text.trim_matches(is_blank);
            if t.is_empty() {
                builder.push_null();
                continue;
            }
            let v =
                convert_text(t, ty).map_err(|e| at_record(e, r + first_data_record, &names[c]))?;
            builder.push(v);
        }
        fields.push(Field::new(names[c].clone(), ty.result_type()));
        columns.push(builder.finish());
    }
    Ok(Table::new(name, fields, columns, nrows))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ErrorCode;

    fn texts(recs: &[Vec<RawField<'_>>]) -> Vec<Vec<String>> {
        recs.iter()
            .map(|r| r.iter().map(|f| f.text.to_string()).collect())
            .collect()
    }

    #[test]
    fn quoting_and_terminators() {
        let recs =
            parse_records("a,b\r\n\"x,\"\"y\"\"\",\"multi\nline\"\r\n\n,\"\"\n", b',').unwrap();
        assert_eq!(
            texts(&recs),
            vec![vec!["a", "b"], vec!["x,\"y\"", "multi\nline"], vec!["", ""]]
        );
        assert!(!recs[2][0].quoted && recs[2][1].quoted);
    }

    #[test]
    fn bom_and_no_final_newline() {
        let recs = parse_records("\u{feff}x,y\n1,2", b',').unwrap();
        assert_eq!(texts(&recs), vec![vec!["x", "y"], vec!["1", "2"]]);
    }

    #[test]
    fn trailing_delimiter_means_empty_field() {
        let recs = parse_records("a,b\n1,", b',').unwrap();
        assert_eq!(texts(&recs)[1], vec!["1", ""]);
    }

    #[test]
    fn bad_quotes() {
        assert_eq!(
            parse_records("a\n\"abc", b',').unwrap_err().code,
            ErrorCode::IngestError
        );
        assert_eq!(
            parse_records("a\n\"abc\"x", b',').unwrap_err().code,
            ErrorCode::IngestError
        );
    }

    #[test]
    fn load_with_inference() {
        let t = load(
            "t",
            "n,s,d\n1, x ,2024-01-01\n\"\",\"\",\n",
            &IngestOptions::default(),
        )
        .unwrap();
        assert_eq!(t.row_count, 2);
        assert_eq!(t.fields[0].data_type, DataType::Int64);
        assert_eq!(t.fields[1].data_type, DataType::String);
        assert_eq!(t.fields[2].data_type, DataType::Date);
        assert!(t.value(1, 0).unwrap().is_null());
        assert_eq!(t.value(0, 1).unwrap(), Value::str(" x "));
        assert_eq!(t.value(1, 1).unwrap(), Value::str(""));
    }

    #[test]
    fn arity_errors() {
        let e = load("t", "a,b\n1,2\n3\n", &IngestOptions::default()).unwrap_err();
        assert_eq!(e.code, ErrorCode::IngestError);
        let e = load("t", "a,a\n1,2\n", &IngestOptions::default()).unwrap_err();
        assert_eq!(e.code, ErrorCode::IngestError);
    }
}
