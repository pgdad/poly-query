//! Query execution: physical operators, expression evaluation, scalar
//! functions, aggregate accumulators and subquery evaluation.

pub mod aggregate;
pub mod context;
pub mod eval;
pub mod functions;
pub mod hash;
pub mod native_filter;
pub mod operators;
pub mod parallel;
pub mod subquery;
pub mod vector;

pub use context::ExecContext;
pub use operators::{Operator, Row, build};
