//! Command-line parsing (protocol.md §2).

use std::path::PathBuf;

use crate::config::{Config, ServeConfig};
use crate::log::LogLevel;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Mode {
    Version,
    Capabilities,
    Session,
    Exec { request: String },
    Serve,
}

#[derive(Debug)]
pub struct Cli {
    pub mode: Mode,
    pub config: Config,
    pub serve: ServeConfig,
}

pub const USAGE: &str = "usage: polyquery (version | capabilities | session [options] | exec [options] --request FILE|- | serve [options] --port N)";

const KNOWN_OPTIONS: &[&str] = &[
    "data-dir",
    "enable-test-functions",
    "max-query-memory-mb",
    "max-ingest-bytes",
    "max-table-rows",
    "max-join-rows",
    "threads",
    "log-level",
    "native-kernels",
    "request",
    "host",
    "port",
    "workers",
    "queue-depth",
    "query-timeout-ms",
    "shutdown-grace-ms",
    "max-request-bytes",
];

fn number<T: std::str::FromStr>(opt: &str, v: &str) -> Result<T, String> {
    v.parse()
        .map_err(|_| format!("invalid value '{v}' for {opt}"))
}

/// Parses arguments (excluding the program name). Errors are usage errors.
pub fn parse_args(args: &[String]) -> Result<Cli, String> {
    let mut it = args.iter();
    let mode_name = it.next().ok_or_else(|| "missing command".to_string())?;
    let mut config = Config::default();
    let mut serve = ServeConfig::default();
    let mut request: Option<String> = None;
    let mut pending: Vec<(String, Option<String>)> = Vec::new();
    while let Some(arg) = it.next() {
        let Some(opt) = arg.strip_prefix("--") else {
            return Err(format!("unexpected argument '{arg}'"));
        };
        let (name, inline) = match opt.split_once('=') {
            Some((n, v)) => (n.to_string(), Some(v.to_string())),
            None => (opt.to_string(), None),
        };
        if !KNOWN_OPTIONS.contains(&name.as_str()) {
            return Err(format!("unknown option --{name}"));
        }
        let takes_value = name != "enable-test-functions";
        let value = if takes_value {
            match inline {
                Some(v) => Some(v),
                None => Some(
                    it.next()
                        .ok_or_else(|| format!("option --{name} requires a value"))?
                        .clone(),
                ),
            }
        } else {
            if inline.is_some() {
                return Err(format!("option --{name} takes no value"));
            }
            None
        };
        pending.push((name, value));
    }
    for (name, value) in pending {
        let v = value.unwrap_or_default();
        let opt = format!("--{name}");
        match name.as_str() {
            "data-dir" => config.data_dir = PathBuf::from(v),
            "enable-test-functions" => config.test_functions = true,
            "max-query-memory-mb" => config.max_query_memory_mb = number(&opt, &v)?,
            "max-ingest-bytes" => config.max_ingest_bytes = number(&opt, &v)?,
            "max-table-rows" => config.max_table_rows = number(&opt, &v)?,
            "max-join-rows" => config.max_join_rows = number(&opt, &v)?,
            "threads" => {
                config.threads = number(&opt, &v)?;
                if config.threads == 0 {
                    return Err("--threads must be at least 1".to_string());
                }
            }
            "log-level" => {
                config.log_level =
                    LogLevel::parse(&v).ok_or_else(|| format!("invalid log level '{v}'"))?
            }
            "native-kernels" => config.native_kernels = Some(PathBuf::from(v)),
            "request" if mode_name == "exec" => request = Some(v),
            "host" if mode_name == "serve" => serve.host = v,
            "port" if mode_name == "serve" => serve.port = Some(number(&opt, &v)?),
            "workers" if mode_name == "serve" => serve.workers = Some(number(&opt, &v)?),
            "queue-depth" if mode_name == "serve" => serve.queue_depth = number(&opt, &v)?,
            "query-timeout-ms" if mode_name == "serve" => {
                serve.query_timeout_ms = number(&opt, &v)?
            }
            "shutdown-grace-ms" if mode_name == "serve" => {
                serve.shutdown_grace_ms = number(&opt, &v)?
            }
            "max-request-bytes" if mode_name == "serve" => {
                serve.max_request_bytes = number(&opt, &v)?
            }
            _ => return Err(format!("unknown option {opt}")),
        }
    }
    let mode = match mode_name.as_str() {
        "version" => Mode::Version,
        "capabilities" => Mode::Capabilities,
        "session" => Mode::Session,
        "exec" => Mode::Exec {
            request: request.ok_or_else(|| "exec requires --request FILE|-".to_string())?,
        },
        "serve" => {
            if serve.port.is_none() {
                return Err("serve requires --port N".to_string());
            }
            Mode::Serve
        }
        other => return Err(format!("unknown command '{other}'")),
    };
    Ok(Cli {
        mode,
        config,
        serve,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(s: &str) -> Vec<String> {
        s.split_whitespace().map(String::from).collect()
    }

    #[test]
    fn parses_session_options() {
        let cli = parse_args(&args(
            "session --data-dir /tmp --enable-test-functions --max-table-rows=10",
        ))
        .unwrap();
        assert_eq!(cli.mode, Mode::Session);
        assert!(cli.config.test_functions);
        assert_eq!(cli.config.max_table_rows, 10);
        assert_eq!(cli.config.data_dir, PathBuf::from("/tmp"));
    }

    #[test]
    fn rejects_unknown() {
        assert!(parse_args(&args("session --bogus 1")).is_err());
        assert!(parse_args(&args("frob")).is_err());
        assert!(parse_args(&args("exec")).is_err());
        assert!(parse_args(&args("session --threads")).is_err());
        assert!(parse_args(&args("session --port 1")).is_err());
    }
}
