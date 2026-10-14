//! Printing results as `table`, `csv` or `json` (spec/apps/pqledger.md §7).

use polyquery::api::{Column, ColumnType, QueryResult, Value};

/// The output format.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Format {
    #[default]
    Table,
    Csv,
    Json,
}

impl Format {
    pub fn parse(s: &str) -> Option<Format> {
        match s {
            "table" => Some(Format::Table),
            "csv" => Some(Format::Csv),
            "json" => Some(Format::Json),
            _ => None,
        }
    }
}

/// A result to print: typed columns and rows.
#[derive(Debug, Clone, PartialEq)]
pub struct Report {
    pub columns: Vec<Column>,
    pub rows: Vec<Vec<Value>>,
}

impl From<QueryResult> for Report {
    fn from(r: QueryResult) -> Self {
        let (columns, rows) = r.into_parts();
        Report { columns, rows }
    }
}

impl Report {
    /// Renders the report in `format`.
    pub fn render(&self, format: Format) -> String {
        match format {
            Format::Table => self.table(),
            Format::Csv => self.csv(),
            Format::Json => self.json(),
        }
    }

    fn table(&self) -> String {
        let texts: Vec<Vec<String>> = self
            .rows
            .iter()
            .map(|row| row.iter().map(value_text).collect())
            .collect();
        let widths: Vec<usize> = self
            .columns
            .iter()
            .enumerate()
            .map(|(c, col)| {
                texts
                    .iter()
                    .map(|row| row[c].chars().count())
                    .chain(std::iter::once(col.name.chars().count()))
                    .max()
                    .unwrap_or(0)
            })
            .collect();
        let right: Vec<bool> = self
            .columns
            .iter()
            .map(|c| c.column_type.is_numeric())
            .collect();
        let mut out = String::new();
        let mut line = |cells: &mut dyn Iterator<Item = &str>| {
            let mut text = String::new();
            for (c, cell) in cells.enumerate() {
                if c > 0 {
                    text.push_str("  ");
                }
                let pad = widths[c].saturating_sub(cell.chars().count());
                if right[c] {
                    text.extend(std::iter::repeat_n(' ', pad));
                    text.push_str(cell);
                } else {
                    text.push_str(cell);
                    text.extend(std::iter::repeat_n(' ', pad));
                }
            }
            out.push_str(text.trim_end_matches(' '));
            out.push('\n');
        };
        line(&mut self.columns.iter().map(|c| c.name.as_str()));
        let dashes: Vec<String> = widths.iter().map(|&w| "-".repeat(w)).collect();
        line(&mut dashes.iter().map(String::as_str));
        for row in &texts {
            line(&mut row.iter().map(String::as_str));
        }
        let n = self.rows.len();
        out.push_str(&if n == 1 {
            "(1 row)\n".to_string()
        } else {
            format!("({n} rows)\n")
        });
        out
    }

    fn csv(&self) -> String {
        let mut out = String::new();
        let header: Vec<String> = self.columns.iter().map(|c| csv_field(&c.name)).collect();
        out.push_str(&header.join(","));
        out.push('\n');
        for row in &self.rows {
            let fields: Vec<String> = row
                .iter()
                .map(|v| match v {
                    Value::Null => String::new(),
                    v => csv_field(&value_text(v)),
                })
                .collect();
            out.push_str(&fields.join(","));
            out.push('\n');
        }
        out
    }

    fn json(&self) -> String {
        let mut out = String::new();
        for row in &self.rows {
            out.push('{');
            for (c, (col, v)) in self.columns.iter().zip(row).enumerate() {
                if c > 0 {
                    out.push(',');
                }
                json_string(&mut out, &col.name);
                out.push(':');
                match v {
                    Value::Null => out.push_str("null"),
                    Value::Boolean(_) | Value::Int64(_) | Value::Float64(_) => {
                        out.push_str(&value_text(v))
                    }
                    _ => json_string(&mut out, &value_text(v)),
                }
            }
            out.push_str("}\n");
        }
        out
    }
}

/// The value text of §7: FLOAT64 with six fractional digits, NULL empty,
/// everything else in its canonical form.
pub fn value_text(v: &Value) -> String {
    match v {
        Value::Float64(f) => {
            let s = format!("{f:.6}");
            if s == "-0.000000" {
                "0.000000".to_string()
            } else {
                s
            }
        }
        other => other.to_string(),
    }
}

/// A CSV field, quoted when it is empty, contains `,` `"` CR or LF, or
/// starts or ends with a space.
fn csv_field(s: &str) -> String {
    if s.is_empty() || s.contains([',', '"', '\r', '\n']) || s.starts_with(' ') || s.ends_with(' ')
    {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s.to_string()
    }
}

fn json_string(out: &mut String, s: &str) {
    out.push('"');
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{8}' => out.push_str("\\b"),
            '\t' => out.push_str("\\t"),
            '\n' => out.push_str("\\n"),
            '\u{c}' => out.push_str("\\f"),
            '\r' => out.push_str("\\r"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

/// `DECIMAL(18,2)`, the type of every amount column.
pub const MONEY: ColumnType = ColumnType::Decimal {
    precision: 18,
    scale: 2,
};

#[cfg(test)]
mod tests {
    use super::*;
    use polyquery::api::Decimal;

    fn report() -> Report {
        Report {
            columns: vec![
                Column::new("month", ColumnType::String),
                Column::new("net", MONEY),
                Column::new("n", ColumnType::Int64),
            ],
            rows: vec![
                vec![
                    Value::String("2026-08".into()),
                    Value::Decimal(Decimal::new(5490, 2)),
                    Value::Int64(3),
                ],
                vec![
                    Value::String("a, \"b\"\n".into()),
                    Value::Decimal(Decimal::new(-120000, 2)),
                    Value::Null,
                ],
            ],
        }
    }

    #[test]
    fn table() {
        let mut r = report();
        r.rows[1][0] = Value::String("a, b".into());
        assert_eq!(
            r.render(Format::Table),
            "month         net  n\n\
             -------  --------  -\n\
             2026-08     54.90  3\n\
             a, b     -1200.00\n\
             (2 rows)\n"
        );
        r.rows.truncate(1);
        assert!(r.render(Format::Table).ends_with("(1 row)\n"));
        let empty = Report {
            columns: report().columns,
            rows: vec![],
        };
        assert_eq!(
            empty.render(Format::Table),
            "month  net  n\n-----  ---  -\n(0 rows)\n"
        );
    }

    #[test]
    fn csv_and_json() {
        assert_eq!(
            report().render(Format::Csv),
            "month,net,n\n2026-08,54.90,3\n\"a, \"\"b\"\"\n\",-1200.00,\n"
        );
        assert_eq!(
            report().render(Format::Json),
            "{\"month\":\"2026-08\",\"net\":\"54.90\",\"n\":3}\n\
             {\"month\":\"a, \\\"b\\\"\\n\",\"net\":\"-1200.00\",\"n\":null}\n"
        );
    }

    #[test]
    fn value_texts() {
        assert_eq!(value_text(&Value::Float64(-0.0000001)), "0.000000");
        assert_eq!(value_text(&Value::Float64(2.5)), "2.500000");
        assert_eq!(value_text(&Value::Boolean(true)), "true");
        let mut s = String::new();
        json_string(&mut s, "\u{1}\u{8}é");
        assert_eq!(s, "\"\\u0001\\bé\"");
    }
}
