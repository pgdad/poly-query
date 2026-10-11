//! Physical planning: maps an (optimized) logical plan to physical
//! operators. This step alone takes the physical decisions
//! (indexes-and-planning.md §4, phase-5.md):
//!
//! * column selection — scans read only the columns the plan uses;
//! * access paths — table scan (with row-group skipping) or index scan;
//! * join algorithms — hash (and build side), merge or nested loop,
//!   honouring the `join` option; top-N sorts; `ParamLookup` for
//!   correlated filters;
//! * the execution model — row-at-a-time or vectorized, worker threads, and
//!   whether filters over column scans (and hash keys) use the native
//!   kernels.
//!
//! The plans of subqueries inside expressions are planned too. The
//! resulting [`PhysicalQuery`] is what executes and what EXPLAIN renders.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use super::access::{self, IndexLookup};
use super::cardinality::estimate_rows;
use super::expr::{AggregateCall, Expr, KeyDomain};
use super::logical::{JoinType, LogicalPlan, SortKey};
use super::optimizer::column_pruning::prune_columns;
use crate::catalog::Catalog;
use crate::exec::native_filter::NativeFilter;
use crate::json::Json;
use crate::native::Kernels;
use crate::sql::ast::BinaryOp;
use crate::storage::{Field, Index, Table};

/// Join algorithm preference (query option `join`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum JoinStrategy {
    #[default]
    Auto,
    Hash,
    Merge,
    NestedLoop,
}

/// The query options that steer physical planning.
#[derive(Debug, Clone, Copy)]
pub struct PhysicalOptions {
    pub join: JoinStrategy,
    /// Query option `use_indexes` (false ⇒ never use indexes).
    pub use_indexes: bool,
    /// Query option `mode`: vectorized (`vectorized`/`auto`) or row.
    pub vectorized: bool,
    /// Worker threads for vectorized execution (option `threads` or the
    /// engine default).
    pub threads: usize,
    /// Query option `native` (effective only with a loaded library).
    pub native: bool,
}

impl Default for PhysicalOptions {
    fn default() -> Self {
        PhysicalOptions {
            join: JoinStrategy::Auto,
            use_indexes: true,
            vectorized: false,
            threads: 1,
            native: false,
        }
    }
}

impl PhysicalOptions {
    /// The same options for the row-at-a-time baseline engine (serial,
    /// without native kernels).
    pub fn row_baseline(self) -> PhysicalOptions {
        PhysicalOptions {
            vectorized: false,
            threads: 1,
            native: false,
            ..self
        }
    }
}

/// Execution model of a physical plan.
#[derive(Debug, Clone, Copy)]
pub struct Execution {
    /// Batch-at-a-time execution instead of the row-at-a-time baseline.
    pub vectorized: bool,
    /// Worker threads (1 for row-at-a-time execution).
    pub threads: usize,
    /// Native kernels used by filters over column scans, hash keys and
    /// aggregation.
    pub native: Option<&'static Kernels>,
}

impl Execution {
    fn choose(opts: &PhysicalOptions) -> Execution {
        Execution {
            vectorized: opts.vectorized,
            threads: if opts.vectorized {
                opts.threads.max(1)
            } else {
                1
            },
            native: crate::native::loaded().filter(|_| opts.native),
        }
    }
}

/// The row-at-a-time baseline.
impl Default for Execution {
    fn default() -> Self {
        Execution::choose(&PhysicalOptions::default())
    }
}

/// Equi-join key pair: `left` is evaluated on left rows, `right` on right rows.
#[derive(Debug, Clone)]
pub struct JoinKey {
    pub left: Expr,
    pub right: Expr,
    pub domain: KeyDomain,
}

/// A planned query: its operator tree, the execution model and the plans
/// of the subqueries inside its expressions.
#[derive(Debug, Clone)]
pub struct PhysicalQuery {
    pub root: PhysicalPlan,
    pub execution: Execution,
    pub subqueries: Arc<SubqueryPlans>,
}

/// Physical plans of the subqueries of a statement, by subquery id.
pub type SubqueryPlans = HashMap<usize, PhysicalSubquery>;

#[derive(Debug)]
pub struct PhysicalSubquery {
    pub plan: PhysicalPlan,
    /// Correlated subqueries run once per distinct parameter tuple, usually
    /// on small inputs, so they use the row-at-a-time engine (lower set-up
    /// cost) whatever the query's execution model.
    pub row_at_a_time: bool,
}

#[derive(Debug, Clone)]
pub enum PhysicalPlan {
    /// One empty row.
    Values,
    /// Full scan of the row groups `groups` (the others were excluded by
    /// their min/max statistics).
    TableScan {
        table: Arc<Table>,
        columns: Vec<usize>,
        schema: Vec<Field>,
        groups: Vec<usize>,
    },
    /// A filter directly above a table scan of a column-layout table whose
    /// conjuncts are (partly) evaluated with the native kernels; `filter`
    /// splits `predicate` into kernel conjuncts and a residual. EXPLAIN shows
    /// it as a `Filter` (with the number of native conjuncts) over a
    /// `TableScan`.
    NativeFilterScan {
        table: Arc<Table>,
        columns: Vec<usize>,
        schema: Vec<Field>,
        groups: Vec<usize>,
        predicate: Expr,
        filter: Arc<NativeFilter>,
        kernels: &'static Kernels,
    },
    /// Rows located through an index, in table order.
    IndexScan {
        table: Arc<Table>,
        index: Arc<Index>,
        lookup: IndexLookup,
        columns: Vec<usize>,
        schema: Vec<Field>,
        estimated_rows: f64,
    },
    Filter {
        input: Box<PhysicalPlan>,
        predicate: Expr,
    },
    Project {
        input: Box<PhysicalPlan>,
        exprs: Vec<Expr>,
        schema: Vec<Field>,
    },
    HashAggregate {
        input: Box<PhysicalPlan>,
        group_by: Vec<Expr>,
        aggregates: Vec<AggregateCall>,
        schema: Vec<Field>,
    },
    /// Equi-join; `residual` is evaluated over the combined (left ++ right) row.
    HashJoin {
        left: Box<PhysicalPlan>,
        right: Box<PhysicalPlan>,
        join_type: JoinType,
        keys: Vec<JoinKey>,
        residual: Option<Expr>,
        /// Build the hash table on the left input (INNER joins only).
        build_left: bool,
        schema: Vec<Field>,
    },
    /// Sort-merge equi-join: both inputs are sorted on the keys and merged;
    /// `residual` is evaluated over the combined row.
    MergeJoin {
        left: Box<PhysicalPlan>,
        right: Box<PhysicalPlan>,
        join_type: JoinType,
        keys: Vec<JoinKey>,
        residual: Option<Expr>,
        schema: Vec<Field>,
    },
    NestedLoopJoin {
        left: Box<PhysicalPlan>,
        right: Box<PhysicalPlan>,
        join_type: JoinType,
        predicate: Option<Expr>,
        schema: Vec<Field>,
    },
    Distinct {
        input: Box<PhysicalPlan>,
    },
    /// Correlated-subquery filter `key = <outer parameter expression>` over a
    /// parameter-independent input: the input is hashed on the keys once per
    /// query (cached under `id`) and each execution probes it. In `keys`,
    /// `left` is evaluated on input rows and `right` (no columns) on the
    /// current parameters.
    ParamLookup {
        id: usize,
        input: Box<PhysicalPlan>,
        keys: Vec<JoinKey>,
        residual: Option<Expr>,
    },
    /// Sort; with `top = Some(n)` only the first n rows are produced.
    Sort {
        input: Box<PhysicalPlan>,
        keys: Vec<SortKey>,
        top: Option<usize>,
    },
    Limit {
        input: Box<PhysicalPlan>,
        offset: u64,
        limit: Option<u64>,
    },
    /// The rows of every input in turn (`UNION ALL`).
    UnionAll {
        inputs: Vec<PhysicalPlan>,
        schema: Vec<Field>,
    },
    /// A subplan occurring several times in the statement (see
    /// [`super::shared`]): vectorized execution computes it once per query
    /// and replays its rows under `id`. EXPLAIN shows just the input.
    Shared {
        id: usize,
        input: Box<PhysicalPlan>,
    },
}

/// Plans an (optimized) logical query against the catalog snapshot it was
/// bound to.
pub fn plan(logical: &LogicalPlan, catalog: &Catalog, opts: PhysicalOptions) -> PhysicalQuery {
    let execution = Execution::choose(&opts);
    let planner = |execution: Execution| Planner {
        catalog,
        opts,
        native: execution.native,
    };
    let root = planner(execution).plan(logical);
    // Every subquery (also nested ones) once, by id.
    let mut subqueries = SubqueryPlans::new();
    let mut pending = Vec::new();
    logical.visit_subqueries(&mut |sub, correlated| pending.push((sub.clone(), correlated)));
    while let Some((sub, correlated)) = pending.pop() {
        if subqueries.contains_key(&sub.id) {
            continue;
        }
        let model = if correlated {
            Execution::choose(&opts.row_baseline())
        } else {
            execution
        };
        let plan = planner(model).plan(&sub.plan);
        sub.plan
            .visit_subqueries(&mut |sub, correlated| pending.push((sub.clone(), correlated)));
        subqueries.insert(
            sub.id,
            PhysicalSubquery {
                plan,
                row_at_a_time: correlated,
            },
        );
    }
    let mut root = root;
    if execution.vectorized {
        super::shared::share_common_subplans(&mut root, &mut subqueries);
    }
    PhysicalQuery {
        root,
        execution,
        subqueries: Arc::new(subqueries),
    }
}

/// Lowers logical operators for one execution model.
struct Planner<'a> {
    catalog: &'a Catalog,
    opts: PhysicalOptions,
    /// Kernels for native filters over column scans.
    native: Option<&'static Kernels>,
}

impl Planner<'_> {
    /// Lowers one query level. Column selection comes first: a plan the
    /// optimizer did not prune (`optimize: false`) still scans only the
    /// columns it uses.
    fn plan(&self, logical: &LogicalPlan) -> PhysicalPlan {
        self.lower(&prune_columns(logical.clone()))
    }

    fn lower(&self, plan: &LogicalPlan) -> PhysicalPlan {
        let boxed = |p: &LogicalPlan| Box::new(self.lower(p));
        match plan {
            LogicalPlan::SingleRow => PhysicalPlan::Values,
            LogicalPlan::Scan {
                table,
                columns,
                schema,
            } => PhysicalPlan::TableScan {
                table: table.clone(),
                columns: columns.clone(),
                schema: schema.clone(),
                groups: (0..table.row_groups().len()).collect(),
            },
            LogicalPlan::Filter { input, predicate } => self
                .param_lookup(input, predicate)
                .unwrap_or_else(|| match &**input {
                    LogicalPlan::Scan {
                        table,
                        columns,
                        schema,
                    } => self.lower_filtered_scan(table, columns, schema, predicate),
                    _ => self.filter(self.lower(input), predicate.clone()),
                }),
            LogicalPlan::Project {
                input,
                exprs,
                schema,
            } => PhysicalPlan::Project {
                input: boxed(input),
                exprs: exprs.clone(),
                schema: schema.clone(),
            },
            LogicalPlan::Aggregate {
                input,
                group_by,
                aggregates,
                schema,
            } => PhysicalPlan::HashAggregate {
                input: boxed(input),
                group_by: group_by.clone(),
                aggregates: aggregates.clone(),
                schema: schema.clone(),
            },
            LogicalPlan::Join {
                left,
                right,
                join_type,
                on,
                schema,
            } => self.lower_join(left, right, *join_type, on.as_ref(), schema),
            LogicalPlan::Distinct { input } => PhysicalPlan::Distinct {
                input: boxed(input),
            },
            LogicalPlan::Sort { input, keys } => PhysicalPlan::Sort {
                input: boxed(input),
                keys: keys.clone(),
                top: None,
            },
            LogicalPlan::Limit {
                input,
                offset,
                limit,
            } => {
                let input = match (&**input, limit) {
                    // ORDER BY … LIMIT: only the first offset+limit rows are needed.
                    (LogicalPlan::Sort { input, keys }, Some(n)) => Box::new(PhysicalPlan::Sort {
                        input: boxed(input),
                        keys: keys.clone(),
                        top: Some(usize::try_from(offset.saturating_add(*n)).unwrap_or(usize::MAX)),
                    }),
                    (other, _) => boxed(other),
                };
                PhysicalPlan::Limit {
                    input,
                    offset: *offset,
                    limit: *limit,
                }
            }
            LogicalPlan::UnionAll { inputs, schema } => PhysicalPlan::UnionAll {
                inputs: inputs.iter().map(|p| self.lower(p)).collect(),
                schema: schema.clone(),
            },
        }
    }

    /// A filter over `input`; directly above a table scan it is evaluated
    /// with the native kernels when they are enabled and apply.
    fn filter(&self, input: PhysicalPlan, predicate: Expr) -> PhysicalPlan {
        if let (
            Some(kernels),
            PhysicalPlan::TableScan {
                table,
                columns,
                schema,
                groups,
            },
        ) = (self.native, &input)
            && let Some(filter) = NativeFilter::analyze(&predicate, table, columns)
        {
            return PhysicalPlan::NativeFilterScan {
                table: table.clone(),
                columns: columns.clone(),
                schema: schema.clone(),
                groups: groups.clone(),
                predicate,
                filter: Arc::new(filter),
                kernels,
            };
        }
        PhysicalPlan::Filter {
            input: Box::new(input),
            predicate,
        }
    }

    /// Access path of a scan with pushed-down conjuncts: an index scan (plus a
    /// residual filter) if an index is selective enough, otherwise a filtered
    /// table scan reading only row groups whose statistics admit a match.
    fn lower_filtered_scan(
        &self,
        table: &Arc<Table>,
        columns: &[usize],
        schema: &[Field],
        predicate: &Expr,
    ) -> PhysicalPlan {
        let mut conjuncts = Vec::new();
        predicate.clone().into_conjuncts(&mut conjuncts);
        if self.opts.use_indexes
            && let Some(choice) =
                access::choose_index(table, columns, &self.catalog.indexes_for(table), &conjuncts)
        {
            let residual: Vec<Expr> = conjuncts
                .into_iter()
                .enumerate()
                .filter(|(i, _)| !choice.used.contains(i))
                .map(|(_, c)| c)
                .collect();
            let scan = PhysicalPlan::IndexScan {
                table: table.clone(),
                index: choice.index,
                lookup: choice.lookup,
                columns: columns.to_vec(),
                schema: schema.to_vec(),
                estimated_rows: choice.selectivity * table.row_count as f64,
            };
            return match Expr::conjunction(residual) {
                Some(predicate) => PhysicalPlan::Filter {
                    input: Box::new(scan),
                    predicate,
                },
                None => scan,
            };
        }
        let groups = access::select_row_groups(table, columns, &conjuncts);
        let scan = PhysicalPlan::TableScan {
            table: table.clone(),
            columns: columns.to_vec(),
            schema: schema.to_vec(),
            groups,
        };
        self.filter(scan, predicate.clone())
    }

    fn lower_join(
        &self,
        left: &LogicalPlan,
        right: &LogicalPlan,
        join_type: JoinType,
        on: Option<&Expr>,
        schema: &[Field],
    ) -> PhysicalPlan {
        let lw = left.width();
        let mut keys = Vec::new();
        let mut residual = Vec::new();
        if let Some(on) = on {
            let mut conjuncts = Vec::new();
            on.clone().into_conjuncts(&mut conjuncts);
            for c in conjuncts {
                match equi_key(&c, lw) {
                    Some(k) if self.opts.join != JoinStrategy::NestedLoop => keys.push(k),
                    _ => residual.push(c),
                }
            }
        }
        let (l, r) = (Box::new(self.lower(left)), Box::new(self.lower(right)));
        if keys.is_empty() {
            return PhysicalPlan::NestedLoopJoin {
                left: l,
                right: r,
                join_type: if on.is_none() && join_type == JoinType::Inner {
                    JoinType::Cross
                } else {
                    join_type
                },
                predicate: on.cloned(),
                schema: schema.to_vec(),
            };
        }
        let join_type = if join_type == JoinType::Cross {
            JoinType::Inner
        } else {
            join_type
        };
        if self.opts.join == JoinStrategy::Merge {
            return PhysicalPlan::MergeJoin {
                left: l,
                right: r,
                join_type,
                keys,
                residual: Expr::conjunction(residual),
                schema: schema.to_vec(),
            };
        }
        let build_left = join_type != JoinType::Left && estimate_rows(left) < estimate_rows(right);
        PhysicalPlan::HashJoin {
            left: l,
            right: r,
            join_type,
            keys,
            residual: Expr::conjunction(residual),
            build_left,
            schema: schema.to_vec(),
        }
    }

    /// Lowers `Filter(input, … AND key = param-expr AND …)` to a ParamLookup
    /// when `input` does not depend on correlation parameters.
    fn param_lookup(&self, input: &LogicalPlan, predicate: &Expr) -> Option<PhysicalPlan> {
        static NEXT_ID: AtomicUsize = AtomicUsize::new(0);
        if !has_param(predicate) {
            return None;
        }
        let mut input_has_param = false;
        input.visit_exprs(&mut |e| input_has_param |= has_param(e));
        if input_has_param {
            return None;
        }
        let mut conjuncts = Vec::new();
        predicate.clone().into_conjuncts(&mut conjuncts);
        let mut keys = Vec::new();
        let mut residual = Vec::new();
        for c in conjuncts {
            let key = match &c {
                Expr::Compare {
                    op: BinaryOp::Eq,
                    left,
                    right,
                } => {
                    let is_inner = |e: &Expr| !e.columns().is_empty() && !has_param(e);
                    let is_outer = |e: &Expr| e.columns().is_empty() && has_param(e);
                    if is_inner(left) && is_outer(right) {
                        Some((left, right))
                    } else if is_inner(right) && is_outer(left) {
                        Some((right, left))
                    } else {
                        None
                    }
                }
                _ => None,
            };
            match key {
                Some((inner, outer)) => keys.push(JoinKey {
                    domain: KeyDomain::of(inner.data_type(), outer.data_type()),
                    left: (**inner).clone(),
                    right: (**outer).clone(),
                }),
                None => residual.push(c),
            }
        }
        if keys.is_empty() {
            return None;
        }
        Some(PhysicalPlan::ParamLookup {
            id: NEXT_ID.fetch_add(1, Ordering::Relaxed),
            input: Box::new(self.lower(input)),
            keys,
            residual: Expr::conjunction(residual),
        })
    }
}

fn has_param(e: &Expr) -> bool {
    e.any(&|x| matches!(x, Expr::Param { .. }))
}

/// Recognizes `l = r` where one side reads only left columns and the other
/// only right columns (each side reading at least one column).
fn equi_key(c: &Expr, lw: usize) -> Option<JoinKey> {
    let Expr::Compare {
        op: BinaryOp::Eq,
        left,
        right,
    } = c
    else {
        return None;
    };
    let side = |e: &Expr| {
        let cols = e.columns();
        if cols.is_empty() {
            None
        } else if cols.iter().all(|&i| i < lw) {
            Some(true)
        } else if cols.iter().all(|&i| i >= lw) {
            Some(false)
        } else {
            None
        }
    };
    let (l, r) = match (side(left)?, side(right)?) {
        (true, false) => (left, right),
        (false, true) => (right, left),
        _ => return None,
    };
    let mut r = (**r).clone();
    r.remap_columns(&|i| i - lw);
    Some(JoinKey {
        domain: KeyDomain::of(l.data_type(), r.data_type()),
        left: (**l).clone(),
        right: r,
    })
}

impl PhysicalPlan {
    pub fn schema(&self) -> &[Field] {
        match self {
            PhysicalPlan::Values => &[],
            PhysicalPlan::TableScan { schema, .. }
            | PhysicalPlan::NativeFilterScan { schema, .. }
            | PhysicalPlan::IndexScan { schema, .. }
            | PhysicalPlan::Project { schema, .. }
            | PhysicalPlan::HashAggregate { schema, .. }
            | PhysicalPlan::HashJoin { schema, .. }
            | PhysicalPlan::MergeJoin { schema, .. }
            | PhysicalPlan::NestedLoopJoin { schema, .. }
            | PhysicalPlan::UnionAll { schema, .. } => schema,
            PhysicalPlan::Filter { input, .. }
            | PhysicalPlan::ParamLookup { input, .. }
            | PhysicalPlan::Distinct { input }
            | PhysicalPlan::Sort { input, .. }
            | PhysicalPlan::Limit { input, .. }
            | PhysicalPlan::Shared { input, .. } => input.schema(),
        }
    }

    /// The input plans of this node.
    pub fn children(&self) -> Vec<&PhysicalPlan> {
        match self {
            PhysicalPlan::Values
            | PhysicalPlan::TableScan { .. }
            | PhysicalPlan::NativeFilterScan { .. }
            | PhysicalPlan::IndexScan { .. } => Vec::new(),
            PhysicalPlan::Filter { input, .. }
            | PhysicalPlan::Project { input, .. }
            | PhysicalPlan::HashAggregate { input, .. }
            | PhysicalPlan::Distinct { input }
            | PhysicalPlan::ParamLookup { input, .. }
            | PhysicalPlan::Sort { input, .. }
            | PhysicalPlan::Limit { input, .. }
            | PhysicalPlan::Shared { input, .. } => vec![input],
            PhysicalPlan::HashJoin { left, right, .. }
            | PhysicalPlan::MergeJoin { left, right, .. }
            | PhysicalPlan::NestedLoopJoin { left, right, .. } => vec![left, right],
            PhysicalPlan::UnionAll { inputs, .. } => inputs.iter().collect(),
        }
    }

    /// The input plans of this node, mutably.
    pub fn children_mut(&mut self) -> Vec<&mut PhysicalPlan> {
        match self {
            PhysicalPlan::Values
            | PhysicalPlan::TableScan { .. }
            | PhysicalPlan::NativeFilterScan { .. }
            | PhysicalPlan::IndexScan { .. } => Vec::new(),
            PhysicalPlan::Filter { input, .. }
            | PhysicalPlan::Project { input, .. }
            | PhysicalPlan::HashAggregate { input, .. }
            | PhysicalPlan::Distinct { input }
            | PhysicalPlan::ParamLookup { input, .. }
            | PhysicalPlan::Sort { input, .. }
            | PhysicalPlan::Limit { input, .. }
            | PhysicalPlan::Shared { input, .. } => vec![input],
            PhysicalPlan::HashJoin { left, right, .. }
            | PhysicalPlan::MergeJoin { left, right, .. }
            | PhysicalPlan::NestedLoopJoin { left, right, .. } => vec![left, right],
            PhysicalPlan::UnionAll { inputs, .. } => inputs.iter_mut().collect(),
        }
    }

    /// Plan as a JSON tree (indexes-and-planning.md §4 node format).
    pub fn to_json(&self) -> Json {
        let names =
            |fields: &[Field]| Json::Array(fields.iter().map(|f| Json::str(&f.name)).collect());
        let exprs =
            |es: &[Expr]| Json::Array(es.iter().map(|e| Json::String(e.to_string())).collect());
        let node = |op: &str, mut props: Vec<(&str, Json)>, children: Vec<&PhysicalPlan>| {
            let mut fields = vec![("op", Json::str(op))];
            fields.append(&mut props);
            fields.push((
                "children",
                Json::Array(children.into_iter().map(|c| c.to_json()).collect()),
            ));
            Json::object(fields)
        };
        match self {
            PhysicalPlan::Values => node("Values", vec![("rows", Json::int(1))], vec![]),
            PhysicalPlan::TableScan {
                table,
                schema,
                groups,
                ..
            } => {
                let mut props = vec![
                    ("table", Json::str(&table.name)),
                    ("columns", names(schema)),
                    ("layout", Json::str(table.layout().name())),
                ];
                if table.is_file_backed() {
                    props.push(("row_groups", Json::uint(table.row_groups().len() as u64)));
                    props.push(("row_groups_read", Json::uint(groups.len() as u64)));
                }
                node("TableScan", props, vec![])
            }
            PhysicalPlan::NativeFilterScan {
                table,
                columns,
                schema,
                groups,
                predicate,
                filter,
                ..
            } => {
                let scan = PhysicalPlan::TableScan {
                    table: table.clone(),
                    columns: columns.clone(),
                    schema: schema.clone(),
                    groups: groups.clone(),
                };
                node(
                    "Filter",
                    vec![
                        ("predicate", Json::String(predicate.to_string())),
                        ("native", Json::uint(filter.native_conjuncts() as u64)),
                    ],
                    vec![&scan],
                )
            }
            PhysicalPlan::IndexScan {
                table,
                index,
                lookup,
                schema,
                estimated_rows,
                ..
            } => node(
                "IndexScan",
                vec![
                    ("table", Json::str(&table.name)),
                    ("index", Json::str(&index.name)),
                    ("kind", Json::str(index.kind.name())),
                    ("column", Json::str(index.column_name())),
                    ("lookup", Json::String(lookup.to_string())),
                    ("columns", names(schema)),
                    ("estimated_rows", Json::uint(estimated_rows.round() as u64)),
                ],
                vec![],
            ),
            PhysicalPlan::Filter { input, predicate } => node(
                "Filter",
                vec![("predicate", Json::String(predicate.to_string()))],
                vec![input],
            ),
            PhysicalPlan::Project {
                input,
                exprs: es,
                schema,
            } => node(
                "Project",
                vec![("columns", names(schema)), ("exprs", exprs(es))],
                vec![input],
            ),
            PhysicalPlan::HashAggregate {
                input,
                group_by,
                aggregates,
                ..
            } => node(
                "Aggregate",
                vec![
                    ("group_by", exprs(group_by)),
                    (
                        "aggregates",
                        Json::Array(
                            aggregates
                                .iter()
                                .map(|a| Json::String(a.to_string()))
                                .collect(),
                        ),
                    ),
                ],
                vec![input],
            ),
            PhysicalPlan::HashJoin {
                left,
                right,
                join_type,
                keys,
                residual,
                build_left,
                ..
            } => node(
                "HashJoin",
                vec![
                    ("join_type", Json::str(join_type.name())),
                    (
                        "keys",
                        Json::Array(
                            keys.iter()
                                .map(|k| Json::String(format!("{} = {}", k.left, k.right)))
                                .collect(),
                        ),
                    ),
                    (
                        "residual",
                        residual
                            .as_ref()
                            .map_or(Json::Null, |r| Json::String(r.to_string())),
                    ),
                    (
                        "build_side",
                        Json::str(if *build_left { "left" } else { "right" }),
                    ),
                ],
                vec![left, right],
            ),
            PhysicalPlan::MergeJoin {
                left,
                right,
                join_type,
                keys,
                residual,
                ..
            } => node(
                "MergeJoin",
                vec![
                    ("join_type", Json::str(join_type.name())),
                    (
                        "keys",
                        Json::Array(
                            keys.iter()
                                .map(|k| Json::String(format!("{} = {}", k.left, k.right)))
                                .collect(),
                        ),
                    ),
                    (
                        "residual",
                        residual
                            .as_ref()
                            .map_or(Json::Null, |r| Json::String(r.to_string())),
                    ),
                ],
                vec![left, right],
            ),
            PhysicalPlan::NestedLoopJoin {
                left,
                right,
                join_type,
                predicate,
                ..
            } => node(
                "NestedLoopJoin",
                vec![
                    ("join_type", Json::str(join_type.name())),
                    (
                        "predicate",
                        predicate
                            .as_ref()
                            .map_or(Json::Null, |p| Json::String(p.to_string())),
                    ),
                ],
                vec![left, right],
            ),
            PhysicalPlan::Distinct { input } => node("Distinct", vec![], vec![input]),
            PhysicalPlan::Shared { input, .. } => input.to_json(),
            PhysicalPlan::ParamLookup {
                input,
                keys,
                residual,
                ..
            } => node(
                "ParamLookup",
                vec![
                    (
                        "keys",
                        Json::Array(
                            keys.iter()
                                .map(|k| Json::String(format!("{} = {}", k.left, k.right)))
                                .collect(),
                        ),
                    ),
                    (
                        "residual",
                        residual
                            .as_ref()
                            .map_or(Json::Null, |r| Json::String(r.to_string())),
                    ),
                ],
                vec![input],
            ),
            PhysicalPlan::Sort { input, keys, top } => node(
                "Sort",
                vec![
                    (
                        "keys",
                        Json::Array(
                            keys.iter()
                                .map(|k| {
                                    Json::String(format!(
                                        "{} {} NULLS {}",
                                        k.expr,
                                        if k.descending { "DESC" } else { "ASC" },
                                        if k.nulls_first { "FIRST" } else { "LAST" }
                                    ))
                                })
                                .collect(),
                        ),
                    ),
                    ("top", top.map_or(Json::Null, |n| Json::uint(n as u64))),
                ],
                vec![input],
            ),
            PhysicalPlan::Limit {
                input,
                offset,
                limit,
            } => node(
                "Limit",
                vec![
                    ("offset", Json::uint(*offset)),
                    ("limit", limit.map(Json::uint).unwrap_or(Json::Null)),
                ],
                vec![input],
            ),
            PhysicalPlan::UnionAll { inputs, schema } => node(
                "UnionAll",
                vec![("columns", names(schema))],
                inputs.iter().collect(),
            ),
        }
    }
}

impl PhysicalQuery {
    /// The EXPLAIN plan: the operator tree, with the execution model on the
    /// root node (`"execution": {"mode": …, "threads": …[, "native": …]}`,
    /// placed before its `children`).
    pub fn to_json(&self) -> Json {
        let mut json = self.root.to_json();
        let execution = &self.execution;
        if let Json::Object(fields) = &mut json {
            let mut props = vec![
                (
                    "mode",
                    Json::str(if execution.vectorized {
                        "vectorized"
                    } else {
                        "row"
                    }),
                ),
                ("threads", Json::uint(execution.threads as u64)),
            ];
            if let Some(k) = execution.native {
                props.push(("native", Json::str(k.variant())));
            }
            let at = fields.len().saturating_sub(1);
            fields.insert(at, ("execution".to_string(), Json::object(props)));
        }
        json
    }

    /// Result columns.
    pub fn schema(&self) -> &[Field] {
        self.root.schema()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::planner::expr::SubqueryPlan;
    use crate::planner::optimizer::test_util::*;
    use crate::types::DataType;

    fn plan_with(logical: &LogicalPlan, opts: PhysicalOptions) -> PhysicalQuery {
        plan(logical, &Catalog::default(), opts)
    }

    fn equi_join() -> LogicalPlan {
        let t = table("t", &["a"], 50);
        let u = table("u", &["b"], 5);
        join(
            scan(&t),
            scan(&u),
            JoinType::Inner,
            Some(cmp(BinaryOp::Eq, col(0), col(1))),
        )
    }

    #[test]
    fn the_join_option_selects_the_algorithm() {
        let op = |join| {
            let opts = PhysicalOptions {
                join,
                ..PhysicalOptions::default()
            };
            match plan_with(&equi_join(), opts).root {
                PhysicalPlan::HashJoin { build_left, .. } => {
                    // The smaller input (u, on the right) is the build side.
                    assert!(!build_left);
                    "hash"
                }
                PhysicalPlan::MergeJoin { .. } => "merge",
                PhysicalPlan::NestedLoopJoin { .. } => "nested_loop",
                other => panic!("unexpected {other:?}"),
            }
        };
        assert_eq!(op(JoinStrategy::Auto), "hash");
        assert_eq!(op(JoinStrategy::Hash), "hash");
        assert_eq!(op(JoinStrategy::Merge), "merge");
        assert_eq!(op(JoinStrategy::NestedLoop), "nested_loop");
    }

    #[test]
    fn row_execution_is_serial() {
        let opts = PhysicalOptions {
            vectorized: true,
            threads: 4,
            ..PhysicalOptions::default()
        };
        let vectorized = plan_with(&equi_join(), opts).execution;
        assert!(vectorized.vectorized);
        assert_eq!(vectorized.threads, 4);
        let row = plan_with(&equi_join(), opts.row_baseline()).execution;
        assert!(!row.vectorized);
        assert_eq!(row.threads, 1);
        assert!(row.native.is_none());
    }

    #[test]
    fn unoptimized_plans_scan_only_the_columns_they_use() {
        let t = table("t", &["a", "b", "c"], 4);
        let logical = project(scan(&t), &[2]);
        let root = plan_with(&logical, PhysicalOptions::default()).root;
        let PhysicalPlan::Project { input, .. } = root else {
            panic!("expected a projection");
        };
        let PhysicalPlan::TableScan { columns, .. } = *input else {
            panic!("expected a table scan");
        };
        assert_eq!(columns, [2]);
    }

    #[test]
    fn correlated_subqueries_are_planned_for_the_row_engine() {
        let t = table("t", &["a"], 4);
        let u = table("u", &["b"], 4);
        let param = Expr::Param {
            index: 0,
            ty: DataType::Int64,
        };
        let sub = |id, plan, params| Expr::Exists {
            sub: Arc::new(SubqueryPlan { id, plan }),
            params,
        };
        let correlated = sub(
            0,
            filter(scan(&u), cmp(BinaryOp::Eq, col(0), param)),
            vec![col(0)],
        );
        let uncorrelated = sub(1, scan(&u), Vec::new());
        let logical = filter(scan(&t), and(correlated, uncorrelated));
        let opts = PhysicalOptions {
            vectorized: true,
            ..PhysicalOptions::default()
        };
        let query = plan_with(&logical, opts);
        assert!(query.subqueries[&0].row_at_a_time);
        assert!(matches!(
            query.subqueries[&0].plan,
            PhysicalPlan::ParamLookup { .. }
        ));
        assert!(!query.subqueries[&1].row_at_a_time);
    }
}
