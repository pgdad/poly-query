//! Statement size limits (change request CR-6, `spec/changes/expression-limits.md`).
//!
//! The engine accepts every statement within these limits in every stage
//! and execution mode; a statement beyond one fails with `RESOURCE_LIMIT`
//! naming the measure. The limits are well above the CR-6 minimums
//! (1 MiB of text, nesting depth 1,000, 25,000 operands) and are what the
//! stack sizes of the engine's threads are dimensioned for (see
//! [`crate::exec::stack`]).

use crate::error::{Error, Result};

/// Maximum SQL text length in bytes.
pub const MAX_TEXT_BYTES: usize = 16 * 1024 * 1024;

/// Maximum nesting depth (CR-6 §1: a chain of binary operators of one
/// precedence level counts as one level).
pub const MAX_NESTING_DEPTH: usize = 4096;

/// Maximum number of operands (literals, column references, `*`).
pub const MAX_OPERANDS: usize = 100_000;

/// Maximum number of table references (FROM items: tables, CTE references,
/// derived tables).
pub const MAX_TABLE_REFERENCES: usize = 262_144;

/// Maximum size of a bound statement (`LogicalPlan::size` units): CTE
/// references are expanded into copies of the CTE's plan and every join
/// stores its output columns, so a short text can describe a huge plan.
pub const MAX_PLAN_SIZE: usize = 4_000_000;

pub fn check_text_length(bytes: usize) -> Result<()> {
    if bytes > MAX_TEXT_BYTES {
        return Err(Error::resource_limit(format!(
            "statement text length ({bytes} bytes) exceeds {MAX_TEXT_BYTES} bytes"
        )));
    }
    Ok(())
}

pub fn check_nesting_depth(depth: usize) -> Result<()> {
    if depth > MAX_NESTING_DEPTH {
        return Err(Error::resource_limit(format!(
            "expression nesting depth exceeds {MAX_NESTING_DEPTH}"
        )));
    }
    Ok(())
}

pub fn check_table_references(count: usize) -> Result<()> {
    if count > MAX_TABLE_REFERENCES {
        return Err(Error::resource_limit(format!(
            "table reference count exceeds {MAX_TABLE_REFERENCES}"
        )));
    }
    Ok(())
}

pub fn check_plan_size(units: usize) -> Result<()> {
    if units > MAX_PLAN_SIZE {
        return Err(Error::resource_limit(format!(
            "statement plan size (expanded CTE references and joins) exceeds {MAX_PLAN_SIZE}"
        )));
    }
    Ok(())
}

pub fn check_operand_count(operands: usize) -> Result<()> {
    if operands > MAX_OPERANDS {
        return Err(Error::resource_limit(format!(
            "operand count exceeds {MAX_OPERANDS}"
        )));
    }
    Ok(())
}
