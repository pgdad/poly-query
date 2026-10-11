//! Vectorized (batch-at-a-time) execution: column vectors, vectorized
//! expression kernels, and batch operators.

pub mod agg;
pub mod batch;
pub mod build;
pub mod eval;
pub mod join;
pub mod keys;
pub mod ops;

pub use batch::{Batch, Vector};
pub use build::build;
pub use ops::{BatchOperator, BoxedBatchOp};
