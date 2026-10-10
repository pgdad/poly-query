//! `polyquery` command-line entry point.

use std::process::ExitCode;

use polyquery::cli::{Mode, USAGE, parse_args};
use polyquery::engine::Engine;
use polyquery::protocol::{capabilities_json, session, version_json};

/// Stack size of the request-processing thread (deep expressions recurse).
const WORKER_STACK_BYTES: usize = 256 * 1024 * 1024;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let cli = match parse_args(&args) {
        Ok(c) => c,
        Err(msg) => {
            eprintln!("polyquery: {msg}\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    polyquery::log::set_level(cli.config.log_level);
    // Keep panic output off the protocol channel; panics are reported as
    // INTERNAL_ERROR responses and logged.
    std::panic::set_hook(Box::new(|info| {
        polyquery::log::error("panic", vec![("detail", polyquery::json::Json::String(info.to_string()))]);
    }));

    match cli.mode {
        Mode::Version => {
            println!("{}", version_json().to_string_compact());
            ExitCode::SUCCESS
        }
        Mode::Capabilities => {
            println!("{}", capabilities_json().to_string_compact());
            ExitCode::SUCCESS
        }
        Mode::Serve => {
            eprintln!("polyquery: serve (HTTP, Phase 4) is not implemented by this engine");
            ExitCode::from(1)
        }
        Mode::Session | Mode::Exec { .. } => {
            if !cli.config.data_dir.is_dir() {
                eprintln!("polyquery: data directory '{}' does not exist", cli.config.data_dir.display());
                return ExitCode::from(1);
            }
            let mode = cli.mode.clone();
            let config = cli.config;
            let worker = std::thread::Builder::new().name("session".into()).stack_size(WORKER_STACK_BYTES).spawn(
                move || {
                    let mut engine = Engine::new(config);
                    match &mode {
                        Mode::Exec { request } => session::run_exec(&mut engine, request),
                        _ => session::run_session(&mut engine),
                    }
                },
            );
            match worker.map(|h| h.join()) {
                Ok(Ok(Ok(()))) => ExitCode::SUCCESS,
                Ok(Ok(Err(e))) => {
                    eprintln!("polyquery: I/O error: {e}");
                    ExitCode::from(1)
                }
                _ => {
                    eprintln!("polyquery: fatal error");
                    ExitCode::from(1)
                }
            }
        }
    }
}
