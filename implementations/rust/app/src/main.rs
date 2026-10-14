//! `pqledger`: a personal-finance command-line application on the
//! embedded PolyQuery engine (spec/apps/pqledger.md).
//!
//! Modules:
//! * [`cli`]      — command-line parsing
//! * [`config`]   — the configuration file; [`ini`] its line syntax
//! * [`rules`]    — the category rules and budget files
//! * [`bankcsv`]  — reading bank CSV exports; [`convert`] turns records into
//!   transactions (dates, [`amount`]s, merchants)
//! * [`ledger`]   — the PQCF ledger, accessed through `polyquery::api`
//! * [`commands`] — the commands, as SQL on the ledger
//! * [`output`]   — table / csv / json output
//! * [`error`]    — error kinds and exit statuses

mod amount;
mod bankcsv;
mod cli;
mod commands;
mod config;
mod convert;
mod error;
mod ini;
mod ledger;
mod output;
mod rules;

use std::io::Write;
use std::process::ExitCode;

use commands::Outcome;
use error::{AppError, ErrorKind};

fn main() -> ExitCode {
    // Errors are reported as `pqledger: error: …`; keep panic messages
    // (engine-internal ones are reported as INTERNAL_ERROR) off stderr.
    std::panic::set_hook(Box::new(|_| {}));
    let args: Vec<String> = std::env::args().skip(1).collect();
    let outcome = std::panic::catch_unwind(|| run(&args))
        .unwrap_or_else(|_| Err(AppError::other("internal error")));
    match outcome {
        Ok(code) => ExitCode::from(code),
        Err(e) => {
            eprintln!("pqledger: error: {}", e.message);
            ExitCode::from(e.kind.exit_code())
        }
    }
}

fn run(args: &[String]) -> Result<u8, AppError> {
    let invocation = cli::parse(args)?;
    let (outcome, format) = commands::run(
        invocation.command,
        invocation.config.as_deref(),
        invocation.format,
    )?;
    let (text, code) = match outcome {
        Outcome::Message(text) => (text, 0),
        Outcome::Report(report, code) => (report.render(format), code),
    };
    let mut out = std::io::stdout().lock();
    out.write_all(text.as_bytes())
        .and_then(|()| out.flush())
        .map_err(|e| AppError::new(ErrorKind::Other, format!("cannot write the output: {e}")))?;
    Ok(code)
}
