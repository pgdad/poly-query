//! The commands (spec/apps/pqledger.md §6–§9). Every report, list and
//! budget is computed by SQL executed by the embedded engine; the host
//! formats the results and computes the `share` column.

use std::path::{Path, PathBuf};

use polyquery::api::{Column, ColumnType, Decimal, Value};

use crate::bankcsv;
use crate::cli::{CategoryFilter, Command, Filter, Month, ReportKind, USAGE};
use crate::config::Config;
use crate::convert;
use crate::error::{AppError, ErrorKind, Result};
use crate::ledger::{self, EngineSettings, Ledger, sql_string};
use crate::output::{Format, Report};
use crate::rules;

/// What a successful command prints, and its exit status.
pub enum Outcome {
    /// Lines of text.
    Message(String),
    /// A result in the selected format, with the exit status.
    Report(Report, u8),
}

/// The configuration file to use (§3.1): `--config`, else
/// `$PQLEDGER_CONFIG`, else `./pqledger.conf`.
pub fn config_path(option: Option<&str>) -> PathBuf {
    if let Some(p) = option {
        return PathBuf::from(p);
    }
    match std::env::var_os("PQLEDGER_CONFIG") {
        Some(p) if !p.is_empty() => PathBuf::from(p),
        _ => PathBuf::from("pqledger.conf"),
    }
}

/// Runs a command; `format_option` is the `--format` option.
pub fn run(
    command: Command,
    config_option: Option<&str>,
    format_option: Option<Format>,
) -> Result<(Outcome, Format)> {
    match command {
        Command::Help => return Ok((Outcome::Message(USAGE.to_string()), Format::Table)),
        Command::Version => {
            let text = format!(
                "pqledger {} (polyquery-rust engine, embedded)\n",
                env!("CARGO_PKG_VERSION")
            );
            return Ok((Outcome::Message(text), Format::Table));
        }
        _ => {}
    }
    let config = Config::load(&config_path(config_option))?;
    let format = format_option.or(config.format).unwrap_or_default();
    let engine = EngineSettings {
        threads: config.threads,
        memory_mb: config.memory_mb,
    };
    if command == Command::Init {
        Ledger::init(&config.data_dir, engine)?;
        return Ok((Outcome::Message("initialized ledger\n".into()), format));
    }
    let rules = match &config.rules_file {
        Some(path) => rules::load_rules(path)?,
        None => Vec::new(),
    };
    let budgets = match (&command, &config.budget_file) {
        (Command::Budget { .. } | Command::Query { .. }, Some(path)) => rules::load_budgets(path)?,
        (Command::Budget { .. }, None) => {
            return Err(AppError::config("budget requires budget_file in [ledger]"));
        }
        _ => Vec::new(),
    };
    let ledger = Ledger::open(&config.data_dir, engine)?;
    let needs_categories = matches!(
        command,
        Command::Report {
            kind: ReportKind::Categories,
            ..
        } | Command::Budget { .. }
            | Command::List { .. }
            | Command::Export { .. }
            | Command::Query { .. }
    );
    if needs_categories {
        ledger.add_rules(&rules)?;
        ledger.add_categorized_ledger()?;
    }
    let outcome = match command {
        Command::Import { file, account } => import(&ledger, &config, &file, &account)?,
        Command::Report { kind, filter } => report(&ledger, kind, &filter)?,
        Command::Budget { month, account } => {
            ledger.add_budgets(&budgets)?;
            budget(&ledger, month, account.as_deref())?
        }
        Command::Accounts => Outcome::Report(
            ledger
                .query(
                    "SELECT account, COUNT(*) AS transactions, SUM(amount) AS balance, \
                     MIN(\"date\") AS \"first\", MAX(\"date\") AS \"last\" \
                     FROM transactions GROUP BY account ORDER BY account",
                )?
                .into(),
            0,
        ),
        Command::List { filter, category } => {
            let mut conditions = filter_conditions(&filter);
            match category {
                CategoryFilter::Any => {}
                CategoryFilter::Category(c) => {
                    conditions.push(format!("category = {}", sql_string(&c)))
                }
                CategoryFilter::Uncategorized => {
                    conditions.push(format!("category = {}", sql_string(ledger::UNCATEGORIZED)))
                }
            }
            Outcome::Report(
                ledger
                    .query(&format!(
                        "SELECT id, \"date\", account, description, amount, category FROM ledger{} \
                         ORDER BY \"date\", id",
                        where_clause(&conditions)
                    ))?
                    .into(),
                0,
            )
        }
        Command::Export { filter } => Outcome::Report(
            ledger
                .query(&format!(
                    "SELECT id, account, \"date\", description, merchant, amount, category, batch \
                     FROM ledger{} ORDER BY id",
                    where_clause(&filter_conditions(&filter))
                ))?
                .into(),
            0,
        ),
        Command::SetCategory { id, category } => {
            if !ledger.has_transaction(id)? {
                return Err(AppError::ledger(format!("no transaction with id {id}")));
            }
            ledger.set_override(id, category.as_deref())?;
            Outcome::Message(match category {
                Some(c) => format!("transaction {id}: category {c}\n"),
                None => format!("transaction {id}: category cleared\n"),
            })
        }
        Command::Query { sql } => {
            ledger.add_budgets(&budgets)?;
            let result = ledger
                .user_query(&sql)
                .map_err(|e| AppError::new(ErrorKind::Query, e.to_string()))?;
            Outcome::Report(result.into(), 0)
        }
        Command::Help | Command::Version | Command::Init => unreachable!("handled above"),
    };
    ledger.close();
    Ok((outcome, format))
}

/// `import FILE --account NAME` (§6.2).
fn import(ledger: &Ledger, config: &Config, file: &str, account: &str) -> Result<Outcome> {
    let path = Path::new(file);
    let bytes =
        std::fs::read(path).map_err(|e| AppError::import(format!("{file}: cannot read: {e}")))?;
    let text = String::from_utf8(bytes)
        .map_err(|_| AppError::import(format!("{file}: not valid UTF-8")))?;
    let settings = config.import_settings(account);
    let records = bankcsv::parse(&text, settings.delimiter, settings.skip_lines)
        .map_err(|e| AppError::import(format!("{file}:{}: {}", e.line, e.message)))?;
    let entries = convert::convert(&records, &settings)
        .map_err(|e| AppError::import(format!("{file}:{}: {}", e.line, e.message)))?;
    let base_name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| file.to_string());
    let s = ledger.import(account, &base_name, &entries)?;
    Ok(Outcome::Message(format!(
        "batch {}: imported {}, duplicates {}\n",
        s.batch, s.imported, s.duplicates
    )))
}

/// SQL conditions of the common filters.
fn filter_conditions(filter: &Filter) -> Vec<String> {
    let mut c = Vec::new();
    if let Some(from) = filter.from {
        c.push(format!("\"date\" >= DATE '{}'", from.first_day()));
    }
    if let Some(next) = filter.to.and_then(Month::next) {
        c.push(format!("\"date\" < DATE '{}'", next.first_day()));
    }
    if let Some(a) = &filter.account {
        c.push(format!("account = {}", sql_string(a)));
    }
    c
}

fn where_clause(conditions: &[String]) -> String {
    if conditions.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", conditions.join(" AND "))
    }
}

fn report(ledger: &Ledger, kind: ReportKind, filter: &Filter) -> Result<Outcome> {
    let mut conditions = filter_conditions(filter);
    let report = match kind {
        ReportKind::Monthly => {
            let month = "SUBSTR(CAST(\"date\" AS STRING), 1, 7)";
            ledger
                .query(&format!(
                    "SELECT {month} AS month, \
                     SUM(CASE WHEN amount > 0 THEN amount ELSE 0.00 END) AS income, \
                     -SUM(CASE WHEN amount < 0 THEN amount ELSE 0.00 END) AS expenses, \
                     SUM(amount) AS net, COUNT(*) AS transactions \
                     FROM transactions{} GROUP BY {month} ORDER BY month",
                    where_clause(&conditions)
                ))?
                .into()
        }
        ReportKind::Categories => {
            conditions.push("amount < 0".into());
            let spent: Report = ledger
                .query(&format!(
                    "SELECT category, -SUM(amount) AS spent, COUNT(*) AS transactions \
                     FROM ledger{} GROUP BY category ORDER BY spent DESC, category",
                    where_clause(&conditions)
                ))?
                .into();
            with_share(spent)?
        }
        ReportKind::Merchants { top } => {
            conditions.push("amount < 0".into());
            ledger
                .query(&format!(
                    "SELECT merchant, -SUM(amount) AS spent, COUNT(*) AS transactions \
                     FROM transactions{} GROUP BY merchant ORDER BY spent DESC, merchant LIMIT {top}",
                    where_clause(&conditions)
                ))?
                .into()
        }
    };
    Ok(Outcome::Report(report, 0))
}

/// Inserts `share` (DECIMAL(18,1)) after `spent`: 100 × spent ÷ total,
/// rounded half away from zero, computed exactly in cents (§9.2).
fn with_share(mut report: Report) -> Result<Report> {
    let spent: Vec<i128> = report
        .rows
        .iter()
        .map(|r| ledger::cents_of(&r[1]).map(i128::from))
        .collect::<Result<_>>()?;
    let total: i128 = spent.iter().sum();
    for (row, cents) in report.rows.iter_mut().zip(&spent) {
        row.insert(
            2,
            Value::Decimal(Decimal::new(share_tenths(*cents, total), 1)),
        );
    }
    report.columns.insert(
        2,
        Column::new(
            "share",
            ColumnType::Decimal {
                precision: 18,
                scale: 1,
            },
        ),
    );
    Ok(report)
}

/// `1000 × part ÷ total` rounded half away from zero (parts are ≥ 0).
fn share_tenths(part: i128, total: i128) -> i128 {
    if total == 0 {
        return 0;
    }
    (2 * 1000 * part + total) / (2 * total)
}

/// `budget --month M [--account NAME]` (§9.4): exit status 3 if a category
/// is over budget.
fn budget(ledger: &Ledger, month: Month, account: Option<&str>) -> Result<Outcome> {
    let filter = Filter {
        from: Some(month),
        to: Some(month),
        account: account.map(str::to_string),
    };
    let mut conditions = filter_conditions(&filter);
    conditions.push("amount < 0".into());
    let report: Report = ledger
        .query(&format!(
            "SELECT b.category, b.amount AS budget, COALESCE(s.spent, 0.00) AS spent, \
             b.amount - COALESCE(s.spent, 0.00) AS remaining, \
             CASE WHEN COALESCE(s.spent, 0.00) <= b.amount THEN 'ok' ELSE 'over' END AS status \
             FROM budgets b LEFT JOIN \
             (SELECT category, -SUM(amount) AS spent FROM ledger{} GROUP BY category) s \
             ON s.category = b.category ORDER BY b.category",
            where_clause(&conditions)
        ))?
        .into();
    let over = report
        .rows
        .iter()
        .any(|r| r.last().and_then(Value::as_str) == Some("over"));
    Ok(Outcome::Report(report, if over { 3 } else { 0 }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shares_round_half_away_from_zero() {
        assert_eq!(share_tenths(39701, 40001), 993);
        assert_eq!(share_tenths(300, 40001), 7);
        assert_eq!(share_tenths(200, 300), 667);
        assert_eq!(share_tenths(1, 8), 125); // 12.5 exactly
        assert_eq!(share_tenths(1, 16), 63); // 6.25 → 6.3
        assert_eq!(share_tenths(5, 5), 1000);
    }

    #[test]
    fn filters_become_conditions() {
        let f = Filter {
            from: Month::parse("2026-01"),
            to: Month::parse("9999-12"),
            account: Some("o'k".into()),
        };
        assert_eq!(
            where_clause(&filter_conditions(&f)),
            " WHERE \"date\" >= DATE '2026-01-01' AND account = 'o''k'"
        );
        let f = Filter {
            to: Month::parse("2026-12"),
            ..Filter::default()
        };
        assert_eq!(filter_conditions(&f), ["\"date\" < DATE '2027-01-01'"]);
        assert_eq!(where_clause(&[]), "");
    }
}
