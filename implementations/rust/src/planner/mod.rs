//! Semantic analysis and logical planning.

pub mod binder;
pub mod expr;
pub mod logical;

pub use binder::{BindContext, plan_query};
pub use logical::LogicalPlan;
