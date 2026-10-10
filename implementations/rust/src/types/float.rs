//! FLOAT64 text parsing/formatting and exact float→decimal rounding.

use super::decimal;

/// True if `s` matches `[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?`.
pub fn is_float_syntax(s: &str) -> bool {
    let b = s.as_bytes();
    let mut i = 0;
    if matches!(b.first(), Some(b'+' | b'-')) {
        i += 1;
    }
    let int_start = i;
    while i < b.len() && b[i].is_ascii_digit() {
        i += 1;
    }
    let int_len = i - int_start;
    let mut frac_len = 0;
    if i < b.len() && b[i] == b'.' {
        i += 1;
        let fs = i;
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
        }
        frac_len = i - fs;
    }
    if int_len == 0 && frac_len == 0 {
        return false;
    }
    if i < b.len() && (b[i] == b'e' || b[i] == b'E') {
        i += 1;
        if i < b.len() && (b[i] == b'+' || b[i] == b'-') {
            i += 1;
        }
        let es = i;
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
        }
        if i == es {
            return false;
        }
    }
    i == b.len()
}

/// Parses float text with the syntax above. Returns `Err(true)` for a
/// syntactically valid but non-finite value, `Err(false)` for bad syntax.
pub fn parse_float(s: &str) -> Result<f64, bool> {
    if !is_float_syntax(s) {
        return Err(false);
    }
    // Rust's parser accepts this syntax (including "1." and ".5").
    let v: f64 = s.parse().map_err(|_| false)?;
    if v.is_finite() {
        Ok(normalize(v))
    } else {
        Err(true)
    }
}

/// Normalizes -0.0 to 0.0.
pub fn normalize(v: f64) -> f64 {
    if v == 0.0 { 0.0 } else { v }
}

/// Round-trip text for a finite float (`0.1`, `3.0`, `1.5e300`).
pub fn format_f64(v: f64) -> String {
    let v = normalize(v);
    if v == 0.0 {
        return "0.0".to_string();
    }
    let a = v.abs();
    if !(1e-5..1e16).contains(&a) {
        format!("{v:e}")
    } else {
        let s = format!("{v}");
        if s.contains('.') { s } else { s + ".0" }
    }
}

/// Converts a finite float to an unscaled decimal at `scale`, rounding half
/// away from zero based on the shortest round-trip decimal representation.
/// Returns None if the result has more than `precision` digits.
pub fn f64_to_decimal(v: f64, precision: u8, scale: u8) -> Option<i64> {
    let v = normalize(v);
    if v == 0.0 {
        return Some(0);
    }
    // "{:e}" yields the shortest round-trip digits: d[.ddd]e[-]x
    let text = format!("{:e}", v.abs());
    let (mant, exp) = text.split_once('e')?;
    let exp: i64 = exp.parse().ok()?;
    let digits: String = mant.chars().filter(|c| *c != '.').collect();
    // value = digits * 10^(exp - (len-1)); scaled = value * 10^scale
    let shift = exp - (digits.len() as i64 - 1) + scale as i64;
    let mut m: i128 = digits.parse().ok()?;
    let unscaled = if shift >= 0 {
        if shift > 20 {
            return None;
        }
        m = m.checked_mul(decimal::pow10(shift as u32))?;
        m
    } else {
        let down = (-shift) as u32;
        if down > 38 {
            0
        } else {
            decimal::div_pow10_round(m, down)
        }
    };
    if !decimal::fits_precision(unscaled, precision) {
        return None;
    }
    Some(if v < 0.0 {
        -(unscaled as i64)
    } else {
        unscaled as i64
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn syntax() {
        for ok in ["1", "-1.5", "+.5", "3.", "1e10", "2.5E-3", "1.e5"] {
            assert!(is_float_syntax(ok), "{ok}");
        }
        for bad in ["", ".", "e5", "1e", "NaN", "inf", "1.5.2", " 1", "0x10"] {
            assert!(!is_float_syntax(bad), "{bad}");
        }
        assert_eq!(parse_float("1e999"), Err(true));
        assert_eq!(parse_float("NaN"), Err(false));
    }

    #[test]
    fn formatting() {
        assert_eq!(format_f64(-0.0), "0.0");
        assert_eq!(format_f64(3.0), "3.0");
        assert_eq!(format_f64(0.1), "0.1");
        assert_eq!(format_f64(1.5e300), "1.5e300");
        assert_eq!(format_f64(2.5e-300), "2.5e-300");
        for v in [1e16, 123456789.123, 1e-7, 0.00001] {
            assert_eq!(format_f64(v).parse::<f64>().unwrap(), v);
        }
    }

    #[test]
    fn to_decimal() {
        assert_eq!(f64_to_decimal(2.5, 3, 0), Some(3));
        assert_eq!(f64_to_decimal(-2.5, 3, 0), Some(-3));
        assert_eq!(f64_to_decimal(1.005, 4, 2), Some(101));
        assert_eq!(f64_to_decimal(1e19, 18, 0), None);
        assert_eq!(f64_to_decimal(0.0001, 5, 2), Some(0));
        assert_eq!(f64_to_decimal(123.456, 6, 3), Some(123456));
    }
}
