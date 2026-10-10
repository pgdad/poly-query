//! PolyQuery: an analytical database engine (Rust, standard library only).
//!
//! Layers, bottom-up:
//! * [`types`]    — data types, values, casts, decimal/date arithmetic
//! * [`storage`]  — immutable tables (row/column/PQCF), statistics, indexes, PQCF files
//! * [`ingest`]   — CSV / JSON / JSONL readers with schema inference
//! * [`catalog`]  — named tables
//! * [`sql`]      — lexer, AST, parser
//! * [`planner`]  — semantic analysis (binding, typing) and logical plans
//! * [`exec`]     — physical operators and expression evaluation
//! * [`engine`]   — transport-independent facade
//! * [`protocol`] — JSON request/response protocol, session and exec modes

pub mod catalog;
pub mod cli;
pub mod config;
pub mod engine;
pub mod error;
pub mod exec;
pub mod ingest;
pub mod json;
pub mod log;
pub mod planner;
pub mod protocol;
pub mod sql;
pub mod storage;
pub mod types;
