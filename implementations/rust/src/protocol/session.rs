//! `session` (JSON lines on stdin/stdout) and `exec` CLI modes.

use std::io::{self, BufRead, Read, Write};
use std::time::Instant;

use super::{error_response, handle_json, handle_line};
use crate::engine::Engine;
use crate::error::Error;
use crate::json::{self, Json};

/// Runs the request/response loop until EOF on stdin.
pub fn run_session(engine: &Engine) -> io::Result<()> {
    let stdin = io::stdin();
    let mut input = stdin.lock();
    let stdout = io::stdout();
    let mut out = stdout.lock();
    let mut buf = Vec::new();
    loop {
        buf.clear();
        if input.read_until(b'\n', &mut buf)? == 0 {
            return Ok(());
        }
        let received = Instant::now();
        let line = match std::str::from_utf8(&buf) {
            Ok(s) => s.trim_end_matches(['\n', '\r']),
            Err(_) => {
                let resp = error_response(
                    Json::Null,
                    &Error::invalid_request("request is not valid UTF-8"),
                );
                writeln!(out, "{}", resp.to_string_compact())?;
                out.flush()?;
                continue;
            }
        };
        if line.trim().is_empty() {
            continue;
        }
        let resp = handle_line(engine, line, received);
        out.write_all(resp.as_bytes())?;
        out.write_all(b"\n")?;
        out.flush()?;
    }
}

/// Executes a request file (a single request or an array of requests),
/// printing one response per line.
pub fn run_exec(engine: &Engine, source: &str) -> io::Result<()> {
    let text = if source == "-" {
        let mut s = String::new();
        io::stdin().read_to_string(&mut s)?;
        s
    } else {
        std::fs::read_to_string(source)?
    };
    let stdout = io::stdout();
    let mut out = stdout.lock();
    match json::parse(&text) {
        Ok(Json::Array(items)) => {
            for item in &items {
                let resp = handle_json(engine, item, Instant::now());
                writeln!(out, "{}", resp.to_string_compact())?;
                out.flush()?;
            }
        }
        Ok(v) => {
            writeln!(
                out,
                "{}",
                handle_json(engine, &v, Instant::now()).to_string_compact()
            )?;
        }
        Err(e) => {
            let resp = error_response(
                Json::Null,
                &Error::invalid_request(format!("invalid JSON: {e}")),
            );
            writeln!(out, "{}", resp.to_string_compact())?;
        }
    }
    out.flush()
}
