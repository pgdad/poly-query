//! Proleptic Gregorian DATE (days since 1970-01-01) and TIMESTAMP
//! (microseconds since 1970-01-01 00:00:00) parsing and formatting.

pub const MICROS_PER_SECOND: i64 = 1_000_000;
pub const MICROS_PER_DAY: i64 = 86_400 * MICROS_PER_SECOND;

/// Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm).
pub fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let m = m as i64;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// Civil date (year, month, day) for days since 1970-01-01.
pub fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

pub fn is_leap(y: i64) -> bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

pub fn days_in_month(y: i64, m: u32) -> u32 {
    match m {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if is_leap(y) => 29,
        2 => 28,
        _ => 0,
    }
}

fn digits(b: &[u8]) -> Option<u32> {
    let mut v = 0u32;
    for &c in b {
        if !c.is_ascii_digit() {
            return None;
        }
        v = v * 10 + (c - b'0') as u32;
    }
    Some(v)
}

/// Parses exactly `YYYY-MM-DD` (valid calendar date, years 0001–9999).
pub fn parse_date(s: &str) -> Option<i32> {
    let b = s.as_bytes();
    if b.len() != 10 || b[4] != b'-' || b[7] != b'-' {
        return None;
    }
    let y = digits(&b[0..4])?;
    let m = digits(&b[5..7])?;
    let d = digits(&b[8..10])?;
    if y < 1 || !(1..=12).contains(&m) || d < 1 || d > days_in_month(y as i64, m) {
        return None;
    }
    Some(days_from_civil(y as i64, m, d) as i32)
}

/// Parses exactly `YYYY-MM-DD[ T]HH:MM:SS[.f{1,6}]`.
pub fn parse_timestamp(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    if b.len() < 19 || (b[10] != b' ' && b[10] != b'T') {
        return None;
    }
    let days = parse_date(&s[..10])? as i64;
    if b[13] != b':' || b[16] != b':' {
        return None;
    }
    let h = digits(&b[11..13])?;
    let mi = digits(&b[14..16])?;
    let sec = digits(&b[17..19])?;
    if h > 23 || mi > 59 || sec > 59 {
        return None;
    }
    let mut micros = 0i64;
    if b.len() > 19 {
        if b[19] != b'.' {
            return None;
        }
        let frac = &b[20..];
        if frac.is_empty() || frac.len() > 6 {
            return None;
        }
        micros = digits(frac)? as i64 * 10i64.pow(6 - frac.len() as u32);
    }
    Some(
        days * MICROS_PER_DAY
            + ((h as i64 * 60 + mi as i64) * 60 + sec as i64) * MICROS_PER_SECOND
            + micros,
    )
}

/// Parses timestamp text, also accepting a bare date (midnight).
pub fn parse_date_or_timestamp(s: &str) -> Option<i64> {
    if s.len() == 10 {
        parse_date(s).map(|d| d as i64 * MICROS_PER_DAY)
    } else {
        parse_timestamp(s)
    }
}

pub fn format_date(days: i32) -> String {
    let (y, m, d) = civil_from_days(days as i64);
    format!("{y:04}-{m:02}-{d:02}")
}

pub fn format_timestamp(micros: i64) -> String {
    let days = micros.div_euclid(MICROS_PER_DAY);
    let rem = micros.rem_euclid(MICROS_PER_DAY);
    let (y, m, d) = civil_from_days(days);
    let secs = rem / MICROS_PER_SECOND;
    let frac = rem % MICROS_PER_SECOND;
    let (h, mi, s) = (secs / 3600, (secs / 60) % 60, secs % 60);
    if frac == 0 {
        format!("{y:04}-{m:02}-{d:02} {h:02}:{mi:02}:{s:02}")
    } else {
        format!("{y:04}-{m:02}-{d:02} {h:02}:{mi:02}:{s:02}.{frac:06}")
    }
}

/// The date part of a timestamp (floor to the day).
pub fn timestamp_to_date(micros: i64) -> i32 {
    micros.div_euclid(MICROS_PER_DAY) as i32
}

pub fn date_to_timestamp(days: i32) -> i64 {
    days as i64 * MICROS_PER_DAY
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn civil_roundtrip() {
        for z in [-719_162i64, -1, 0, 1, 19_000, 2_932_896] {
            let (y, m, d) = civil_from_days(z);
            assert_eq!(days_from_civil(y, m, d), z);
        }
        assert_eq!(days_from_civil(1970, 1, 1), 0);
        assert_eq!(days_from_civil(1, 1, 1), -719_162);
    }

    #[test]
    fn parse_and_format() {
        assert_eq!(format_date(parse_date("2024-02-29").unwrap()), "2024-02-29");
        assert!(parse_date("2023-02-29").is_none());
        assert!(parse_date("0000-01-01").is_none());
        assert!(parse_date("2024-1-01").is_none());
        assert_eq!(format_date(parse_date("0001-01-01").unwrap()), "0001-01-01");
        let ts = parse_timestamp("2024-02-29 13:14:15.5").unwrap();
        assert_eq!(format_timestamp(ts), "2024-02-29 13:14:15.500000");
        assert_eq!(
            format_timestamp(parse_timestamp("2024-01-01T00:00:00").unwrap()),
            "2024-01-01 00:00:00"
        );
        assert!(parse_timestamp("2023-01-01 25:00:00").is_none());
        assert!(parse_timestamp("2023-01-01 10:00:00.").is_none());
        assert!(parse_timestamp("2023-01-01 10:00:00.1234567").is_none());
        assert_eq!(
            format_timestamp(parse_timestamp("9999-12-31 23:59:59.999999").unwrap()),
            "9999-12-31 23:59:59.999999"
        );
        assert_eq!(
            format_timestamp(parse_timestamp("1969-12-31 23:59:59.5").unwrap()),
            "1969-12-31 23:59:59.500000"
        );
        assert_eq!(
            timestamp_to_date(parse_timestamp("1969-12-31 23:59:59").unwrap()),
            -1
        );
    }
}
