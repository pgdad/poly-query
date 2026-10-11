//! Query planning: semantic analysis (binding & typing) producing a logical
//! plan, rule-based logical optimization, and physical planning.
//!
//! `AST → binder → LogicalPlan → optimizer (rules) → physical::plan → PhysicalQuery`

pub mod access;
pub mod binder;
pub mod cardinality;
pub mod expr;
pub mod logical;
pub mod optimizer;
pub mod physical;
pub mod typing;

pub use binder::{BindContext, plan_query};
pub use logical::LogicalPlan;
pub use optimizer::Optimizer;
pub use physical::{PhysicalOptions, PhysicalPlan, PhysicalQuery};
