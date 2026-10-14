//! The category rules file and the budget file (spec/apps/pqledger.md §5).

use std::path::Path;

use polyquery::api::Decimal;

use crate::amount;
use crate::config::is_category_name;
use crate::error::{AppError, Result};
use crate::ini::{self, Line};

/// One pattern of the rules file; its position in the list is its rule
/// number − 1.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rule {
    pub category: String,
    /// The pattern as written, ASCII upper-cased (`*` and `?` wildcards).
    pub pattern: String,
}

/// A monthly budget of one category.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Budget {
    pub category: String,
    pub amount: Decimal,
}

fn read(path: &Path, what: &str) -> Result<Vec<ini::Numbered>> {
    let display = path.display();
    let bytes = std::fs::read(path)
        .map_err(|e| AppError::config(format!("cannot read {what} '{display}': {e}")))?;
    let text = String::from_utf8(bytes)
        .map_err(|_| AppError::config(format!("{display}: not valid UTF-8")))?;
    ini::parse(&text).map_err(|m| AppError::config(format!("{display}: {m}")))
}

/// Reads a rules file: lines `CATEGORY = PATTERN [, PATTERN …]`.
pub fn load_rules(path: &Path) -> Result<Vec<Rule>> {
    let lines = read(path, "rules file")?;
    parse_rules(lines).map_err(|m| AppError::config(format!("{}: {m}", path.display())))
}

fn parse_rules(lines: Vec<ini::Numbered>) -> std::result::Result<Vec<Rule>, String> {
    let mut rules = Vec::new();
    for ini::Numbered { number, line } in lines {
        let (category, patterns) = assignment(number, line)?;
        for pattern in patterns.split(',') {
            let pattern = ini::trim_blanks(pattern);
            if pattern.is_empty() {
                return Err(format!("line {number}: empty pattern"));
            }
            if pattern.contains(['%', '_']) {
                return Err(format!(
                    "line {number}: pattern '{pattern}' contains '%' or '_'"
                ));
            }
            rules.push(Rule {
                category: category.clone(),
                pattern: pattern.to_ascii_uppercase(),
            });
        }
    }
    Ok(rules)
}

/// Reads a budget file: lines `CATEGORY = AMOUNT`.
pub fn load_budgets(path: &Path) -> Result<Vec<Budget>> {
    let lines = read(path, "budget file")?;
    parse_budgets(lines).map_err(|m| AppError::config(format!("{}: {m}", path.display())))
}

fn parse_budgets(lines: Vec<ini::Numbered>) -> std::result::Result<Vec<Budget>, String> {
    let mut budgets: Vec<Budget> = Vec::new();
    for ini::Numbered { number, line } in lines {
        let (category, value) = assignment(number, line)?;
        let cents = amount::parse_plain(&value)
            .ok_or_else(|| format!("line {number}: invalid budget amount '{value}'"))?;
        if budgets.iter().any(|b| b.category == category) {
            return Err(format!("line {number}: category '{category}' listed twice"));
        }
        budgets.push(Budget {
            category,
            amount: Decimal::new(cents as i128, 2),
        });
    }
    Ok(budgets)
}

/// A `CATEGORY = VALUE` line with a valid category name.
fn assignment(number: usize, line: Line) -> std::result::Result<(String, String), String> {
    match line {
        Line::Section(_) => Err(format!("line {number}: sections are not allowed here")),
        Line::Assignment { key, value } => {
            if !is_category_name(&key) {
                return Err(format!("line {number}: invalid category name '{key}'"));
            }
            Ok((key, value))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rules(text: &str) -> std::result::Result<Vec<Rule>, String> {
        parse_rules(ini::parse(text)?)
    }

    fn budgets(text: &str) -> std::result::Result<Vec<Budget>, String> {
        parse_budgets(ini::parse(text)?)
    }

    #[test]
    fn rules_in_file_order() {
        let r =
            rules("# x\ngroceries = Whole Foods*, safeway\ncoffee = CAFé*\ngroceries = rewe?\n")
                .unwrap();
        let flat: Vec<_> = r
            .iter()
            .map(|r| (r.category.as_str(), r.pattern.as_str()))
            .collect();
        assert_eq!(
            flat,
            [
                ("groceries", "WHOLE FOODS*"),
                ("groceries", "SAFEWAY"),
                ("coffee", "CAFé*"),
                ("groceries", "REWE?")
            ]
        );
    }

    #[test]
    fn invalid_rules() {
        assert!(rules("groceries = SAFE_WAY\n").is_err());
        assert!(rules("groceries = 50%\n").is_err());
        assert!(rules("groceries = a,,b\n").is_err());
        assert!(rules("groceries =\n").is_err());
        assert!(rules("Groceries = a\n").is_err());
        assert!(rules("uncategorized = a\n").is_err());
        assert!(rules("[x]\n").is_err());
        assert!(rules("groceries\n").is_err());
    }

    #[test]
    fn budget_amounts() {
        let b = budgets("groceries = 600\ncoffee = 30.5\n").unwrap();
        assert_eq!(b[0].amount.to_string(), "600.00");
        assert_eq!(b[1].amount.to_string(), "30.50");
        assert!(budgets("groceries = 12.345\n").is_err());
        assert!(budgets("groceries = -1\n").is_err());
        assert!(budgets("groceries = 1\ngroceries = 2\n").is_err());
        assert!(budgets("groceries = 12345678901234567\n").is_err());
    }
}
