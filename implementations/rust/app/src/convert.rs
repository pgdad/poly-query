//! Converting bank CSV records into transactions (spec/apps/pqledger.md
//! §6.2 step 3 and §6.3).

use polyquery::api::Date;

use crate::amount::{self, MAX_CENTS};
use crate::bankcsv::Record;
use crate::config::{AmountMode, ColumnRef, DateFormat, ImportSettings};
use crate::ini::trim_blanks;

/// A converted bank record.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    /// Physical line of the record in its file.
    pub line: usize,
    pub date: Date,
    pub description: String,
    pub merchant: String,
    pub cents: i64,
}

/// A record that cannot be converted: its line and the reason.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConvertError {
    pub line: usize,
    pub message: String,
}

/// Column positions (0-based) of the fields an import needs.
#[derive(Debug, Clone, Copy)]
struct Columns {
    date: usize,
    description: usize,
    amount: Amounts,
}

#[derive(Debug, Clone, Copy)]
enum Amounts {
    Signed(usize),
    DebitCredit { debit: usize, credit: usize },
}

/// Converts the records of a file (header first when configured).
pub fn convert(records: &[Record], s: &ImportSettings) -> Result<Vec<Entry>, ConvertError> {
    let Some(first) = records.first() else {
        if s.header {
            return Err(ConvertError {
                line: s.skip_lines + 1,
                message: "no header record (the file is empty)".into(),
            });
        }
        return Ok(Vec::new());
    };
    let width = first.fields.len();
    let (header, data) = if s.header {
        (Some(first), &records[1..])
    } else {
        (None, records)
    };
    let header_line = first.line;
    let resolve = |r: &ColumnRef| {
        resolve(r, header, width).map_err(|message| ConvertError {
            line: header_line,
            message,
        })
    };
    let columns = Columns {
        date: resolve(&s.date_column)?,
        description: resolve(&s.description_column)?,
        amount: match s.amount_mode {
            AmountMode::Signed => Amounts::Signed(resolve(&s.amount_column)?),
            AmountMode::DebitCredit => Amounts::DebitCredit {
                debit: resolve(&s.debit_column)?,
                credit: resolve(&s.credit_column)?,
            },
        },
    };
    data.iter()
        .map(|r| {
            if r.fields.len() != width {
                return Err(ConvertError {
                    line: r.line,
                    message: format!("{} fields, expected {width}", r.fields.len()),
                });
            }
            convert_record(r, columns, s).map_err(|message| ConvertError {
                line: r.line,
                message,
            })
        })
        .collect()
}

/// The 0-based position of a referenced column.
fn resolve(r: &ColumnRef, header: Option<&Record>, width: usize) -> Result<usize, String> {
    match r {
        ColumnRef::Position(n) if *n <= width => Ok(n - 1),
        ColumnRef::Position(n) => Err(format!(
            "column {n} is beyond the {width} columns of the file"
        )),
        ColumnRef::Name(name) => {
            let Some(header) = header else {
                return Err(format!(
                    "column '{name}' is a name but the file has no header (header = false)"
                ));
            };
            header
                .fields
                .iter()
                .position(|f| trim_blanks(f).eq_ignore_ascii_case(name))
                .ok_or_else(|| format!("the header has no column '{name}'"))
        }
    }
}

fn convert_record(r: &Record, c: Columns, s: &ImportSettings) -> Result<Entry, String> {
    let date_text = trim_blanks(&r.fields[c.date]);
    let date = parse_date(date_text, s.date_format)
        .ok_or_else(|| format!("invalid date '{date_text}'"))?;
    let description = trim_blanks(&r.fields[c.description]).to_string();
    let mut cents = match c.amount {
        Amounts::Signed(i) => amount::parse_field(&r.fields[i], s)?,
        Amounts::DebitCredit { debit, credit } => {
            let side = |i: usize| {
                let f = &r.fields[i];
                if trim_blanks(f).is_empty() {
                    Ok(None)
                } else {
                    amount::parse_field(f, s).map(Some)
                }
            };
            match (side(debit)?, side(credit)?) {
                (None, None) => return Err("both debit and credit are empty".into()),
                (d, c) => c.unwrap_or(0) - d.unwrap_or(0),
            }
        }
    };
    if s.invert_sign {
        cents = -cents;
    }
    if cents.abs() > MAX_CENTS {
        return Err("amount does not fit DECIMAL(18,2)".into());
    }
    let merchant = merchant(&description);
    Ok(Entry {
        line: r.line,
        date,
        description,
        merchant,
        cents,
    })
}

/// Parses a date in the configured format. In the `/` and `.` formats the
/// month and day may have 1 or 2 digits; the year always has 4.
pub fn parse_date(text: &str, format: DateFormat) -> Option<Date> {
    fn number(s: &str, min: usize, max: usize) -> Option<u32> {
        if s.len() < min || s.len() > max || !s.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        s.parse().ok()
    }
    let (y, m, d) = match format {
        DateFormat::Iso => {
            let mut parts = text.split('-');
            let (y, m, d) = (parts.next()?, parts.next()?, parts.next()?);
            if parts.next().is_some() {
                return None;
            }
            (number(y, 4, 4)?, number(m, 2, 2)?, number(d, 2, 2)?)
        }
        DateFormat::Compact => {
            if text.len() != 8 || !text.is_ascii() {
                return None;
            }
            (
                number(&text[0..4], 4, 4)?,
                number(&text[4..6], 2, 2)?,
                number(&text[6..8], 2, 2)?,
            )
        }
        DateFormat::MonthDayYear | DateFormat::DayMonthYear | DateFormat::Dotted => {
            let sep = if format == DateFormat::Dotted {
                '.'
            } else {
                '/'
            };
            let mut parts = text.split(sep);
            let (a, b, y) = (parts.next()?, parts.next()?, parts.next()?);
            if parts.next().is_some() {
                return None;
            }
            let (a, b, y) = (number(a, 1, 2)?, number(b, 1, 2)?, number(y, 4, 4)?);
            if format == DateFormat::MonthDayYear {
                (y, a, b)
            } else {
                (y, b, a)
            }
        }
    };
    Date::from_ymd(y as i32, m, d)
}

/// The normalized merchant of a description (§6.3): ASCII letters
/// upper-cased, runs of spaces and tabs collapsed to one space, trimmed;
/// then a trailing store-number token (`#` + digits, or 3+ digits) is
/// removed once, unless it is the only token.
pub fn merchant(description: &str) -> String {
    let mut out = String::with_capacity(description.len());
    let mut pending_space = false;
    for ch in description.chars() {
        if ch == ' ' || ch == '\t' {
            pending_space = !out.is_empty();
            continue;
        }
        if pending_space {
            out.push(' ');
            pending_space = false;
        }
        out.push(ch.to_ascii_uppercase());
    }
    if let Some(space) = out.rfind(' ') {
        let token = &out[space + 1..];
        let digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
        let store_number = match token.strip_prefix('#') {
            Some(rest) => digits(rest),
            None => token.len() >= 3 && digits(token),
        };
        if store_number {
            out.truncate(space);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bankcsv;

    #[test]
    fn merchants() {
        for (description, expected) in [
            ("Whole Foods Market #10234", "WHOLE FOODS MARKET"),
            ("SQ *Blue  Bottle 4421", "SQ *BLUE BOTTLE"),
            ("Rent 2026", "RENT"),
            ("7-Eleven 12", "7-ELEVEN 12"),
            ("#123", "#123"),
            ("Café\tMélange  #9", "CAFé MéLANGE"),
            ("Shop 12 345", "SHOP 12"),
            ("REI #", "REI #"),
            ("", ""),
            ("  a  ", "A"),
            ("Line\nbreak", "LINE\nBREAK"),
        ] {
            assert_eq!(merchant(description), expected, "{description:?}");
        }
    }

    #[test]
    fn dates() {
        let d = |t, f| parse_date(t, f).map(|d| d.to_string());
        assert_eq!(
            d("2026-01-05", DateFormat::Iso).as_deref(),
            Some("2026-01-05")
        );
        assert_eq!(d("2026-1-05", DateFormat::Iso), None);
        assert_eq!(d("2026-02-30", DateFormat::Iso), None);
        assert_eq!(
            d("20260105", DateFormat::Compact).as_deref(),
            Some("2026-01-05")
        );
        assert_eq!(
            d("1/5/2026", DateFormat::MonthDayYear).as_deref(),
            Some("2026-01-05")
        );
        assert_eq!(
            d("1/5/2026", DateFormat::DayMonthYear).as_deref(),
            Some("2026-05-01")
        );
        assert_eq!(
            d("31.12.2025", DateFormat::Dotted).as_deref(),
            Some("2025-12-31")
        );
        assert_eq!(d("31.12.25", DateFormat::Dotted), None);
        assert_eq!(d("29.02.2025", DateFormat::Dotted), None);
        assert_eq!(d("0000-01-01", DateFormat::Iso), None);
    }

    #[test]
    fn converts_debit_credit_records() {
        let s = ImportSettings {
            delimiter: b';',
            amount_mode: AmountMode::DebitCredit,
            date_format: DateFormat::Dotted,
            debit_column: ColumnRef::Name("soll".into()),
            credit_column: ColumnRef::Position(4),
            decimal_separator: ',',
            thousands_separator: Some('.'),
            date_column: ColumnRef::Name("Tag".into()),
            description_column: ColumnRef::Name("Text".into()),
            ..ImportSettings::default()
        };
        let text = "Tag;Text;Soll;Haben\n01.01.2026;Miete;1.120,00;\n02.01.2026; Gehalt ;;3.810,55\n03.01.2026;x;;\n";
        let records = bankcsv::parse(text, b';', 0).unwrap();
        let err = convert(&records, &s).unwrap_err();
        assert_eq!(err.line, 4);
        let entries = convert(&records[..3], &s).unwrap();
        assert_eq!(entries[0].cents, -112_000);
        assert_eq!(entries[1].cents, 381_055);
        assert_eq!(entries[1].description, "Gehalt");
        assert_eq!(entries[1].line, 3);
    }

    #[test]
    fn missing_columns_and_field_counts() {
        let s = ImportSettings::default();
        let records = bankcsv::parse("Day,Description,Amount\n2026-01-05,x,1\n", b',', 0).unwrap();
        assert_eq!(convert(&records, &s).unwrap_err().line, 1);
        let records =
            bankcsv::parse("Date,Description,Amount\n2026-01-05,x,1,2\n", b',', 0).unwrap();
        assert_eq!(convert(&records, &s).unwrap_err().line, 2);
        let s = ImportSettings {
            header: false,
            date_column: ColumnRef::Position(1),
            description_column: ColumnRef::Position(2),
            amount_column: ColumnRef::Position(3),
            invert_sign: true,
            ..ImportSettings::default()
        };
        let records = bankcsv::parse("2026-01-05,x,1.5\n", b',', 0).unwrap();
        assert_eq!(convert(&records, &s).unwrap()[0].cents, -150);
        assert!(convert(&[], &s).unwrap().is_empty());
        assert_eq!(
            convert(&[], &ImportSettings::default()).unwrap_err().line,
            1
        );
    }
}
