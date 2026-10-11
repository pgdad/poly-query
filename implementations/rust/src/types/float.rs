//! FLOAT64 text parsing/formatting and exact float→decimal rounding.

use super::decimal;
use super::i256::I256;

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

/// Converts a finite float to an unscaled decimal at `scale`, using the
/// exact binary value of the double and rounding half away from zero
/// (CR-2 §5). Returns None if the result has more than `precision` digits.
pub fn f64_to_decimal(v: f64, precision: u8, scale: u8) -> Option<i128> {
    let v = normalize(v);
    if v == 0.0 {
        return Some(0);
    }
    if !v.is_finite() {
        return None;
    }
    // v = mantissa * 2^exp exactly.
    let bits = v.to_bits();
    let raw_exp = ((bits >> 52) & 0x7ff) as i32;
    let frac = (bits & ((1u64 << 52) - 1)) as i128;
    let (mantissa, exp) = if raw_exp == 0 {
        (frac, -1074)
    } else {
        (frac | 1 << 52, raw_exp - 1075)
    };
    let mantissa = if v < 0.0 { -mantissa } else { mantissa };
    // unscaled = mantissa * 10^scale * 2^exp, rounded.
    let scaled = I256::mul_i128(mantissa, decimal::pow10(scale as u32));
    let unscaled = if exp >= 0 {
        scaled.checked_shl(exp as u32)?
    } else {
        scaled.shr_round((-exp) as u32)
    };
    let unscaled = unscaled.to_i128()?;
    decimal::fits_precision(unscaled, precision).then_some(unscaled)
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
        // 1.005 is 1.00499999999999989... in binary.
        assert_eq!(f64_to_decimal(1.005, 4, 2), Some(100));
        assert_eq!(f64_to_decimal(1.125, 4, 2), Some(113));
        assert_eq!(f64_to_decimal(-1.125, 4, 2), Some(-113));
        assert_eq!(
            f64_to_decimal(0.1, 38, 30),
            Some(100_000_000_000_000_005_551_115_123_126)
        );
        assert_eq!(
            f64_to_decimal(1e30, 38, 0),
            Some(1_000_000_000_000_000_019_884_624_838_656)
        );
        assert_eq!(f64_to_decimal(1e19, 18, 0), None);
        assert_eq!(f64_to_decimal(0.0001, 5, 2), Some(0));
        assert_eq!(f64_to_decimal(123.456, 6, 3), Some(123456));
    }
}
