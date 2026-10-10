//! Query execution.

pub mod aggregate;
pub mod context;
pub mod eval;
pub mod operators;

pub use context::ExecContext;
pub use operators::{Operator, Row, build};
