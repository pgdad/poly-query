//! Bound (resolved and typed) expressions produced by semantic analysis.

use crate::sql::ast::BinaryOp;
use crate::types::{DataType, Value};

/// Numeric domain in which an arithmetic operator is evaluated.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArithKind {
    Int,
    Decimal,
    Float,
}

/// Scalar (non-aggregate) functions known to the engine.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScalarFunc {
    /// Test-only `PQ_SLEEP(ms)`.
    PqSleep,
}

impl ScalarFunc {
    pub fn name(self) -> &'static str {
        match self {
            ScalarFunc::PqSleep => "PQ_SLEEP",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Expr {
    Literal { value: Value, ty: DataType },
    /// Reference to column `index` of the input row.
    Column { index: usize, ty: DataType },
    Negate { expr: Box<Expr>, ty: DataType },
    Not(Box<Expr>),
    And(Box<Expr>, Box<Expr>),
    Or(Box<Expr>, Box<Expr>),
    Arith { op: BinaryOp, kind: ArithKind, left: Box<Expr>, right: Box<Expr>, ty: DataType },
    Compare { op: BinaryOp, left: Box<Expr>, right: Box<Expr> },
    Concat(Box<Expr>, Box<Expr>),
    IsNull { expr: Box<Expr>, negated: bool },
    Cast { expr: Box<Expr>, to: DataType },
    Function { func: ScalarFunc, args: Vec<Expr>, ty: DataType },
}

impl Expr {
    pub fn data_type(&self) -> DataType {
        match self {
            Expr::Literal { ty, .. }
            | Expr::Column { ty, .. }
            | Expr::Negate { ty, .. }
            | Expr::Arith { ty, .. }
            | Expr::Function { ty, .. } => *ty,
            Expr::Not(_) | Expr::And(..) | Expr::Or(..) | Expr::Compare { .. } | Expr::IsNull { .. } => {
                DataType::Boolean
            }
            Expr::Concat(..) => DataType::String,
            Expr::Cast { to, .. } => *to,
        }
    }

    /// Immediate sub-expressions.
    pub fn children(&self) -> Vec<&Expr> {
        match self {
            Expr::Literal { .. } | Expr::Column { .. } => vec![],
            Expr::Negate { expr, .. } | Expr::Not(expr) | Expr::IsNull { expr, .. } | Expr::Cast { expr, .. } => {
                vec![expr]
            }
            Expr::And(l, r) | Expr::Or(l, r) | Expr::Concat(l, r) => vec![l, r],
            Expr::Arith { left, right, .. } | Expr::Compare { left, right, .. } => vec![left, right],
            Expr::Function { args, .. } => args.iter().collect(),
        }
    }

    fn children_mut(&mut self) -> Vec<&mut Expr> {
        match self {
            Expr::Literal { .. } | Expr::Column { .. } => vec![],
            Expr::Negate { expr, .. } | Expr::Not(expr) | Expr::IsNull { expr, .. } | Expr::Cast { expr, .. } => {
                vec![expr]
            }
            Expr::And(l, r) | Expr::Or(l, r) | Expr::Concat(l, r) => vec![l, r],
            Expr::Arith { left, right, .. } | Expr::Compare { left, right, .. } => vec![left, right],
            Expr::Function { args, .. } => args.iter_mut().collect(),
        }
    }

    /// Collects the input column indices referenced by this expression.
    pub fn collect_columns(&self, out: &mut Vec<usize>) {
        if let Expr::Column { index, .. } = self {
            out.push(*index);
        }
        for c in self.children() {
            c.collect_columns(out);
        }
    }

    /// Rewrites column indices through `map` (old index → new index).
    pub fn remap_columns(&mut self, map: &dyn Fn(usize) -> usize) {
        if let Expr::Column { index, .. } = self {
            *index = map(*index);
        }
        for c in self.children_mut() {
            c.remap_columns(map);
        }
    }

    /// True if the expression references no input columns.
    pub fn is_constant(&self) -> bool {
        let mut cols = Vec::new();
        self.collect_columns(&mut cols);
        cols.is_empty()
    }

    /// Human-readable rendering (used for plan display).
    pub fn display(&self) -> String {
        match self {
            Expr::Literal { value, .. } => match value {
                Value::Null => "NULL".to_string(),
                Value::Str(s) => format!("'{}'", s.replace('\'', "''")),
                v => v.to_text(),
            },
            Expr::Column { index, .. } => format!("#{index}"),
            Expr::Negate { expr, .. } => format!("(-{})", expr.display()),
            Expr::Not(e) => format!("(NOT {})", e.display()),
            Expr::And(l, r) => format!("({} AND {})", l.display(), r.display()),
            Expr::Or(l, r) => format!("({} OR {})", l.display(), r.display()),
            Expr::Arith { op, left, right, .. } | Expr::Compare { op, left, right } => {
                format!("({} {} {})", left.display(), op.symbol(), right.display())
            }
            Expr::Concat(l, r) => format!("({} || {})", l.display(), r.display()),
            Expr::IsNull { expr, negated } => {
                format!("({} IS {}NULL)", expr.display(), if *negated { "NOT " } else { "" })
            }
            Expr::Cast { expr, to } => format!("CAST({} AS {to})", expr.display()),
            Expr::Function { func, args, .. } => {
                let args: Vec<String> = args.iter().map(|a| a.display()).collect();
                format!("{}({})", func.name(), args.join(", "))
            }
        }
    }
}

/// Aggregate functions.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AggFunc {
    CountStar,
    Count,
    Sum,
    Avg,
    Min,
    Max,
}

impl AggFunc {
    pub fn lookup(name: &str) -> Option<AggFunc> {
        match name.to_ascii_uppercase().as_str() {
            "COUNT" => Some(AggFunc::Count),
            "SUM" => Some(AggFunc::Sum),
            "AVG" => Some(AggFunc::Avg),
            "MIN" => Some(AggFunc::Min),
            "MAX" => Some(AggFunc::Max),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            AggFunc::CountStar | AggFunc::Count => "COUNT",
            AggFunc::Sum => "SUM",
            AggFunc::Avg => "AVG",
            AggFunc::Min => "MIN",
            AggFunc::Max => "MAX",
        }
    }
}

/// One aggregate computation over the input rows of a group.
#[derive(Debug, Clone, PartialEq)]
pub struct AggregateCall {
    pub func: AggFunc,
    /// Argument (None for COUNT(*)).
    pub arg: Option<Expr>,
    pub distinct: bool,
    /// Result type.
    pub ty: DataType,
}

impl AggregateCall {
    pub fn display(&self) -> String {
        match &self.arg {
            None => "COUNT(*)".to_string(),
            Some(a) => format!("{}({}{})", self.func.name(), if self.distinct { "DISTINCT " } else { "" }, a.display()),
        }
    }
}
