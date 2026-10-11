//! Exact fixed-point decimal helpers. A DECIMAL value is an unscaled integer
//! with at most 38 digits plus a scale, held in an i128 (10^38 < 2^127);
//! intermediates that may exceed i128 use [`I256`].

use super::i256::I256;

/// Largest unscaled magnitude representable with 18 digits.
pub const MAX_UNSCALED: i128 = 999_999_999_999_999_999;

/// Precision limit of a narrow decimal (and of narrow results).
pub const NARROW_PRECISION: u8 = 18;

/// 10^n as i128 (n ≤ 38).
pub fn pow10(n: u32) -> i128 {
    10i128.pow(n)
}

/// True if `v` has at most `precision` digits.
pub fn fits_precision(v: i128, precision: u8) -> bool {
    v.unsigned_abs() < pow10(precision as u32) as u128
}

/// True if `v` fits in DECIMAL(18, s) for any s.
pub fn fits18(v: i128) -> bool {
    (-MAX_UNSCALED..=MAX_UNSCALED).contains(&v)
}

/// True if a 256-bit intermediate has at most `precision` digits.
pub fn fits_precision_wide(v: I256, precision: u8) -> bool {
    v.to_i128().is_some_and(|x| fits_precision(x, precision))
}

/// Divides `v` by 10^`digits`, rounding half away from zero.
pub fn div_pow10_round(v: i128, digits: u32) -> i128 {
    if digits == 0 {
        return v;
    }
    if digits > 38 {
        return 0;
    }
    let d = pow10(digits);
    let q = v / d;
    let r = v % d;
    if r.unsigned_abs() * 2 >= d.unsigned_abs() {
        if v < 0 { q - 1 } else { q + 1 }
    } else {
        q
    }
}

/// Changes the scale of an unscaled value, rounding half away from zero when
/// the scale decreases. Returns None if an intermediate overflows i128.
pub fn rescale(v: i128, from: u8, to: u8) -> Option<i128> {
    if to >= from {
        v.checked_mul(pow10((to - from) as u32))
    } else {
        Some(div_pow10_round(v, (from - to) as u32))
    }
}

/// Compares two decimals with possibly different scales exactly (scales
/// ≤ 38, so each side is multiplied by at most 10^38).
pub fn compare(a: i128, sa: u8, b: i128, sb: u8) -> std::cmp::Ordering {
    let s = sa.max(sb);
    let (fa, fb) = (pow10((s - sa) as u32), pow10((s - sb) as u32));
    match (a.checked_mul(fa), b.checked_mul(fb)) {
        (Some(x), Some(y)) => x.cmp(&y),
        _ => I256::mul_i128(a, fa).cmp(&I256::mul_i128(b, fb)),
    }
}

/// `a ± b` at scale max(sa, sb), exact; None if the result needs more than
/// `precision` digits.
pub fn add(a: i128, sa: u8, b: i128, sb: u8, subtract: bool, precision: u8) -> Option<(i128, u8)> {
    let s = sa.max(sb);
    let (fa, fb) = (pow10((s - sa) as u32), pow10((s - sb) as u32));
    let fast = a.checked_mul(fa).zip(b.checked_mul(fb)).and_then(|(x, y)| {
        if subtract {
            x.checked_sub(y)
        } else {
            x.checked_add(y)
        }
    });
    let v = match fast {
        Some(v) => v,
        None => {
            let (x, y) = (I256::mul_i128(a, fa), I256::mul_i128(b, fb));
            let r = if subtract {
                x.wrapping_sub(y)
            } else {
                x.wrapping_add(y)
            };
            r.to_i128()?
        }
    };
    fits_precision(v, precision).then_some((v, s))
}

/// `a * b` (scale sa + sb), exact; None if the result needs more than
/// `precision` digits.
pub fn mul(a: i128, b: i128, precision: u8) -> Option<i128> {
    let v = match a.checked_mul(b) {
        Some(v) => v,
        None => I256::mul_i128(a, b).to_i128()?,
    };
    fits_precision(v, precision).then_some(v)
}

/// Appends the decimal digits of `v` (no allocation).
pub fn write_u64(out: &mut String, v: u64) {
    write_u128(out, v as u128);
}

fn write_u128(out: &mut String, mut v: u128) {
    let mut buf = [0u8; 40];
    let mut i = buf.len();
    loop {
        i -= 1;
        buf[i] = b'0' + (v % 10) as u8;
        v /= 10;
        if v == 0 {
            break;
        }
    }
    out.push_str(std::str::from_utf8(&buf[i..]).unwrap_or_default());
}

/// Appends a signed integer.
pub fn write_i64(out: &mut String, v: i64) {
    if v < 0 {
        out.push('-');
    }
    write_u64(out, v.unsigned_abs());
}

/// Appends the canonical text of a decimal (see [`format`]) without
/// allocating.
pub fn write(out: &mut String, unscaled: i128, scale: u8) {
    if unscaled < 0 {
        out.push('-');
    }
    let mut buf = [0u8; 40];
    let mut i = buf.len();
    let mut v = unscaled.unsigned_abs();
    loop {
        i -= 1;
        buf[i] = b'0' + (v % 10) as u8;
        v /= 10;
        if v == 0 {
            break;
        }
    }
    let digits = std::str::from_utf8(&buf[i..]).unwrap_or_default();
    let scale = scale as usize;
    if scale == 0 {
        out.push_str(digits);
    } else if digits.len() > scale {
        let (int, frac) = digits.split_at(digits.len() - scale);
        out.push_str(int);
        out.push('.');
        out.push_str(frac);
    } else {
        out.push_str("0.");
        for _ in 0..scale - digits.len() {
            out.push('0');
        }
        out.push_str(digits);
    }
}

/// Canonical text: exactly `scale` fractional digits, at least one integer digit.
pub fn format(unscaled: i128, scale: u8) -> String {
    let mut out = String::with_capacity(44);
    write(&mut out, unscaled, scale);
    out
}

/// Converts to the nearest f64.
pub fn to_f64(unscaled: i128, scale: u8) -> f64 {
    if unscaled.unsigned_abs() < (1u128 << 53) && scale <= 22 {
        // Both operands are exact, so the division is correctly rounded.
        unscaled as f64 / 10f64.powi(scale as i32)
    } else {
        // Rust's float parser is correctly rounded.
        format(unscaled, scale).parse().unwrap_or(0.0)
    }
}

/// Nearest f64 of a 256-bit unscaled value at `scale` (exact sums).
pub fn wide_to_f64(unscaled: I256, scale: u8) -> f64 {
    match unscaled.to_i128() {
        Some(v) => to_f64(v, scale),
        None => format!("{}e-{scale}", unscaled.to_decimal_string())
            .parse()
            .unwrap_or(0.0),
    }
}

/// Decimal text split into parts: `[+-]?(digits(.digits*)?|.digits)`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DecimalText<'a> {
    pub negative: bool,
    /// Integer digits with leading zeros removed.
    pub int_digits: &'a str,
    /// Fractional digits (verbatim, including trailing zeros).
    pub frac_digits: &'a str,
}

/// Parses decimal text (no exponent). Returns None if the syntax is invalid.
pub fn parse_text(s: &str) -> Option<DecimalText<'_>> {
    let (negative, body) = match s.as_bytes().first() {
        Some(b'-') => (true, &s[1..]),
        Some(b'+') => (false, &s[1..]),
        _ => (false, s),
    };
    let (int, frac) = match body.find('.') {
        Some(dot) => (&body[..dot], &body[dot + 1..]),
        None => (body, ""),
    };
    if int.is_empty() && frac.is_empty() {
        return None;
    }
    if !int.bytes().all(|b| b.is_ascii_digit()) || !frac.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    if int.is_empty() && !body.starts_with('.') {
        return None;
    }
    Some(DecimalText {
        negative,
        int_digits: int.trim_start_matches('0'),
        frac_digits: frac,
    })
}

/// Outcome of converting decimal text to a fixed scale.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TextToDecimal {
    Ok(i128),
    /// More fractional digits than the scale allows (only with `exact`).
    TooPrecise,
    /// The value does not fit the precision.
    Overflow,
}

/// Converts parsed decimal text to an unscaled value at `scale`, checking
/// `precision`. With `exact`, extra fractional digits are an error
/// (ingestion); otherwise they are rounded half away from zero (CAST).
pub fn text_to_unscaled(
    t: &DecimalText<'_>,
    precision: u8,
    scale: u8,
    exact: bool,
) -> TextToDecimal {
    let scale_us = scale as usize;
    if t.int_digits.len() > precision as usize {
        return TextToDecimal::Overflow;
    }
    if exact && t.frac_digits.len() > scale_us {
        return TextToDecimal::TooPrecise;
    }
    // Integer digits beyond precision - scale cannot fit (and could overflow
    // the accumulator below).
    if t.int_digits.len() > (precision - scale) as usize {
        return TextToDecimal::Overflow;
    }
    let mut v: i128 = 0;
    for b in t.int_digits.bytes() {
        v = v * 10 + (b - b'0') as i128;
    }
    let frac = t.frac_digits.as_bytes();
    for i in 0..scale_us {
        let d = frac.get(i).map(|b| (b - b'0') as i128).unwrap_or(0);
        v = v * 10 + d;
    }
    if frac.len() > scale_us {
        if exact {
            return TextToDecimal::TooPrecise;
        }
        if frac[scale_us] >= b'5' {
            v += 1;
        }
    }
    if !fits_precision(v, precision) {
        return TextToDecimal::Overflow;
    }
    TextToDecimal::Ok(if t.negative { -v } else { v })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formatting() {
        assert_eq!(format(150, 2), "1.50");
        assert_eq!(format(-5, 2), "-0.05");
        assert_eq!(format(12, 0), "12");
        assert_eq!(format(0, 3), "0.000");
        assert_eq!(format(-4010, 2), "-40.10");
    }

    #[test]
    fn rounding() {
        assert_eq!(div_pow10_round(2345, 1), 235);
        assert_eq!(div_pow10_round(-2345, 1), -235);
        assert_eq!(div_pow10_round(2344, 1), 234);
        assert_eq!(rescale(25, 1, 0), Some(3));
    }

    #[test]
    fn text_conversion() {
        let t = parse_text("1.005").unwrap();
        assert_eq!(text_to_unscaled(&t, 4, 2, false), TextToDecimal::Ok(101));
        assert_eq!(text_to_unscaled(&t, 4, 2, true), TextToDecimal::TooPrecise);
        let t = parse_text("+7").unwrap();
        assert_eq!(text_to_unscaled(&t, 4, 1, true), TextToDecimal::Ok(70));
        let t = parse_text("123.4").unwrap();
        assert_eq!(text_to_unscaled(&t, 3, 1, true), TextToDecimal::Overflow);
        assert!(parse_text(".").is_none());
        assert!(parse_text("1e5").is_none());
        assert!(parse_text("-").is_none());
        assert!(parse_text("7.").is_some());
        assert!(parse_text(".5").is_some());
    }

    #[test]
    fn comparison() {
        assert_eq!(compare(150, 2, 15, 1), std::cmp::Ordering::Equal);
        assert_eq!(compare(-1, 0, 5, 1), std::cmp::Ordering::Less);
        let big = pow10(38) - 1;
        assert_eq!(compare(big, 0, 1, 38), std::cmp::Ordering::Greater);
        assert_eq!(compare(-big, 0, 1, 38), std::cmp::Ordering::Less);
    }

    #[test]
    fn wide_arithmetic() {
        // 2e37 (scale 0) - 1.5e37 (scale 1): the rescaled operand exceeds
        // i128 but the exact result fits 38 digits.
        let a = 2 * pow10(37);
        let b = -15 * pow10(37);
        assert_eq!(add(a, 0, b, 1, false, 38), Some((5 * pow10(37), 1)));
        assert_eq!(
            add(pow10(38) - 2, 0, 1, 0, false, 38),
            Some((pow10(38) - 1, 0))
        );
        assert_eq!(add(pow10(38) - 2, 0, 2, 0, false, 38), None);
        assert_eq!(add(MAX_UNSCALED, 0, 1, 0, false, 18), None);
        assert_eq!(mul(pow10(20), pow10(19), 38), None);
        assert_eq!(mul(pow10(20), pow10(17), 38), Some(pow10(37)));
        assert_eq!(format(-(pow10(38) - 1), 10).len(), 40);
    }
}
