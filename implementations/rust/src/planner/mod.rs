//! Query planning: semantic analysis (binding & typing) producing a logical
//! plan, logical optimization, and physical planning.
//!
//! `AST → binder → LogicalPlan → optimizer → physical::lower → PhysicalPlan`

pub mod access;
pub mod binder;
pub mod expr;
pub mod logical;
pub mod optimizer;
pub mod physical;
pub mod reorder;
pub mod rewrite;
pub mod typing;

pub use binder::{BindContext, plan_query};
pub use logical::LogicalPlan;
pub use physical::{PhysicalOptions, PhysicalPlan};
