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

pub fn check_operand_count(operands: usize) -> Result<()> {
    if operands > MAX_OPERANDS {
        return Err(Error::resource_limit(format!(
            "operand count exceeds {MAX_OPERANDS}"
        )));
    }
    Ok(())
}
