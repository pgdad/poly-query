//! Query execution: physical operators, expression evaluation, scalar
//! functions, aggregate accumulators and subquery evaluation.

pub mod aggregate;
pub mod context;
pub mod eval;
pub mod functions;
pub mod operators;
pub mod subquery;

pub use context::ExecContext;
pub use operators::{Operator, Row, build};
