//! Abstract syntax tree for PolyQuery SQL v1 (grammar.md §2).

use super::lexer::Pos;

#[derive(Debug, Clone, PartialEq)]
pub struct Ident {
    pub value: String,
    pub quoted: bool,
    pub pos: Pos,
}

impl Ident {
    /// ASCII case-insensitive identifier match.
    pub fn matches(&self, name: &str) -> bool {
        self.value.eq_ignore_ascii_case(name)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Statement {
    Query(Box<Query>),
    Explain(Box<Query>),
    CreateIndex { name: Ident, if_not_exists: bool, table: Ident, column: Ident, using: Option<Ident> },
    DropIndex { name: Ident, if_exists: bool },
}

#[derive(Debug, Clone, PartialEq)]
pub struct Query {
    pub with: Vec<Cte>,
    pub body: SelectCore,
    pub order_by: Vec<OrderItem>,
    pub limit: Option<Expr>,
    pub offset: Option<Expr>,
    pub pos: Pos,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Cte {
    pub name: Ident,
    pub columns: Vec<Ident>,
    pub query: Box<Query>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SelectCore {
    pub distinct: bool,
    pub items: Vec<SelectItem>,
    pub from: Option<FromItem>,
    pub where_clause: Option<Expr>,
    pub group_by: Vec<Expr>,
    pub having: Option<Expr>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum SelectItem {
    /// `*`
    Wildcard(Pos),
    /// `r.*`
    QualifiedWildcard(Ident),
    Expr { expr: Expr, alias: Option<Ident> },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JoinKind {
    Inner,
    Left,
    Cross,
}

#[derive(Debug, Clone, PartialEq)]
pub enum FromItem {
    Table { name: Ident, alias: Option<Ident> },
    Derived { query: Box<Query>, alias: Ident },
    Join { left: Box<FromItem>, right: Box<FromItem>, kind: JoinKind, on: Option<Expr>, pos: Pos },
}

#[derive(Debug, Clone, PartialEq)]
pub struct OrderItem {
    pub expr: Expr,
    pub descending: bool,
    /// `Some(true)` = NULLS FIRST, `Some(false)` = NULLS LAST.
    pub nulls_first: Option<bool>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Expr {
    pub kind: ExprKind,
    pub pos: Pos,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnaryOp {
    Neg,
    Plus,
    Not,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BinaryOp {
    Add,
    Sub,
    Mul,
    Div,
    Mod,
    Concat,
    Eq,
    NotEq,
    Lt,
    LtEq,
    Gt,
    GtEq,
    And,
    Or,
}

impl BinaryOp {
    pub fn is_comparison(self) -> bool {
        matches!(self, BinaryOp::Eq | BinaryOp::NotEq | BinaryOp::Lt | BinaryOp::LtEq | BinaryOp::Gt | BinaryOp::GtEq)
    }

    pub fn is_arithmetic(self) -> bool {
        matches!(self, BinaryOp::Add | BinaryOp::Sub | BinaryOp::Mul | BinaryOp::Div | BinaryOp::Mod)
    }

    pub fn symbol(self) -> &'static str {
        match self {
            BinaryOp::Add => "+",
            BinaryOp::Sub => "-",
            BinaryOp::Mul => "*",
            BinaryOp::Div => "/",
            BinaryOp::Mod => "%",
            BinaryOp::Concat => "||",
            BinaryOp::Eq => "=",
            BinaryOp::NotEq => "<>",
            BinaryOp::Lt => "<",
            BinaryOp::LtEq => "<=",
            BinaryOp::Gt => ">",
            BinaryOp::GtEq => ">=",
            BinaryOp::And => "AND",
            BinaryOp::Or => "OR",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Literal {
    /// Numeric literal text as written (no sign).
    Number(String),
    String(String),
    Bool(bool),
    Null,
    Date(String),
    Timestamp(String),
}

#[derive(Debug, Clone, PartialEq)]
pub struct TypeName {
    pub name: String,
    pub params: Vec<String>,
    pub pos: Pos,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ExprKind {
    Literal(Literal),
    Column { qualifier: Option<Ident>, name: Ident },
    Unary { op: UnaryOp, expr: Box<Expr> },
    Binary { op: BinaryOp, left: Box<Expr>, right: Box<Expr> },
    IsNull { expr: Box<Expr>, negated: bool },
    Between { expr: Box<Expr>, low: Box<Expr>, high: Box<Expr>, negated: bool },
    InList { expr: Box<Expr>, list: Vec<Expr>, negated: bool },
    InSubquery { expr: Box<Expr>, query: Box<Query>, negated: bool },
    Like { expr: Box<Expr>, pattern: Box<Expr>, negated: bool },
    Function { name: Ident, args: Vec<Expr>, distinct: bool, star: bool },
    Cast { expr: Box<Expr>, type_name: TypeName },
    Case { operand: Option<Box<Expr>>, whens: Vec<(Expr, Expr)>, else_expr: Option<Box<Expr>> },
    Exists(Box<Query>),
    Subquery(Box<Query>),
}
