//! Command-line parsing (spec/apps/pqledger.md §2).

use crate::config::{is_account_name, is_category_name};
use crate::error::{AppError, Result};
use crate::output::Format;

pub const USAGE: &str = "\
usage: pqledger [--config PATH] [--format table|csv|json] COMMAND [ARGS]

commands:
  init                                    create an empty ledger
  import FILE --account NAME              import a bank-statement CSV file
  report monthly [FILTERS]                income, expenses and net per month
  report categories [FILTERS]             spending per category
  report merchants [FILTERS] [--top N]    top merchants by spending (default 10)
  budget --month YYYY-MM [--account NAME] spending against the monthly budgets
  accounts                                transactions, balance and dates per account
  list [FILTERS] [--category C | --uncategorized]
                                          transactions by date
  export [FILTERS]                        all transaction columns by id
  set-category ID CATEGORY                override the category of a transaction
  set-category ID --clear                 remove the override
  query SQL                               run SQL on the ledger tables
  help                                    show this help
  version                                 show the version

filters:
  --month YYYY-MM | --from YYYY-MM | --to YYYY-MM   date range (inclusive months)
  --account NAME                                    one account

The configuration file is --config PATH, else $PQLEDGER_CONFIG, else
./pqledger.conf. See APP.md for the configuration reference.
";

/// A calendar month (`YYYY-MM`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Month {
    pub year: u32,
    pub month: u32,
}

impl Month {
    /// Parses `YYYY-MM` with year 0001–9999 and month 01–12.
    pub fn parse(s: &str) -> Option<Month> {
        let b = s.as_bytes();
        if b.len() != 7 || b[4] != b'-' || !s.is_ascii() {
            return None;
        }
        let (y, m) = (&s[..4], &s[5..]);
        if !y.bytes().chain(m.bytes()).all(|c| c.is_ascii_digit()) {
            return None;
        }
        let (year, month) = (y.parse().ok()?, m.parse().ok()?);
        ((1..=9999).contains(&year) && (1..=12).contains(&month)).then_some(Month { year, month })
    }

    /// The following month (None after 9999-12).
    pub fn next(self) -> Option<Month> {
        match self {
            Month {
                year: 9999,
                month: 12,
            } => None,
            Month { year, month: 12 } => Some(Month {
                year: year + 1,
                month: 1,
            }),
            Month { year, month } => Some(Month {
                year,
                month: month + 1,
            }),
        }
    }

    /// `YYYY-MM-01`.
    pub fn first_day(self) -> String {
        format!("{:04}-{:02}-01", self.year, self.month)
    }
}

/// The common filters: an inclusive month range and an account.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Filter {
    pub from: Option<Month>,
    pub to: Option<Month>,
    pub account: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CategoryFilter {
    Any,
    Category(String),
    Uncategorized,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReportKind {
    Monthly,
    Categories,
    Merchants { top: u64 },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Command {
    Help,
    Version,
    Init,
    Import {
        file: String,
        account: String,
    },
    Report {
        kind: ReportKind,
        filter: Filter,
    },
    Budget {
        month: Month,
        account: Option<String>,
    },
    Accounts,
    List {
        filter: Filter,
        category: CategoryFilter,
    },
    Export {
        filter: Filter,
    },
    SetCategory {
        id: i64,
        category: Option<String>,
    },
    Query {
        sql: String,
    },
}

/// A parsed command line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Invocation {
    pub config: Option<String>,
    pub format: Option<Format>,
    pub command: Command,
}

/// The options and positional arguments of a command.
struct Args {
    positionals: Vec<String>,
    values: Vec<(&'static str, String)>,
    flags: Vec<&'static str>,
}

impl Args {
    /// Splits `args` by the command's value options and flags. Repeated
    /// or unknown options and missing values are usage errors.
    fn parse(
        args: &[String],
        value_options: &[&'static str],
        flags: &[&'static str],
    ) -> Result<Args> {
        let mut parsed = Args {
            positionals: Vec::new(),
            values: Vec::new(),
            flags: Vec::new(),
        };
        let mut it = args.iter();
        while let Some(arg) = it.next() {
            if !arg.starts_with("--") {
                parsed.positionals.push(arg.clone());
                continue;
            }
            let repeated = || AppError::usage(format!("option {arg} given more than once"));
            if let Some(&name) = value_options.iter().find(|&&o| o == arg) {
                if parsed.values.iter().any(|(n, _)| *n == name) {
                    return Err(repeated());
                }
                let value = it
                    .next()
                    .ok_or_else(|| AppError::usage(format!("option {arg} requires a value")))?;
                parsed.values.push((name, value.clone()));
            } else if let Some(&name) = flags.iter().find(|&&o| o == arg) {
                if parsed.flags.contains(&name) {
                    return Err(repeated());
                }
                parsed.flags.push(name);
            } else {
                return Err(AppError::usage(format!("unknown option {arg}")));
            }
        }
        Ok(parsed)
    }

    fn value(&self, name: &str) -> Option<&str> {
        self.values
            .iter()
            .find(|(n, _)| *n == name)
            .map(|(_, v)| v.as_str())
    }

    fn flag(&self, name: &str) -> bool {
        self.flags.contains(&name)
    }

    /// Exactly `n` positional arguments.
    fn positionals(&self, n: usize, what: &str) -> Result<&[String]> {
        match self.positionals.len() {
            len if len == n => Ok(&self.positionals),
            len if len < n => Err(AppError::usage(format!("missing {what}"))),
            _ => Err(AppError::usage(format!(
                "unexpected argument '{}'",
                self.positionals[n]
            ))),
        }
    }

    fn filter(&self) -> Result<Filter> {
        let month = |name: &str| -> Result<Option<Month>> {
            self.value(name)
                .map(|v| {
                    Month::parse(v).ok_or_else(|| {
                        AppError::usage(format!("{name}: invalid month '{v}' (expected YYYY-MM)"))
                    })
                })
                .transpose()
        };
        let (single, from, to) = (month("--month")?, month("--from")?, month("--to")?);
        let (from, to) = match single {
            Some(_) if from.is_some() || to.is_some() => {
                return Err(AppError::usage(
                    "--month cannot be combined with --from or --to",
                ));
            }
            Some(m) => (Some(m), Some(m)),
            None => (from, to),
        };
        if let (Some(f), Some(t)) = (from, to)
            && f > t
        {
            return Err(AppError::usage("--from is later than --to"));
        }
        Ok(Filter {
            from,
            to,
            account: self.account()?,
        })
    }

    fn account(&self) -> Result<Option<String>> {
        self.value("--account")
            .map(|a| {
                if is_account_name(a) {
                    Ok(a.to_string())
                } else {
                    Err(AppError::usage(format!(
                        "invalid account name '{a}' (expected [a-z0-9_-]{{1,32}})"
                    )))
                }
            })
            .transpose()
    }
}

/// A transaction id: a decimal integer ≥ 1. Ids beyond `i64` cannot
/// exist; they saturate (and are then reported as unknown).
fn parse_id(v: &str) -> Option<i64> {
    if v.is_empty() || !v.bytes().all(|b| b.is_ascii_digit()) || v.bytes().all(|b| b == b'0') {
        return None;
    }
    Some(v.parse().unwrap_or(i64::MAX))
}

/// `--top N`: a decimal integer ≥ 1; values beyond `u64` saturate.
fn parse_top(v: &str) -> Option<u64> {
    if v.is_empty() || !v.bytes().all(|b| b.is_ascii_digit()) || v.bytes().all(|b| b == b'0') {
        return None;
    }
    Some(v.parse().unwrap_or(u64::MAX))
}

const FILTERS: [&str; 4] = ["--month", "--from", "--to", "--account"];

fn with_filters(extra: &[&'static str]) -> Vec<&'static str> {
    FILTERS.iter().chain(extra).copied().collect()
}

/// Parses the arguments after the program name.
pub fn parse(args: &[String]) -> Result<Invocation> {
    let mut config = None;
    let mut format = None;
    let mut rest = args;
    let mut help = false;
    while let Some(arg) = rest.first().filter(|a| a.starts_with("--")) {
        let repeated = || AppError::usage(format!("option {arg} given more than once"));
        match arg.as_str() {
            "--help" => {
                rest = &rest[1..];
                help = true;
                break;
            }
            "--config" | "--format" => {
                let value = rest
                    .get(1)
                    .ok_or_else(|| AppError::usage(format!("option {arg} requires a value")))?;
                if arg == "--config" {
                    if config.replace(value.clone()).is_some() {
                        return Err(repeated());
                    }
                } else {
                    let f = Format::parse(value).ok_or_else(|| {
                        AppError::usage(format!(
                            "invalid format '{value}' (expected table, csv or json)"
                        ))
                    })?;
                    if format.replace(f).is_some() {
                        return Err(repeated());
                    }
                }
                rest = &rest[2..];
            }
            _ => return Err(AppError::usage(format!("unknown option {arg}"))),
        }
    }
    let command = if help {
        Args::parse(rest, &[], &[])?.positionals(0, "")?;
        Command::Help
    } else {
        let (name, args) = rest
            .split_first()
            .ok_or_else(|| AppError::usage("missing command"))?;
        parse_command(name, args)?
    };
    Ok(Invocation {
        config,
        format,
        command,
    })
}

fn parse_command(name: &str, args: &[String]) -> Result<Command> {
    let no_args = |command: Command| -> Result<Command> {
        Args::parse(args, &[], &[])?.positionals(0, "")?;
        Ok(command)
    };
    match name {
        "help" => no_args(Command::Help),
        "version" => no_args(Command::Version),
        "init" => no_args(Command::Init),
        "accounts" => no_args(Command::Accounts),
        "import" => {
            let a = Args::parse(args, &["--account"], &[])?;
            let file = a.positionals(1, "FILE")?[0].clone();
            let account = a
                .account()?
                .ok_or_else(|| AppError::usage("import requires --account NAME"))?;
            Ok(Command::Import { file, account })
        }
        "report" => {
            let (kind, args) = args.split_first().ok_or_else(|| {
                AppError::usage("missing report kind (monthly, categories or merchants)")
            })?;
            let options = match kind.as_str() {
                "merchants" => with_filters(&["--top"]),
                "monthly" | "categories" => with_filters(&[]),
                other => return Err(AppError::usage(format!("unknown report '{other}'"))),
            };
            let a = Args::parse(args, &options, &[])?;
            a.positionals(0, "")?;
            let kind = match kind.as_str() {
                "monthly" => ReportKind::Monthly,
                "categories" => ReportKind::Categories,
                _ => {
                    let top = match a.value("--top") {
                        None => 10,
                        Some(v) => parse_top(v).ok_or_else(|| {
                            AppError::usage(format!("--top: expected an integer >= 1, not '{v}'"))
                        })?,
                    };
                    ReportKind::Merchants { top }
                }
            };
            Ok(Command::Report {
                kind,
                filter: a.filter()?,
            })
        }
        "budget" => {
            let a = Args::parse(args, &["--month", "--account"], &[])?;
            a.positionals(0, "")?;
            let filter = a.filter()?;
            let month = filter
                .from
                .ok_or_else(|| AppError::usage("budget requires --month YYYY-MM"))?;
            Ok(Command::Budget {
                month,
                account: filter.account,
            })
        }
        "list" => {
            let a = Args::parse(args, &with_filters(&["--category"]), &["--uncategorized"])?;
            a.positionals(0, "")?;
            let category = match (a.value("--category"), a.flag("--uncategorized")) {
                (Some(_), true) => {
                    return Err(AppError::usage(
                        "--category and --uncategorized exclude each other",
                    ));
                }
                (Some(c), false) if is_category_name(c) || c == crate::ledger::UNCATEGORIZED => {
                    CategoryFilter::Category(c.to_string())
                }
                (Some(c), false) => {
                    return Err(AppError::usage(format!("invalid category name '{c}'")));
                }
                (None, true) => CategoryFilter::Uncategorized,
                (None, false) => CategoryFilter::Any,
            };
            Ok(Command::List {
                filter: a.filter()?,
                category,
            })
        }
        "export" => {
            let a = Args::parse(args, &with_filters(&[]), &[])?;
            a.positionals(0, "")?;
            Ok(Command::Export {
                filter: a.filter()?,
            })
        }
        "set-category" => {
            let a = Args::parse(args, &[], &["--clear"])?;
            let clear = a.flag("--clear");
            let p = a.positionals(if clear { 1 } else { 2 }, "ID and CATEGORY")?;
            let id = parse_id(&p[0])
                .ok_or_else(|| AppError::usage(format!("invalid transaction id '{}'", p[0])))?;
            let category = if clear {
                None
            } else if is_category_name(&p[1]) {
                Some(p[1].clone())
            } else {
                return Err(AppError::usage(format!(
                    "invalid category name '{}' (expected [a-z0-9_-]{{1,32}}, not 'uncategorized')",
                    p[1]
                )));
            };
            Ok(Command::SetCategory { id, category })
        }
        "query" => {
            let a = Args::parse(args, &[], &[])?;
            let sql = a.positionals(1, "SQL")?[0].clone();
            Ok(Command::Query { sql })
        }
        other => Err(AppError::usage(format!("unknown command '{other}'"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ErrorKind;

    fn parse_str(line: &str) -> Result<Invocation> {
        let args: Vec<String> = line.split_whitespace().map(String::from).collect();
        parse(&args)
    }

    fn command(line: &str) -> Command {
        parse_str(line).unwrap().command
    }

    fn is_usage_error(line: &str) -> bool {
        matches!(parse_str(line), Err(e) if e.kind == ErrorKind::Usage)
    }

    fn month(s: &str) -> Month {
        Month::parse(s).unwrap()
    }

    #[test]
    fn commands() {
        let inv =
            parse_str("--format csv --config c.conf report monthly --account a --from 2026-01")
                .unwrap();
        assert_eq!(inv.format, Some(Format::Csv));
        assert_eq!(inv.config.as_deref(), Some("c.conf"));
        assert_eq!(
            inv.command,
            Command::Report {
                kind: ReportKind::Monthly,
                filter: Filter {
                    from: Some(month("2026-01")),
                    to: None,
                    account: Some("a".into())
                }
            }
        );
        assert_eq!(
            command("import --account card x.csv"),
            Command::Import {
                file: "x.csv".into(),
                account: "card".into()
            }
        );
        assert_eq!(
            command("set-category --clear 7"),
            Command::SetCategory {
                id: 7,
                category: None
            }
        );
        assert_eq!(
            command("report merchants --top 3"),
            Command::Report {
                kind: ReportKind::Merchants { top: 3 },
                filter: Filter::default()
            }
        );
        assert_eq!(command("--help"), Command::Help);
        assert_eq!(parse_top("99999999999999999999"), Some(u64::MAX));
        assert_eq!(parse_top("007"), Some(7));
        assert_eq!(parse_top("00"), None);
        assert_eq!(parse_id("99999999999999999999"), Some(i64::MAX));
        assert_eq!(parse_id("+1"), None);
        assert_eq!(
            command("budget --month 2026-02"),
            Command::Budget {
                month: month("2026-02"),
                account: None
            }
        );
    }

    #[test]
    fn usage_errors() {
        for line in [
            "",
            "frobnicate",
            "report",
            "report weekly",
            "report monthly --month 2026-01 --from 2026-01",
            "report monthly --month 2026-13",
            "report monthly --month 0000-01",
            "report monthly --from 2026-03 --to 2026-02",
            "report monthly --bogus",
            "report monthly --month",
            "import t.csv",
            "import t.csv --account Bad",
            "import a.csv b.csv --account a",
            "set-category 1 Groceries",
            "set-category 1 uncategorized",
            "set-category 0 x",
            "set-category 1 x --clear",
            "report merchants --top 0",
            "--format xml accounts",
            "--config a --config b accounts",
            "accounts extra",
            "report monthly --month 2026-01 --month 2026-02",
            "budget",
            "budget --month 2026-01 --from 2026-01",
            "list --category a --uncategorized",
            "query",
            "query a b",
            "init --account x",
            "--verbose init",
        ] {
            assert!(is_usage_error(line), "accepted: {line:?}");
        }
    }

    #[test]
    fn months() {
        assert_eq!(month("2026-12").next(), Some(month("2027-01")));
        assert_eq!(month("9999-12").next(), None);
        assert_eq!(month("0001-02").first_day(), "0001-02-01");
        assert!(Month::parse("2026-1").is_none());
        assert!(Month::parse("2026-00").is_none());
    }
}
