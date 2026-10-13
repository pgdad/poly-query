//! Name-resolution scopes (semantics.md §1, §8, §9): range variables of a
//! FROM clause, CTE environments and correlation to enclosing queries.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;

use crate::error::{Error, Result};
use crate::planner::expr::Expr;
use crate::planner::logical::LogicalPlan;
use crate::sql::ast::Ident;
use crate::storage::Field;

/// A named relation visible in a FROM clause.
#[derive(Debug, Clone)]
pub struct RangeVar {
    pub name: String,
    pub fields: Vec<Field>,
    /// Index of the relation's first column in the combined input row.
    pub offset: usize,
}

/// The range variables of one FROM clause, laid out left to right.
#[derive(Debug, Clone, Default)]
pub struct Scope {
    pub vars: Vec<RangeVar>,
    /// Index of each range variable by ASCII-lowercased name.
    by_name: HashMap<String, usize>,
    /// (range variable, field) of every column, by ASCII-lowercased name.
    by_column: HashMap<String, Vec<(usize, usize)>>,
}

impl Scope {
    pub fn single(name: &str, fields: Vec<Field>) -> Scope {
        let mut scope = Scope::default();
        scope.push(RangeVar {
            name: name.to_string(),
            fields,
            offset: 0,
        });
        scope
    }

    fn push(&mut self, var: RangeVar) {
        let v = self.vars.len();
        self.by_name.insert(var.name.to_ascii_lowercase(), v);
        for (i, f) in var.fields.iter().enumerate() {
            self.by_column
                .entry(f.name.to_ascii_lowercase())
                .or_default()
                .push((v, i));
        }
        self.vars.push(var);
    }

    pub fn width(&self) -> usize {
        self.vars.last().map_or(0, |v| v.offset + v.fields.len())
    }

    pub fn var(&self, name: &Ident) -> Option<&RangeVar> {
        self.by_name
            .get(&name.value.to_ascii_lowercase())
            .map(|&v| &self.vars[v])
    }

    /// Concatenates the scopes of a join's inputs; duplicate range variable
    /// names are a SEMANTIC_ERROR. Linear in the size of `right`.
    pub fn merge(left: Scope, right: Scope) -> Result<Scope> {
        let shift = left.width();
        let mut scope = left;
        for mut v in right.vars {
            if scope.by_name.contains_key(&v.name.to_ascii_lowercase()) {
                return Err(Error::semantic(format!(
                    "table name or alias '{}' is used more than once in FROM",
                    v.name
                )));
            }
            v.offset += shift;
            scope.push(v);
        }
        Ok(scope)
    }

    /// Resolves a column against this scope only. `Ok(None)` means the name
    /// is not visible here (it may still refer to an enclosing query).
    pub fn lookup(
        &self,
        qualifier: Option<&Ident>,
        name: &Ident,
    ) -> Result<Option<(usize, &Field)>> {
        let key = name.value.to_ascii_lowercase();
        let matches: Vec<(usize, usize)> = match qualifier {
            Some(q) => match self.by_name.get(&q.value.to_ascii_lowercase()) {
                Some(&v) => self.vars[v]
                    .fields
                    .iter()
                    .enumerate()
                    .filter(|(_, f)| name.matches(&f.name))
                    .map(|(i, _)| (v, i))
                    .collect(),
                None => return Ok(None),
            },
            None => self.by_column.get(&key).cloned().unwrap_or_default(),
        };
        if matches.len() > 1 {
            return Err(name.pos.error(Error::semantic(format!(
                "ambiguous column '{}'",
                name.value
            ))));
        }
        let found = matches.first().map(|&(v, i)| {
            let var = &self.vars[v];
            (var.offset + i, &var.fields[i])
        });
        match (found, qualifier) {
            (None, Some(q)) => Err(name.pos.error(Error::semantic(format!(
                "unknown column '{}.{}'",
                q.value, name.value
            )))),
            (found, _) => Ok(found),
        }
    }
}

/// A bound common table expression.
#[derive(Debug)]
pub struct CteDef {
    pub name: String,
    /// The bound plan; each reference gets a copy, the last one the plan
    /// itself (so a chain of CTEs each referencing the previous one is
    /// bound in linear time and memory).
    plan: RefCell<Option<LogicalPlan>>,
    /// References not yet bound: an upper bound (references counted by
    /// name in the query text, see `count_table_refs`).
    uses_left: Cell<usize>,
    /// Output fields (renamed by the CTE column list, if any).
    pub fields: Vec<Field>,
    /// Identity of the correlation context the CTE was bound in.
    pub corr_key: usize,
    /// Whether the plan references correlation parameters.
    pub correlated: bool,
}

impl CteDef {
    pub fn new(
        name: String,
        plan: LogicalPlan,
        uses: usize,
        fields: Vec<Field>,
        corr_key: usize,
        correlated: bool,
    ) -> Self {
        CteDef {
            name,
            plan: RefCell::new(Some(plan)),
            uses_left: Cell::new(uses),
            fields,
            corr_key,
            correlated,
        }
    }

    /// The plan for one reference to the CTE; `copied` is called with the
    /// plan's size (`LogicalPlan::size`) before the plan is copied (rather
    /// than moved).
    pub fn instantiate(&self, copied: impl FnOnce(usize) -> Result<()>) -> Result<LogicalPlan> {
        let left = self.uses_left.get().saturating_sub(1);
        self.uses_left.set(left);
        let mut slot = self.plan.borrow_mut();
        let plan = if left == 0 {
            slot.take()
        } else {
            copied(slot.as_ref().map_or(0, LogicalPlan::size))?;
            slot.clone()
        };
        plan.ok_or_else(|| {
            Error::internal(format!(
                "CTE '{}' referenced more often than counted",
                self.name
            ))
        })
    }
}

/// CTEs visible at some point of a query, innermost `WITH` first.
#[derive(Debug, Default)]
pub struct CteEnv<'a> {
    defs: Vec<CteDef>,
    /// Index of each definition by ASCII-lowercased name.
    index: HashMap<String, usize>,
    pub parent: Option<&'a CteEnv<'a>>,
}

impl<'a> CteEnv<'a> {
    pub fn new(parent: Option<&'a CteEnv<'a>>) -> Self {
        CteEnv {
            defs: Vec::new(),
            index: HashMap::new(),
            parent,
        }
    }

    pub fn lookup(&self, name: &str) -> Option<&CteDef> {
        match self.index.get(&name.to_ascii_lowercase()) {
            Some(&i) => Some(&self.defs[i]),
            None => self.parent.and_then(|p| p.lookup(name)),
        }
    }

    /// True if this (innermost) `WITH` already defines `name`.
    pub fn defines(&self, name: &str) -> bool {
        self.index.contains_key(&name.to_ascii_lowercase())
    }

    pub fn define(&mut self, def: CteDef) {
        self.index
            .insert(def.name.to_ascii_lowercase(), self.defs.len());
        self.defs.push(def);
    }
}

/// The link from a subquery to the scope its expression appears in. Outer
/// column references become parameters: `params[i]` is an expression valid
/// in `outer` whose value the subquery sees as `Expr::Param { index: i }`.
pub struct Correlation<'a> {
    pub outer: &'a ExprScope<'a>,
    pub params: RefCell<Vec<Expr>>,
}

impl<'a> Correlation<'a> {
    pub fn new(outer: &'a ExprScope<'a>) -> Self {
        Correlation {
            outer,
            params: RefCell::new(Vec::new()),
        }
    }

    fn add_param(&self, e: Expr) -> usize {
        let mut params = self.params.borrow_mut();
        if let Some(i) = params.iter().position(|p| *p == e) {
            return i;
        }
        params.push(e);
        params.len() - 1
    }
}

/// Identity of an optional correlation context (0 for none).
pub fn corr_key(corr: Option<&Correlation<'_>>) -> usize {
    corr.map_or(0, |c| c as *const Correlation<'_> as usize)
}

/// Everything an expression can see: the current FROM scope, the
/// correlation to enclosing queries, and the visible CTEs.
#[derive(Clone, Copy)]
pub struct ExprScope<'a> {
    pub scope: &'a Scope,
    pub corr: Option<&'a Correlation<'a>>,
    pub env: &'a CteEnv<'a>,
}

impl ExprScope<'_> {
    /// Resolves a column reference to an input column or a correlation
    /// parameter; returns the bound expression and the column's name.
    pub fn resolve(&self, qualifier: Option<&Ident>, name: &Ident) -> Result<(Expr, String)> {
        self.resolve_opt(qualifier, name)?.ok_or_else(|| {
            let text = match qualifier {
                Some(q) => format!("{}.{}", q.value, name.value),
                None => name.value.clone(),
            };
            name.pos
                .error(Error::semantic(format!("unknown column '{text}'")))
        })
    }

    fn resolve_opt(
        &self,
        qualifier: Option<&Ident>,
        name: &Ident,
    ) -> Result<Option<(Expr, String)>> {
        if let Some((index, f)) = self.scope.lookup(qualifier, name)? {
            let e = Expr::Column {
                index,
                ty: f.data_type,
            };
            return Ok(Some((e, f.name.clone())));
        }
        if let Some(corr) = self.corr
            && let Some((outer, col_name)) = corr.outer.resolve_opt(qualifier, name)?
        {
            let ty = outer.data_type();
            let index = corr.add_param(outer);
            return Ok(Some((Expr::Param { index, ty }, col_name)));
        }
        Ok(None)
    }
}
