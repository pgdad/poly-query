//! Structured JSON-lines logging to stderr (protocol.md §7.4).

use std::io::Write;
use std::sync::atomic::{AtomicU8, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::json::Json;
use crate::types::datetime;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum LogLevel {
    Debug = 0,
    Info = 1,
    Warn = 2,
    Error = 3,
    Off = 4,
}

impl LogLevel {
    pub fn parse(s: &str) -> Option<LogLevel> {
        match s {
            "debug" => Some(LogLevel::Debug),
            "info" => Some(LogLevel::Info),
            "warn" => Some(LogLevel::Warn),
            "error" => Some(LogLevel::Error),
            "off" => Some(LogLevel::Off),
            _ => None,
        }
    }

    fn name(self) -> &'static str {
        match self {
            LogLevel::Debug => "debug",
            LogLevel::Info => "info",
            LogLevel::Warn => "warn",
            LogLevel::Error => "error",
            LogLevel::Off => "off",
        }
    }
}

static LEVEL: AtomicU8 = AtomicU8::new(LogLevel::Info as u8);

pub fn set_level(level: LogLevel) {
    LEVEL.store(level as u8, Ordering::Relaxed);
}

pub fn enabled(level: LogLevel) -> bool {
    level != LogLevel::Off && level as u8 >= LEVEL.load(Ordering::Relaxed)
}

/// RFC 3339 UTC timestamp with millisecond precision.
pub fn now_rfc3339() -> String {
    let d = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let micros = d.as_micros() as i64;
    let text = datetime::format_timestamp(micros - micros % 1000);
    let (date, time) = text.split_at(10);
    let time = time.trim_start();
    let time = if time.len() > 8 { &time[..12] } else { time };
    format!("{date}T{time}Z")
}

/// Writes one log event with extra fields.
pub fn log(level: LogLevel, msg: &str, fields: Vec<(&str, Json)>) {
    if !enabled(level) {
        return;
    }
    let mut all = vec![
        ("ts", Json::String(now_rfc3339())),
        ("level", Json::str(level.name())),
        ("msg", Json::str(msg)),
    ];
    all.extend(fields);
    let line = Json::object(all).to_string_compact();
    let mut err = std::io::stderr().lock();
    let _ = writeln!(err, "{line}");
}

pub fn debug(msg: &str, fields: Vec<(&str, Json)>) {
    log(LogLevel::Debug, msg, fields);
}

pub fn info(msg: &str, fields: Vec<(&str, Json)>) {
    log(LogLevel::Info, msg, fields);
}

pub fn warn(msg: &str, fields: Vec<(&str, Json)>) {
    log(LogLevel::Warn, msg, fields);
}

pub fn error(msg: &str, fields: Vec<(&str, Json)>) {
    log(LogLevel::Error, msg, fields);
}
