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
//! * [`api`]      — the public embedding API (the engine as a library)
//! * [`protocol`] — JSON request/response protocol, session and exec modes
//! * [`server`]   — HTTP/1.1 server (`serve`): admission, streaming, metrics, shutdown
//! * [`alloc`]    — the global allocator (arena-local `realloc`)

pub mod alloc;
pub mod api;
pub mod catalog;
pub mod cli;
pub mod config;
pub mod engine;
pub mod error;
pub mod exec;
pub mod ingest;
pub mod interrupt;
pub mod json;
pub mod log;
pub mod native;
pub mod planner;
pub mod protocol;
pub mod server;
pub mod sql;
pub mod stack;
pub mod storage;
pub mod types;
