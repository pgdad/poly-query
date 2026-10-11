//! Bound (resolved and typed) expressions produced by semantic analysis.

use std::fmt;
use std::sync::Arc;

use super::logical::LogicalPlan;
use crate::sql::ast::BinaryOp;
use crate::types::{DataType, Value};

/// Numeric domain in which an arithmetic operator is evaluated.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArithKind {
    Int,
    Decimal,
    Float,
}

/// Domain in which two values of possibly different (but comparable) types
/// are compared; used to normalize hash keys so that hashing agrees with
/// comparison (types.md §2, §5).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyDomain {
    /// Both sides have the same representation.
    Exact,
    /// INT64 mixed with DECIMAL: INT64 is viewed as DECIMAL(18,0).
    Decimal,
    /// Any numeric mixed with FLOAT64.
    Float,
    /// DATE mixed with TIMESTAMP.
    Timestamp,
}

impl KeyDomain {
    /// The comparison domain of two comparable types.
    pub fn of(l: DataType, r: DataType) -> KeyDomain {
        use DataType as T;
        match (l, r) {
            (T::Float64, t) | (t, T::Float64) if t.is_numeric() => KeyDomain::Float,
            (T::Int64, T::Decimal { .. }) | (T::Decimal { .. }, T::Int64) => KeyDomain::Decimal,
            (T::Date, T::Timestamp) | (T::Timestamp, T::Date) => KeyDomain::Timestamp,
            _ => KeyDomain::Exact,
        }
    }
}

/// Unit argument of `DATE_TRUNC`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TruncUnit {
    Year,
    Month,
    Day,
    Hour,
    Minute,
}

impl TruncUnit {
    pub fn parse(s: &str) -> Option<TruncUnit> {
        Some(match s.to_ascii_lowercase().as_str() {
            "year" => TruncUnit::Year,
            "month" => TruncUnit::Month,
            "day" => TruncUnit::Day,
            "hour" => TruncUnit::Hour,
            "minute" => TruncUnit::Minute,
            _ => return None,
        })
    }
}

/// Scalar (non-aggregate) functions (functions.md §1).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScalarFunc {
    Abs,
    /// `ROUND(x, n)` with the constant `n`; only `x` is kept as an argument.
    Round(i64),
    Floor,
    Ceil,
    Sqrt,
    Power,
    Mod,
    Length,
    Upper,
    Lower,
    Substr,
    Trim,
    Ltrim,
    Rtrim,
    Replace,
    Concat,
    Coalesce,
    Nullif,
    Year,
    Month,
    Day,
    Hour,
    Minute,
    Second,
    /// `DATE_TRUNC(unit, t)`; only `t` is kept as an argument.
    DateTrunc(TruncUnit),
    /// `DATE_DIFF('day', a, b)`; only `a` and `b` are kept as arguments.
    DateDiffDays,
    /// Test-only `PQ_SLEEP(ms)`.
    PqSleep,
}

impl ScalarFunc {
    pub fn name(self) -> &'static str {
        match self {
            ScalarFunc::Abs => "ABS",
            ScalarFunc::Round(_) => "ROUND",
            ScalarFunc::Floor => "FLOOR",
            ScalarFunc::Ceil => "CEIL",
            ScalarFunc::Sqrt => "SQRT",
            ScalarFunc::Power => "POWER",
            ScalarFunc::Mod => "MOD",
            ScalarFunc::Length => "LENGTH",
            ScalarFunc::Upper => "UPPER",
            ScalarFunc::Lower => "LOWER",
            ScalarFunc::Substr => "SUBSTR",
            ScalarFunc::Trim => "TRIM",
            ScalarFunc::Ltrim => "LTRIM",
            ScalarFunc::Rtrim => "RTRIM",
            ScalarFunc::Replace => "REPLACE",
            ScalarFunc::Concat => "CONCAT",
            ScalarFunc::Coalesce => "COALESCE",
            ScalarFunc::Nullif => "NULLIF",
            ScalarFunc::Year => "YEAR",
            ScalarFunc::Month => "MONTH",
            ScalarFunc::Day => "DAY",
            ScalarFunc::Hour => "HOUR",
            ScalarFunc::Minute => "MINUTE",
            ScalarFunc::Second => "SECOND",
            ScalarFunc::DateTrunc(_) => "DATE_TRUNC",
            ScalarFunc::DateDiffDays => "DATE_DIFF",
            ScalarFunc::PqSleep => "PQ_SLEEP",
        }
    }
}

/// A bound subquery: its own logical plan, identified within the statement
/// (so that plans and executions can be cached per subquery).
#[derive(Debug, Clone)]
pub struct SubqueryPlan {
    pub id: usize,
    pub plan: LogicalPlan,
}

impl PartialEq for SubqueryPlan {
    fn eq(&self, other: &Self) -> bool {
        self.id == other.id
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Expr {
    Literal {
        value: Value,
        ty: DataType,
    },
    /// Reference to column `index` of the input row.
    Column {
        index: usize,
        ty: DataType,
    },
    /// Correlation parameter `index` of the enclosing subquery execution
    /// (a value of an outer query's row).
    Param {
        index: usize,
        ty: DataType,
    },
    /// Placeholder for aggregate `index` while binding an aggregated query;
    /// replaced by a column reference before planning.
    AggRef {
        index: usize,
        ty: DataType,
    },
    Negate {
        expr: Box<Expr>,
        ty: DataType,
    },
    Not(Box<Expr>),
    And(Box<Expr>, Box<Expr>),
    Or(Box<Expr>, Box<Expr>),
    Arith {
        op: BinaryOp,
        kind: ArithKind,
        left: Box<Expr>,
        right: Box<Expr>,
        ty: DataType,
    },
    Compare {
        op: BinaryOp,
        left: Box<Expr>,
        right: Box<Expr>,
    },
    Concat(Box<Expr>, Box<Expr>),
    IsNull {
        expr: Box<Expr>,
        negated: bool,
    },
    Cast {
        expr: Box<Expr>,
        to: DataType,
    },
    Function {
        func: ScalarFunc,
        args: Vec<Expr>,
        ty: DataType,
    },
    Case {
        operand: Option<Box<Expr>>,
        whens: Vec<(Expr, Expr)>,
        else_expr: Option<Box<Expr>>,
        ty: DataType,
    },
    Between {
        expr: Box<Expr>,
        low: Box<Expr>,
        high: Box<Expr>,
        negated: bool,
    },
    InList {
        expr: Box<Expr>,
        list: Vec<Expr>,
        negated: bool,
    },
    Like {
        expr: Box<Expr>,
        pattern: Box<Expr>,
        negated: bool,
    },
    /// Scalar subquery; `params` are evaluated in the enclosing row context
    /// and become the subquery's `Param`s.
    ScalarSubquery {
        sub: Arc<SubqueryPlan>,
        params: Vec<Expr>,
        ty: DataType,
    },
    Exists {
        sub: Arc<SubqueryPlan>,
        params: Vec<Expr>,
    },
    InSubquery {
        expr: Box<Expr>,
        sub: Arc<SubqueryPlan>,
        params: Vec<Expr>,
        negated: bool,
        domain: KeyDomain,
    },
}

impl Expr {
    pub fn data_type(&self) -> DataType {
        match self {
            Expr::Literal { ty, .. }
            | Expr::Column { ty, .. }
            | Expr::Param { ty, .. }
            | Expr::AggRef { ty, .. }
            | Expr::Negate { ty, .. }
            | Expr::Arith { ty, .. }
            | Expr::Function { ty, .. }
            | Expr::Case { ty, .. }
            | Expr::ScalarSubquery { ty, .. } => *ty,
            Expr::Not(_)
            | Expr::And(..)
            | Expr::Or(..)
            | Expr::Compare { .. }
            | Expr::IsNull { .. }
            | Expr::Between { .. }
            | Expr::InList { .. }
            | Expr::Like { .. }
            | Expr::Exists { .. }
            | Expr::InSubquery { .. } => DataType::Boolean,
            Expr::Concat(..) => DataType::String,
            Expr::Cast { to, .. } => *to,
        }
    }

    /// Immediate sub-expressions evaluated in this expression's row context
    /// (subquery plans are not included; their parameters are).
    pub fn children(&self) -> Vec<&Expr> {
        let mut out = Vec::new();
        self.for_each_child(&mut |c| out.push(c));
        out
    }

    fn for_each_child<'a>(&'a self, f: &mut dyn FnMut(&'a Expr)) {
        match self {
            Expr::Literal { .. }
            | Expr::Column { .. }
            | Expr::Param { .. }
            | Expr::AggRef { .. } => {}
            Expr::Negate { expr, .. }
            | Expr::Not(expr)
            | Expr::IsNull { expr, .. }
            | Expr::Cast { expr, .. } => f(expr),
            Expr::And(l, r) | Expr::Or(l, r) | Expr::Concat(l, r) => {
                f(l);
                f(r);
            }
            Expr::Arith { left, right, .. } | Expr::Compare { left, right, .. } => {
                f(left);
                f(right);
            }
            Expr::Function { args, .. } => args.iter().for_each(f),
            Expr::Case {
                operand,
                whens,
                else_expr,
                ..
            } => {
                if let Some(o) = operand {
                    f(o);
                }
                for (w, t) in whens {
                    f(w);
                    f(t);
                }
                if let Some(e) = else_expr {
                    f(e);
                }
            }
            Expr::Between {
                expr, low, high, ..
            } => {
                f(expr);
                f(low);
                f(high);
            }
            Expr::InList { expr, list, .. } => {
                f(expr);
                list.iter().for_each(f);
            }
            Expr::Like { expr, pattern, .. } => {
                f(expr);
                f(pattern);
            }
            Expr::ScalarSubquery { params, .. } | Expr::Exists { params, .. } => {
                params.iter().for_each(f)
            }
            Expr::InSubquery { expr, params, .. } => {
                f(expr);
                params.iter().for_each(f);
            }
        }
    }

    /// Mutable access to the immediate sub-expressions (same set as `children`).
    pub fn children_mut(&mut self) -> Vec<&mut Expr> {
        match self {
            Expr::Literal { .. }
            | Expr::Column { .. }
            | Expr::Param { .. }
            | Expr::AggRef { .. } => vec![],
            Expr::Negate { expr, .. }
            | Expr::Not(expr)
            | Expr::IsNull { expr, .. }
            | Expr::Cast { expr, .. } => vec![expr],
            Expr::And(l, r) | Expr::Or(l, r) | Expr::Concat(l, r) => vec![l, r],
            Expr::Arith { left, right, .. } | Expr::Compare { left, right, .. } => {
                vec![left, right]
            }
            Expr::Function { args, .. } => args.iter_mut().collect(),
            Expr::Case {
                operand,
                whens,
                else_expr,
                ..
            } => {
                let mut v: Vec<&mut Expr> = Vec::new();
                if let Some(o) = operand {
                    v.push(o);
                }
                for (w, t) in whens {
                    v.push(w);
                    v.push(t);
                }
                if let Some(e) = else_expr {
                    v.push(e);
                }
                v
            }
            Expr::Between {
                expr, low, high, ..
            } => vec![expr, low, high],
            Expr::InList { expr, list, .. } => std::iter::once(&mut **expr)
                .chain(list.iter_mut())
                .collect(),
            Expr::Like { expr, pattern, .. } => vec![expr, pattern],
            Expr::ScalarSubquery { params, .. } | Expr::Exists { params, .. } => {
                params.iter_mut().collect()
            }
            Expr::InSubquery { expr, params, .. } => std::iter::once(&mut **expr)
                .chain(params.iter_mut())
                .collect(),
        }
    }

    /// Calls `f` for every subquery in this expression tree (not descending
    /// into subquery plans); `correlated` tells whether the subquery
    /// receives outer values as parameters.
    pub fn visit_subqueries(&self, f: &mut dyn FnMut(&Arc<SubqueryPlan>, bool)) {
        match self {
            Expr::ScalarSubquery { sub, params, .. }
            | Expr::Exists { sub, params }
            | Expr::InSubquery { sub, params, .. } => f(sub, !params.is_empty()),
            _ => {}
        }
        self.for_each_child(&mut |c| c.visit_subqueries(f));
    }

    /// Mutable variant of [`Expr::visit_subqueries`].
    pub fn visit_subqueries_mut(&mut self, f: &mut dyn FnMut(&mut Arc<SubqueryPlan>)) {
        match self {
            Expr::ScalarSubquery { sub, .. }
            | Expr::Exists { sub, .. }
            | Expr::InSubquery { sub, .. } => f(sub),
            _ => {}
        }
        for c in self.children_mut() {
            c.visit_subqueries_mut(f);
        }
    }

    /// True if `pred` holds for this expression or any sub-expression.
    pub fn any(&self, pred: &dyn Fn(&Expr) -> bool) -> bool {
        if pred(self) {
            return true;
        }
        let mut found = false;
        self.for_each_child(&mut |c| {
            if !found && c.any(pred) {
                found = true;
            }
        });
        found
    }

    /// Collects the input column indices referenced by this expression.
    pub fn collect_columns(&self, out: &mut Vec<usize>) {
        if let Expr::Column { index, .. } = self {
            out.push(*index);
        }
        self.for_each_child(&mut |c| c.collect_columns(out));
    }

    /// Sorted, deduplicated input columns referenced by this expression.
    pub fn columns(&self) -> Vec<usize> {
        let mut v = Vec::new();
        self.collect_columns(&mut v);
        v.sort_unstable();
        v.dedup();
        v
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

    /// True if the expression can be evaluated without any row, parameter or
    /// subquery (a constant expression in the sense of grammar.md).
    pub fn is_constant(&self) -> bool {
        !self.any(&|e| {
            matches!(
                e,
                Expr::Column { .. }
                    | Expr::Param { .. }
                    | Expr::AggRef { .. }
                    | Expr::ScalarSubquery { .. }
                    | Expr::Exists { .. }
                    | Expr::InSubquery { .. }
            ) || matches!(
                e,
                Expr::Function {
                    func: ScalarFunc::PqSleep,
                    ..
                }
            )
        })
    }

    /// True if evaluating the expression can never raise an error, so it may
    /// be evaluated where the row engine would skip it (or skipped where it
    /// would evaluate it) without changing the outcome.
    pub fn is_infallible(&self) -> bool {
        match self {
            Expr::Literal { .. } | Expr::Column { .. } | Expr::Param { .. } => true,
            Expr::Not(_)
            | Expr::And(..)
            | Expr::Or(..)
            | Expr::IsNull { .. }
            | Expr::Compare { .. }
            | Expr::Between { .. }
            | Expr::InList { .. }
            | Expr::Like { .. }
            | Expr::Concat(..) => self.children().into_iter().all(Expr::is_infallible),
            _ => false,
        }
    }

    /// Splits a conjunction into its conjuncts.
    pub fn into_conjuncts(self, out: &mut Vec<Expr>) {
        match self {
            Expr::And(l, r) => {
                l.into_conjuncts(out);
                r.into_conjuncts(out);
            }
            e => out.push(e),
        }
    }

    /// Rebuilds a conjunction (None for an empty list).
    pub fn conjunction(conjuncts: Vec<Expr>) -> Option<Expr> {
        conjuncts
            .into_iter()
            .reduce(|a, b| Expr::And(Box::new(a), Box::new(b)))
    }
}

/// Human-readable rendering (used for plan display).
impl fmt::Display for Expr {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let list = |items: &[Expr]| {
            items
                .iter()
                .map(|a| a.to_string())
                .collect::<Vec<_>>()
                .join(", ")
        };
        let not = |n: bool| if n { "NOT " } else { "" };
        match self {
            Expr::Literal { value, .. } => match value {
                Value::Null => f.write_str("NULL"),
                Value::Str(s) => write!(f, "'{}'", s.replace('\'', "''")),
                v => f.write_str(&v.to_text()),
            },
            Expr::Column { index, .. } => write!(f, "#{index}"),
            Expr::Param { index, .. } => write!(f, "$outer{index}"),
            Expr::AggRef { index, .. } => write!(f, "$agg{index}"),
            Expr::Negate { expr, .. } => write!(f, "(-{expr})"),
            Expr::Not(e) => write!(f, "(NOT {e})"),
            Expr::And(l, r) => write!(f, "({l} AND {r})"),
            Expr::Or(l, r) => write!(f, "({l} OR {r})"),
            Expr::Arith {
                op, left, right, ..
            }
            | Expr::Compare { op, left, right } => write!(f, "({left} {} {right})", op.symbol()),
            Expr::Concat(l, r) => write!(f, "({l} || {r})"),
            Expr::IsNull { expr, negated } => write!(f, "({expr} IS {}NULL)", not(*negated)),
            Expr::Cast { expr, to } => write!(f, "CAST({expr} AS {to})"),
            Expr::Function { func, args, .. } => match func {
                ScalarFunc::Round(n) => write!(f, "ROUND({}, {n})", list(args)),
                ScalarFunc::DateTrunc(unit) => {
                    write!(
                        f,
                        "DATE_TRUNC('{}', {})",
                        format!("{unit:?}").to_lowercase(),
                        list(args)
                    )
                }
                ScalarFunc::DateDiffDays => write!(f, "DATE_DIFF('day', {})", list(args)),
                _ => write!(f, "{}({})", func.name(), list(args)),
            },
            Expr::Case {
                operand,
                whens,
                else_expr,
                ..
            } => {
                f.write_str("CASE")?;
                if let Some(o) = operand {
                    write!(f, " {o}")?;
                }
                for (w, t) in whens {
                    write!(f, " WHEN {w} THEN {t}")?;
                }
                if let Some(e) = else_expr {
                    write!(f, " ELSE {e}")?;
                }
                f.write_str(" END")
            }
            Expr::Between {
                expr,
                low,
                high,
                negated,
            } => write!(f, "({expr} {}BETWEEN {low} AND {high})", not(*negated)),
            Expr::InList {
                expr,
                list: items,
                negated,
            } => write!(f, "({expr} {}IN ({}))", not(*negated), list(items)),
            Expr::Like {
                expr,
                pattern,
                negated,
            } => write!(f, "({expr} {}LIKE {pattern})", not(*negated)),
            Expr::ScalarSubquery { sub, .. } => write!(f, "$subquery{}", sub.id),
            Expr::Exists { sub, .. } => write!(f, "EXISTS($subquery{})", sub.id),
            Expr::InSubquery {
                expr, sub, negated, ..
            } => write!(f, "({expr} {}IN $subquery{})", not(*negated), sub.id),
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

impl fmt::Display for AggregateCall {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.arg {
            None => f.write_str("COUNT(*)"),
            Some(a) => write!(
                f,
                "{}({}{a})",
                self.func.name(),
                if self.distinct { "DISTINCT " } else { "" }
            ),
        }
    }
}
