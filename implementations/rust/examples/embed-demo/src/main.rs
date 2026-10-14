//! `pq-embed-demo DATA_DIR CSV_FILE SQL` — the minimal embedding example
//! (spec/apps/embedding.md §5).
//!
//! Creates an engine instance on `DATA_DIR`, loads `CSV_FILE` (relative to
//! `DATA_DIR`, header row, inferred schema) as table `t`, runs `SQL` and
//! prints the result as CSV. It uses only the public API `polyquery::api`.

use std::io::{self, Write};
use std::process::ExitCode;

use polyquery::api::{Config, Database, LoadOptions, QueryResult, Value};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [data_dir, csv_file, sql] = args.as_slice() else {
        eprintln!("usage: pq-embed-demo DATA_DIR CSV_FILE SQL");
        return ExitCode::from(2);
    };
    match run(data_dir, csv_file, sql) {
        Ok(result) => match print_csv(&result) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("error: cannot write the result: {e}");
                ExitCode::from(1)
            }
        },
        Err(e) => {
            eprintln!("error: {}: {}", e.code_str(), e.message());
            ExitCode::from(1)
        }
    }
}

/// Create, load, query, close.
fn run(data_dir: &str, csv_file: &str, sql: &str) -> polyquery::api::Result<QueryResult> {
    let db = Database::create(Config::new(data_dir))?;
    db.load_csv_file("t", csv_file, &LoadOptions::default())?;
    let result = db.query(sql)?;
    db.close();
    Ok(result)
}

/// The `csv` output format of spec/apps/pqledger.md §7.
fn print_csv(result: &QueryResult) -> io::Result<()> {
    let mut out = io::BufWriter::new(io::stdout().lock());
    let header: Vec<String> = result.column_names().map(quote).collect();
    writeln!(out, "{}", header.join(","))?;
    for row in result {
        let fields: Vec<String> = row
            .iter()
            .map(|v| match v {
                Value::Null => String::new(),
                other => quote(&text(other)),
            })
            .collect();
        writeln!(out, "{}", fields.join(","))?;
    }
    out.flush()
}

/// Value text: FLOAT64 with six fractional digits, everything else in its
/// canonical form.
fn text(v: &Value) -> String {
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

/// Quotes a non-NULL field if it is empty, contains `,`, `"`, CR or LF, or
/// starts or ends with a space.
fn quote(s: &str) -> String {
    let needs = s.is_empty()
        || s.contains([',', '"', '\r', '\n'])
        || s.starts_with(' ')
        || s.ends_with(' ');
    if needs {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s.to_string()
    }
}
