//! SQL front end: lexer, AST, parser and statement size limits.

pub mod ast;
pub mod lexer;
pub mod limits;
pub mod parser;

pub use parser::parse_statement;
