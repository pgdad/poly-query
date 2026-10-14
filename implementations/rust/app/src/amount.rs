//! Money amounts as integer cents: parsing bank amount fields
//! (spec/apps/pqledger.md §6.2) and budget amounts (§5.2).

use crate::config::ImportSettings;

/// Largest absolute amount that fits `DECIMAL(18,2)`, in cents.
pub const MAX_CENTS: i64 = 999_999_999_999_999_999;

/// Parses `[0-9]+(\.[0-9]{1,2})?` with at most 16 integer digits into
/// cents.
pub fn parse_plain(text: &str) -> Option<i64> {
    let (int, frac) = match text.split_once('.') {
        Some((i, f)) => (i, Some(f)),
        None => (text, None),
    };
    if int.is_empty() || int.len() > 16 || !int.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let mut cents: i64 = int.parse::<i64>().ok()? * 100;
    if let Some(f) = frac {
        if f.is_empty() || f.len() > 2 || !f.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        let digits: i64 = f.parse().ok()?;
        cents += if f.len() == 1 { digits * 10 } else { digits };
    }
    Some(cents)
}

/// Converts one amount field with the account's settings (sign,
/// parentheses, currency symbol, separators); `invert_sign` is not applied
/// here. Returns cents.
pub fn parse_field(field: &str, s: &ImportSettings) -> Result<i64, String> {
    let bad = || format!("invalid amount '{field}'");
    let mut text = crate::ini::trim_blanks(field);
    let mut negative = false;
    if let Some(inner) = text.strip_prefix('(').and_then(|t| t.strip_suffix(')')) {
        negative = true;
        text = inner;
    } else if let Some(rest) = text.strip_prefix('-') {
        negative = true;
        text = rest;
    } else if let Some(rest) = text.strip_prefix('+') {
        text = rest;
    }
    let symbol = s.currency_symbol.as_str();
    if !symbol.is_empty() {
        if let Some(rest) = text.strip_prefix(symbol) {
            text = rest;
        } else if let Some(rest) = text.strip_suffix(symbol) {
            text = rest;
        }
    }
    let mut normalized: String = crate::ini::trim_blanks(text).to_string();
    if let Some(sep) = s.thousands_separator {
        normalized.retain(|c| c != sep);
    }
    if s.decimal_separator != '.' {
        normalized = normalized.replace(s.decimal_separator, ".");
    }
    let cents = parse_plain(&normalized).ok_or_else(bad)?;
    Ok(if negative { -cents } else { cents })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_amounts() {
        assert_eq!(parse_plain("0"), Some(0));
        assert_eq!(parse_plain("12.5"), Some(1250));
        assert_eq!(parse_plain("12.05"), Some(1205));
        assert_eq!(
            parse_plain("9999999999999999.99"),
            Some(999_999_999_999_999_999)
        );
        for bad in [
            "",
            ".5",
            "1.",
            "1.234",
            "+1",
            "-1",
            "1e5",
            "12345678901234567",
            "1,00",
        ] {
            assert_eq!(parse_plain(bad), None, "{bad}");
        }
    }

    fn settings(decimal: char, thousands: Option<char>, symbol: &str) -> ImportSettings {
        ImportSettings {
            decimal_separator: decimal,
            thousands_separator: thousands,
            currency_symbol: symbol.into(),
            ..ImportSettings::default()
        }
    }

    #[test]
    fn fields() {
        let us = settings('.', Some(','), "$");
        assert_eq!(parse_field(" $1,234.56 ", &us), Ok(123_456));
        assert_eq!(parse_field("($31.06)", &us), Ok(-3106));
        assert_eq!(parse_field("-$5", &us), Ok(-500));
        assert_eq!(parse_field("+5.10$", &us), Ok(510));
        assert_eq!(parse_field("-0.00", &us), Ok(0));
        assert!(parse_field("$-5", &us).is_err());
        assert!(parse_field("", &us).is_err());
        let de = settings(',', Some('.'), "EUR");
        assert_eq!(parse_field("1.120,00", &de), Ok(112_000));
        assert_eq!(parse_field("71,8 EUR", &de), Ok(7180));
        let ch = settings('.', Some('\''), "");
        assert_eq!(parse_field("1'000.5", &ch), Ok(100_050));
        let fr = settings(',', Some(' '), "€");
        assert_eq!(parse_field("€ 1 000,25", &fr), Ok(100_025));
    }
}
