//! The configuration file (spec/apps/pqledger.md §3).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::error::{AppError, Result};
use crate::ini::{self, Line};
use crate::output::Format;

/// Where a CSV column is found: its 1-based position or its header name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ColumnRef {
    Position(usize),
    Name(String),
}

impl ColumnRef {
    fn parse(value: &str) -> std::result::Result<ColumnRef, String> {
        if value.is_empty() {
            return Err("a column reference must not be empty".into());
        }
        if value.bytes().all(|b| b.is_ascii_digit()) {
            return match value.parse::<usize>() {
                Ok(n) if n >= 1 => Ok(ColumnRef::Position(n)),
                _ => Err(format!("invalid column position '{value}'")),
            };
        }
        Ok(ColumnRef::Name(value.to_string()))
    }
}

impl std::fmt::Display for ColumnRef {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ColumnRef::Position(n) => write!(f, "column {n}"),
            ColumnRef::Name(name) => write!(f, "column '{name}'"),
        }
    }
}

/// The `date_format` values.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DateFormat {
    /// `YYYY-MM-DD`
    Iso,
    /// `YYYYMMDD`
    Compact,
    /// `MM/DD/YYYY`
    MonthDayYear,
    /// `DD/MM/YYYY`
    DayMonthYear,
    /// `DD.MM.YYYY`
    Dotted,
}

impl DateFormat {
    fn parse(value: &str) -> Option<DateFormat> {
        Some(match value {
            "YYYY-MM-DD" => DateFormat::Iso,
            "YYYYMMDD" => DateFormat::Compact,
            "MM/DD/YYYY" => DateFormat::MonthDayYear,
            "DD/MM/YYYY" => DateFormat::DayMonthYear,
            "DD.MM.YYYY" => DateFormat::Dotted,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AmountMode {
    /// One signed amount column.
    Signed,
    /// Separate debit and credit columns: amount = credit − debit.
    DebitCredit,
}

/// How the bank files of one account are read: the effective `[import]`
/// settings (§3.3).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImportSettings {
    pub delimiter: u8,
    pub header: bool,
    pub skip_lines: usize,
    pub date_column: ColumnRef,
    pub date_format: DateFormat,
    pub description_column: ColumnRef,
    pub amount_mode: AmountMode,
    pub amount_column: ColumnRef,
    pub debit_column: ColumnRef,
    pub credit_column: ColumnRef,
    pub decimal_separator: char,
    /// None: no thousands separator.
    pub thousands_separator: Option<char>,
    pub currency_symbol: String,
    pub invert_sign: bool,
}

impl Default for ImportSettings {
    fn default() -> Self {
        ImportSettings {
            delimiter: b',',
            header: true,
            skip_lines: 0,
            date_column: ColumnRef::Name("Date".into()),
            date_format: DateFormat::Iso,
            description_column: ColumnRef::Name("Description".into()),
            amount_mode: AmountMode::Signed,
            amount_column: ColumnRef::Name("Amount".into()),
            debit_column: ColumnRef::Name("Debit".into()),
            credit_column: ColumnRef::Name("Credit".into()),
            decimal_separator: '.',
            thousands_separator: None,
            currency_symbol: String::new(),
            invert_sign: false,
        }
    }
}

/// One `[import]` or `[account NAME]` section: the keys it sets, applied
/// over the settings of the level below.
#[derive(Debug, Clone, Default)]
struct ImportSection {
    /// Line of the section header (for messages).
    line: usize,
    keys: Vec<(String, String)>,
}

impl ImportSection {
    /// Applies this section's keys over `base`. Keys and values were
    /// validated when the file was read.
    fn apply(&self, base: &ImportSettings) -> ImportSettings {
        let mut s = base.clone();
        for (key, value) in &self.keys {
            set_import_key(&mut s, key, value).expect("validated import key");
        }
        s
    }
}

/// Sets one `[import]` key; Err for unknown keys and invalid values.
fn set_import_key(
    s: &mut ImportSettings,
    key: &str,
    value: &str,
) -> std::result::Result<(), String> {
    let bool_value = || match value {
        "true" => Ok(true),
        "false" => Ok(false),
        _ => Err(format!("{key} must be 'true' or 'false'")),
    };
    match key {
        "delimiter" => {
            s.delimiter = match value {
                "tab" => b'\t',
                v if v.len() == 1 && v.is_ascii() && !matches!(v, "\"" | "\r" | "\n") => {
                    v.as_bytes()[0]
                }
                _ => return Err("delimiter must be one ASCII character or 'tab'".into()),
            }
        }
        "header" => s.header = bool_value()?,
        "skip_lines" => {
            s.skip_lines = parse_count(value).ok_or("skip_lines must be an integer >= 0")?;
        }
        "date_column" => s.date_column = ColumnRef::parse(value)?,
        "date_format" => {
            s.date_format = DateFormat::parse(value).ok_or_else(|| {
                format!("unknown date_format '{value}' (YYYY-MM-DD, YYYYMMDD, MM/DD/YYYY, DD/MM/YYYY or DD.MM.YYYY)")
            })?;
        }
        "description_column" => s.description_column = ColumnRef::parse(value)?,
        "amount_mode" => {
            s.amount_mode = match value {
                "signed" => AmountMode::Signed,
                "debit_credit" => AmountMode::DebitCredit,
                _ => return Err("amount_mode must be 'signed' or 'debit_credit'".into()),
            }
        }
        "amount_column" => s.amount_column = ColumnRef::parse(value)?,
        "debit_column" => s.debit_column = ColumnRef::parse(value)?,
        "credit_column" => s.credit_column = ColumnRef::parse(value)?,
        "decimal_separator" => {
            s.decimal_separator = match value {
                "." => '.',
                "," => ',',
                _ => return Err("decimal_separator must be '.' or ','".into()),
            }
        }
        "thousands_separator" => {
            s.thousands_separator = match value {
                "none" => None,
                "," => Some(','),
                "." => Some('.'),
                "space" => Some(' '),
                "'" => Some('\''),
                _ => return Err("thousands_separator must be none, ',', '.', space or '''".into()),
            }
        }
        "currency_symbol" => s.currency_symbol = value.to_string(),
        "invert_sign" => s.invert_sign = bool_value()?,
        _ => return Err(format!("unknown key '{key}'")),
    }
    Ok(())
}

fn parse_count(value: &str) -> Option<usize> {
    if value.is_empty() || !value.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    value.parse().ok()
}

/// An account name: `[a-z0-9_-]{1,32}`.
pub fn is_account_name(s: &str) -> bool {
    is_name(s)
}

/// A category name: `[a-z0-9_-]{1,32}`, not `uncategorized`.
pub fn is_category_name(s: &str) -> bool {
    is_name(s) && s != crate::ledger::UNCATEGORIZED
}

fn is_name(s: &str) -> bool {
    (1..=32).contains(&s.len())
        && s.bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_' || b == b'-')
}

/// The parsed configuration file.
#[derive(Debug, Clone)]
pub struct Config {
    pub data_dir: PathBuf,
    pub rules_file: Option<PathBuf>,
    pub budget_file: Option<PathBuf>,
    pub format: Option<Format>,
    pub threads: Option<usize>,
    pub memory_mb: Option<u64>,
    import: ImportSection,
    accounts: BTreeMap<String, ImportSection>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Section {
    Ledger,
    Import,
    Output,
    Engine,
    Account(String),
}

impl Section {
    fn parse(name: &str) -> Option<Section> {
        Some(match name {
            "ledger" => Section::Ledger,
            "import" => Section::Import,
            "output" => Section::Output,
            "engine" => Section::Engine,
            _ => {
                let account = name.strip_prefix("account ")?;
                if !is_account_name(account) {
                    return None;
                }
                Section::Account(account.to_string())
            }
        })
    }
}

impl Config {
    /// Reads and validates the configuration file at `path`.
    pub fn load(path: &Path) -> Result<Config> {
        let display = path.display().to_string();
        let bytes = std::fs::read(path).map_err(|e| {
            AppError::config(format!("cannot read configuration file '{display}': {e}"))
        })?;
        let text = String::from_utf8(bytes)
            .map_err(|_| AppError::config(format!("{display}: not valid UTF-8")))?;
        let base = match path.parent() {
            Some(p) if !p.as_os_str().is_empty() => p.to_path_buf(),
            _ => PathBuf::from("."),
        };
        Config::parse(&text, &base).map_err(|m| AppError::config(format!("{display}: {m}")))
    }

    /// Parses configuration text; relative paths are resolved against
    /// `base`. Errors name the line.
    pub fn parse(text: &str, base: &Path) -> std::result::Result<Config, String> {
        let mut data_dir = None;
        let mut rules_file = None;
        let mut budget_file = None;
        let mut format = None;
        let mut threads = None;
        let mut memory_mb = None;
        let mut import: Option<ImportSection> = None;
        let mut accounts: BTreeMap<String, ImportSection> = BTreeMap::new();
        let mut seen_sections: Vec<Section> = Vec::new();
        let mut current: Option<Section> = None;
        let mut keys_in_section: Vec<String> = Vec::new();

        for ini::Numbered { number, line } in ini::parse(text)? {
            match line {
                Line::Section(name) => {
                    let section = Section::parse(&name)
                        .ok_or_else(|| format!("line {number}: unknown section [{name}]"))?;
                    if seen_sections.contains(&section) {
                        return Err(format!("line {number}: section [{name}] repeated"));
                    }
                    seen_sections.push(section.clone());
                    let fresh = ImportSection {
                        line: number,
                        keys: Vec::new(),
                    };
                    match &section {
                        Section::Import => import = Some(fresh),
                        Section::Account(a) => {
                            accounts.insert(a.clone(), fresh);
                        }
                        _ => {}
                    }
                    current = Some(section);
                    keys_in_section.clear();
                }
                Line::Assignment { key, value } => {
                    let Some(section) = &current else {
                        return Err(format!(
                            "line {number}: assignment before the first section"
                        ));
                    };
                    if keys_in_section.contains(&key) {
                        return Err(format!(
                            "line {number}: key '{key}' repeated in the section"
                        ));
                    }
                    keys_in_section.push(key.clone());
                    let bad = |m: String| format!("line {number}: {m}");
                    let path_value = |v: &str| {
                        if v.is_empty() {
                            Err(bad(format!("{key} must not be empty")))
                        } else {
                            Ok(base.join(v))
                        }
                    };
                    match section {
                        Section::Ledger => match key.as_str() {
                            "data_dir" => data_dir = Some(path_value(&value)?),
                            "rules_file" => rules_file = Some(path_value(&value)?),
                            "budget_file" => budget_file = Some(path_value(&value)?),
                            _ => return Err(bad(format!("unknown key '{key}' in [ledger]"))),
                        },
                        Section::Output => match key.as_str() {
                            "format" => {
                                format = Some(Format::parse(&value).ok_or_else(|| {
                                    bad(format!("format must be table, csv or json, not '{value}'"))
                                })?)
                            }
                            _ => return Err(bad(format!("unknown key '{key}' in [output]"))),
                        },
                        Section::Engine => {
                            let n = parse_count(&value)
                                .filter(|&n| n >= 1)
                                .ok_or_else(|| bad(format!("{key} must be an integer >= 1")))?;
                            match key.as_str() {
                                "threads" => threads = Some(n),
                                "memory_mb" => memory_mb = Some(n as u64),
                                _ => return Err(bad(format!("unknown key '{key}' in [engine]"))),
                            }
                        }
                        Section::Import | Section::Account(_) => {
                            set_import_key(&mut ImportSettings::default(), &key, &value)
                                .map_err(bad)?;
                            let target = match section {
                                Section::Account(a) => accounts.get_mut(a),
                                _ => import.as_mut(),
                            };
                            target.expect("section registered").keys.push((key, value));
                        }
                    }
                }
            }
        }
        if !seen_sections.contains(&Section::Ledger) {
            return Err("missing section [ledger]".into());
        }
        let data_dir = data_dir.ok_or("missing key data_dir in [ledger]")?;
        let config = Config {
            data_dir,
            rules_file,
            budget_file,
            format,
            threads,
            memory_mb,
            import: import.unwrap_or_default(),
            accounts,
        };
        config.validate_separators()?;
        Ok(config)
    }

    /// The decimal and thousands separators must differ in every effective
    /// setting.
    fn validate_separators(&self) -> std::result::Result<(), String> {
        let sections = std::iter::once(("[import]".to_string(), &self.import, None)).chain(
            self.accounts
                .iter()
                .map(|(a, s)| (format!("[account {a}]"), s, Some(a))),
        );
        for (name, section, account) in sections {
            let s = match account {
                Some(a) => self.import_settings(a),
                None => section.apply(&ImportSettings::default()),
            };
            if s.thousands_separator == Some(s.decimal_separator) {
                return Err(format!(
                    "line {}: {name}: decimal_separator and thousands_separator must differ",
                    section.line
                ));
            }
        }
        Ok(())
    }

    /// The effective import settings of an account: `[account NAME]` over
    /// `[import]` over the defaults.
    pub fn import_settings(&self, account: &str) -> ImportSettings {
        let general = self.import.apply(&ImportSettings::default());
        match self.accounts.get(account) {
            Some(section) => section.apply(&general),
            None => general,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(text: &str) -> std::result::Result<Config, String> {
        Config::parse(text, Path::new("/conf"))
    }

    #[test]
    fn complete_example() {
        let c = parse(
            "[ledger]\ndata_dir = ledger\nrules_file = rules.conf\n\n[import]\ndate_column = Date\n\n\
             [account visa]\ndate_format = MM/DD/YYYY\ninvert_sign = true\n\n\
             [account sparkonto]\ndelimiter = ;\ndecimal_separator = ,\nthousands_separator = .\n\
             amount_mode = debit_credit\ndebit_column = 3\n[output]\nformat = csv\n[engine]\nthreads = 2\n",
        )
        .unwrap();
        assert_eq!(c.data_dir, Path::new("/conf/ledger"));
        assert_eq!(c.rules_file.as_deref(), Some(Path::new("/conf/rules.conf")));
        assert_eq!(c.budget_file, None);
        assert_eq!(c.format, Some(Format::Csv));
        assert_eq!(c.threads, Some(2));
        let visa = c.import_settings("visa");
        assert_eq!(visa.date_format, DateFormat::MonthDayYear);
        assert!(visa.invert_sign);
        let spk = c.import_settings("sparkonto");
        assert_eq!(spk.delimiter, b';');
        assert_eq!(spk.thousands_separator, Some('.'));
        assert_eq!(spk.debit_column, ColumnRef::Position(3));
        assert_eq!(spk.amount_mode, AmountMode::DebitCredit);
        assert_eq!(c.import_settings("other"), ImportSettings::default());
    }

    #[test]
    fn errors() {
        let cases = [
            "[ledger]\ndata_dir = l\ncolour = blue\n",
            "[ledger]\ndata_dir = l\ndata_dir = m\n",
            "data_dir = l\n[ledger]\ndata_dir = l\n",
            "[ledger]\nrules_file = r\n",
            "[ledger]\ndata_dir = l\n[output]\nformat = xml\n",
            "[ledger]\ndata_dir = l\n[import]\nheader = yes\n",
            "[ledger]\ndata_dir = l\n[accounts]\n",
            "[ledger]\ndata_dir = l\n[ledger]\n",
            "[ledger]\ndata_dir = l\n[account Visa]\n",
            "[ledger]\ndata_dir = l\n[account eu]\ndecimal_separator = ,\nthousands_separator = ,\n",
            "[ledger]\ndata_dir = l\n[import]\nthousands_separator = ,\n[account eu]\ndecimal_separator = ,\n",
            "[ledger]\ndata_dir = l\n[engine]\nthreads = 0\n",
            "[ledger]\ndata_dir = l\n[import]\nskip_lines = -1\n",
            "[ledger]\ndata_dir = l\n[import]\ndate_column = 0\n",
            "[output]\nformat = csv\n",
        ];
        for text in cases {
            assert!(parse(text).is_err(), "accepted: {text}");
        }
        assert!(
            parse("[ledger]\ndata_dir = l\ncolour = blue\n")
                .unwrap_err()
                .starts_with("line 3:")
        );
    }

    #[test]
    fn names() {
        assert!(is_account_name("giro-2_x"));
        assert!(!is_account_name("Giro"));
        assert!(!is_account_name(""));
        assert!(!is_account_name(&"a".repeat(33)));
        assert!(is_category_name("groceries"));
        assert!(!is_category_name("uncategorized"));
    }
}
