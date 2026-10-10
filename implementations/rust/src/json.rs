//! Minimal strict JSON (RFC 8259) document model, parser and serializer.
//!
//! Numbers keep their literal text so that ingestion can apply the exact
//! literal-based typing rules (ingestion.md §2) and the protocol can echo
//! request ids verbatim. Object members keep their order and duplicates;
//! callers decide how to treat duplicate keys.

use std::fmt::Write as _;

#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    /// A number, stored as its (valid) JSON literal text.
    Number(String),
    String(String),
    Array(Vec<Json>),
    Object(Vec<(String, Json)>),
    /// Pre-serialized JSON text spliced verbatim into output (never produced by the parser).
    Raw(String),
}

/// Maximum nesting depth accepted by the parser (protects the stack).
const MAX_DEPTH: usize = 512;

#[derive(Debug, Clone, PartialEq)]
pub struct JsonError {
    pub message: String,
    /// Byte offset of the error in the input.
    pub offset: usize,
}

impl std::fmt::Display for JsonError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} at byte {}", self.message, self.offset)
    }
}

impl Json {
    pub fn str(s: &str) -> Json {
        Json::String(s.to_string())
    }

    pub fn int(v: i64) -> Json {
        Json::Number(v.to_string())
    }

    pub fn uint(v: u64) -> Json {
        Json::Number(v.to_string())
    }

    pub fn object(fields: Vec<(&str, Json)>) -> Json {
        Json::Object(
            fields
                .into_iter()
                .map(|(k, v)| (k.to_string(), v))
                .collect(),
        )
    }

    /// First member with the given key (objects only).
    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Object(fields) => fields.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Json::String(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Json::Bool(b) => Some(*b),
            _ => None,
        }
    }

    /// The value as an integer, if it is a number literal denoting an integer
    /// that fits in i64 (`3`, `3.0` and `3e0` all qualify).
    pub fn as_i64(&self) -> Option<i64> {
        match self {
            Json::Number(text) => {
                if let Ok(v) = text.parse::<i64>() {
                    return Some(v);
                }
                let f: f64 = text.parse().ok()?;
                if f.fract() == 0.0 && f.abs() < 9.0e15 {
                    Some(f as i64)
                } else {
                    None
                }
            }
            _ => None,
        }
    }

    pub fn as_array(&self) -> Option<&[Json]> {
        match self {
            Json::Array(items) => Some(items),
            _ => None,
        }
    }

    pub fn is_object(&self) -> bool {
        matches!(self, Json::Object(_))
    }

    /// Serializes to a single line (no raw newlines can appear).
    pub fn to_string_compact(&self) -> String {
        let mut out = String::new();
        self.write_to(&mut out);
        out
    }

    pub fn write_to(&self, out: &mut String) {
        match self {
            Json::Null => out.push_str("null"),
            Json::Bool(true) => out.push_str("true"),
            Json::Bool(false) => out.push_str("false"),
            Json::Number(n) => out.push_str(n),
            Json::String(s) => write_escaped(out, s),
            Json::Raw(r) => out.push_str(r),
            Json::Array(items) => {
                out.push('[');
                for (i, item) in items.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    item.write_to(out);
                }
                out.push(']');
            }
            Json::Object(fields) => {
                out.push('{');
                for (i, (k, v)) in fields.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    write_escaped(out, k);
                    out.push(':');
                    v.write_to(out);
                }
                out.push('}');
            }
        }
    }
}

/// Writes `s` as a JSON string literal. Escapes `"`, `\` and control
/// characters; other characters (including non-ASCII) are emitted raw.
pub fn write_escaped(out: &mut String, s: &str) {
    out.push('"');
    let mut start = 0;
    let bytes = s.as_bytes();
    for (i, &b) in bytes.iter().enumerate() {
        let esc: Option<&str> = match b {
            b'"' => Some("\\\""),
            b'\\' => Some("\\\\"),
            b'\n' => Some("\\n"),
            b'\r' => Some("\\r"),
            b'\t' => Some("\\t"),
            0x08 => Some("\\b"),
            0x0c => Some("\\f"),
            0x00..=0x1f | 0x7f => None,
            _ => continue,
        };
        out.push_str(&s[start..i]);
        match esc {
            Some(e) => out.push_str(e),
            None => {
                let _ = write!(out, "\\u{:04x}", b);
            }
        }
        start = i + 1;
    }
    out.push_str(&s[start..]);
    out.push('"');
}

/// Parses a complete JSON document (surrounding whitespace allowed).
pub fn parse(text: &str) -> Result<Json, JsonError> {
    let mut p = Parser {
        src: text.as_bytes(),
        text,
        pos: 0,
    };
    p.skip_ws();
    let v = p.value(0)?;
    p.skip_ws();
    if p.pos != p.src.len() {
        return Err(p.err("unexpected trailing characters"));
    }
    Ok(v)
}

struct Parser<'a> {
    src: &'a [u8],
    text: &'a str,
    pos: usize,
}

impl<'a> Parser<'a> {
    fn err(&self, msg: &str) -> JsonError {
        JsonError {
            message: msg.to_string(),
            offset: self.pos,
        }
    }

    fn skip_ws(&mut self) {
        while let Some(&b) = self.src.get(self.pos) {
            if b == b' ' || b == b'\t' || b == b'\n' || b == b'\r' {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn peek(&self) -> Option<u8> {
        self.src.get(self.pos).copied()
    }

    fn expect_literal(&mut self, lit: &str, v: Json) -> Result<Json, JsonError> {
        if self.src[self.pos..].starts_with(lit.as_bytes()) {
            self.pos += lit.len();
            Ok(v)
        } else {
            Err(self.err("invalid literal"))
        }
    }

    fn value(&mut self, depth: usize) -> Result<Json, JsonError> {
        if depth > MAX_DEPTH {
            return Err(self.err("nesting too deep"));
        }
        match self.peek() {
            None => Err(self.err("unexpected end of input")),
            Some(b'n') => self.expect_literal("null", Json::Null),
            Some(b't') => self.expect_literal("true", Json::Bool(true)),
            Some(b'f') => self.expect_literal("false", Json::Bool(false)),
            Some(b'"') => Ok(Json::String(self.string()?)),
            Some(b'[') => {
                self.pos += 1;
                let mut items = Vec::new();
                self.skip_ws();
                if self.peek() == Some(b']') {
                    self.pos += 1;
                    return Ok(Json::Array(items));
                }
                loop {
                    self.skip_ws();
                    items.push(self.value(depth + 1)?);
                    self.skip_ws();
                    match self.peek() {
                        Some(b',') => self.pos += 1,
                        Some(b']') => {
                            self.pos += 1;
                            return Ok(Json::Array(items));
                        }
                        _ => return Err(self.err("expected ',' or ']'")),
                    }
                }
            }
            Some(b'{') => {
                self.pos += 1;
                let mut fields = Vec::new();
                self.skip_ws();
                if self.peek() == Some(b'}') {
                    self.pos += 1;
                    return Ok(Json::Object(fields));
                }
                loop {
                    self.skip_ws();
                    if self.peek() != Some(b'"') {
                        return Err(self.err("expected object key"));
                    }
                    let key = self.string()?;
                    self.skip_ws();
                    if self.peek() != Some(b':') {
                        return Err(self.err("expected ':'"));
                    }
                    self.pos += 1;
                    self.skip_ws();
                    let v = self.value(depth + 1)?;
                    fields.push((key, v));
                    self.skip_ws();
                    match self.peek() {
                        Some(b',') => self.pos += 1,
                        Some(b'}') => {
                            self.pos += 1;
                            return Ok(Json::Object(fields));
                        }
                        _ => return Err(self.err("expected ',' or '}'")),
                    }
                }
            }
            Some(b'-' | b'0'..=b'9') => self.number(),
            Some(_) => Err(self.err("unexpected character")),
        }
    }

    fn digits(&mut self) -> usize {
        let start = self.pos;
        while matches!(self.peek(), Some(b'0'..=b'9')) {
            self.pos += 1;
        }
        self.pos - start
    }

    fn number(&mut self) -> Result<Json, JsonError> {
        let start = self.pos;
        if self.peek() == Some(b'-') {
            self.pos += 1;
        }
        match self.peek() {
            Some(b'0') => {
                self.pos += 1;
            }
            Some(b'1'..=b'9') => {
                self.digits();
            }
            _ => return Err(self.err("invalid number")),
        }
        if self.peek() == Some(b'.') {
            self.pos += 1;
            if self.digits() == 0 {
                return Err(self.err("invalid number: digits expected after '.'"));
            }
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.pos += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.pos += 1;
            }
            if self.digits() == 0 {
                return Err(self.err("invalid number: digits expected in exponent"));
            }
        }
        Ok(Json::Number(self.text[start..self.pos].to_string()))
    }

    fn hex4(&mut self) -> Result<u32, JsonError> {
        if self.pos + 4 > self.src.len() {
            return Err(self.err("truncated \\u escape"));
        }
        let h = &self.text[self.pos..self.pos + 4];
        let v = u32::from_str_radix(h, 16).map_err(|_| self.err("invalid \\u escape"))?;
        if !h.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(self.err("invalid \\u escape"));
        }
        self.pos += 4;
        Ok(v)
    }

    fn string(&mut self) -> Result<String, JsonError> {
        debug_assert_eq!(self.peek(), Some(b'"'));
        self.pos += 1;
        let mut out = String::new();
        loop {
            let start = self.pos;
            while let Some(&b) = self.src.get(self.pos) {
                if b == b'"' || b == b'\\' || b < 0x20 {
                    break;
                }
                self.pos += 1;
            }
            out.push_str(&self.text[start..self.pos]);
            match self.peek() {
                None => return Err(self.err("unterminated string")),
                Some(b'"') => {
                    self.pos += 1;
                    return Ok(out);
                }
                Some(b'\\') => {
                    self.pos += 1;
                    let c = self.peek().ok_or_else(|| self.err("unterminated escape"))?;
                    self.pos += 1;
                    match c {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{8}'),
                        b'f' => out.push('\u{c}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => {
                            let hi = self.hex4()?;
                            let cp = if (0xD800..0xDC00).contains(&hi) {
                                if !self.src[self.pos..].starts_with(b"\\u") {
                                    return Err(self.err("unpaired surrogate"));
                                }
                                self.pos += 2;
                                let lo = self.hex4()?;
                                if !(0xDC00..0xE000).contains(&lo) {
                                    return Err(self.err("invalid surrogate pair"));
                                }
                                0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)
                            } else if (0xDC00..0xE000).contains(&hi) {
                                return Err(self.err("unpaired surrogate"));
                            } else {
                                hi
                            };
                            out.push(
                                char::from_u32(cp).ok_or_else(|| self.err("invalid code point"))?,
                            );
                        }
                        _ => return Err(self.err("invalid escape")),
                    }
                }
                Some(_) => return Err(self.err("control character in string")),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_and_serializes() {
        let v = parse(r#" {"a": [1, -2.5e3, true, null], "b": "x\"yé\n"} "#).unwrap();
        assert_eq!(v.get("a").unwrap().as_array().unwrap().len(), 4);
        assert_eq!(v.get("b").unwrap().as_str().unwrap(), "x\"y\u{e9}\n");
        assert_eq!(
            v.to_string_compact(),
            r#"{"a":[1,-2.5e3,true,null],"b":"x\"yé\n"}"#
        );
    }

    #[test]
    fn rejects_invalid() {
        for bad in [
            "",
            "[1,]",
            "{\"a\":1,}",
            "NaN",
            "01",
            "1.",
            ".5",
            "\"a",
            "{'a':1}",
            "[1] x",
            "\"\u{1}\"",
        ] {
            assert!(parse(bad).is_err(), "{bad} should fail");
        }
    }

    #[test]
    fn surrogate_pairs() {
        assert_eq!(parse(r#""😀""#).unwrap(), Json::String("😀".to_string()));
        assert!(parse(r#""\ud83d""#).is_err());
    }

    #[test]
    fn deep_nesting_is_rejected() {
        let s = "[".repeat(10_000);
        assert!(parse(&s).is_err());
    }

    #[test]
    fn integer_access() {
        assert_eq!(parse("42").unwrap().as_i64(), Some(42));
        assert_eq!(parse("4.5").unwrap().as_i64(), None);
        assert_eq!(parse("\"4\"").unwrap().as_i64(), None);
    }
}
