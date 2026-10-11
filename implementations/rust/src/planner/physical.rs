//! Physical planning: chooses concrete algorithms for logical operators
//! (hash vs nested-loop join, build side, top-N sort) and renders the
//! EXPLAIN plan JSON (indexes-and-planning.md §4).

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use super::access::{self, IndexLookup};
use super::expr::{AggregateCall, Expr, KeyDomain};
use super::logical::{JoinType, LogicalPlan, SortKey};
use crate::json::Json;
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

#[derive(Debug, Clone, Copy)]
pub struct PhysicalOptions {
    pub join: JoinStrategy,
    /// Query option `use_indexes` (false ⇒ never use indexes).
    pub use_indexes: bool,
}

impl Default for PhysicalOptions {
    fn default() -> Self {
        PhysicalOptions {
            join: JoinStrategy::Auto,
            use_indexes: true,
        }
    }
}

/// Equi-join key pair: `left` is evaluated on left rows, `right` on right rows.
#[derive(Debug, Clone)]
pub struct JoinKey {
    pub left: Expr,
    pub right: Expr,
    pub domain: KeyDomain,
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
}

/// Lowers an optimized logical plan.
pub fn lower(plan: &LogicalPlan, opts: PhysicalOptions) -> PhysicalPlan {
    let boxed = |p: &LogicalPlan| Box::new(lower(p, opts));
    match plan {
        LogicalPlan::SingleRow => PhysicalPlan::Values,
        LogicalPlan::Scan {
            table,
            columns,
            schema,
            ..
        } => PhysicalPlan::TableScan {
            table: table.clone(),
            columns: columns.clone(),
            schema: schema.clone(),
            groups: (0..table.row_groups().len()).collect(),
        },
        LogicalPlan::Filter { input, predicate } => param_lookup(input, predicate, opts)
            .unwrap_or_else(|| match &**input {
                LogicalPlan::Scan {
                    table,
                    columns,
                    schema,
                    indexes,
                } => lower_filtered_scan(table, columns, schema, indexes, predicate, opts),
                _ => PhysicalPlan::Filter {
                    input: boxed(input),
                    predicate: predicate.clone(),
                },
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
        } => lower_join(left, right, *join_type, on.as_ref(), schema, opts),
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
    }
}

/// Access path of a scan with pushed-down conjuncts: an index scan (plus a
/// residual filter) if an index is selective enough, otherwise a filtered
/// table scan reading only row groups whose statistics admit a match.
fn lower_filtered_scan(
    table: &Arc<Table>,
    columns: &[usize],
    schema: &[Field],
    indexes: &[Arc<Index>],
    predicate: &Expr,
    opts: PhysicalOptions,
) -> PhysicalPlan {
    let mut conjuncts = Vec::new();
    predicate.clone().into_conjuncts(&mut conjuncts);
    if opts.use_indexes
        && let Some(choice) = access::choose_index(table, columns, indexes, &conjuncts)
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
    PhysicalPlan::Filter {
        input: Box::new(PhysicalPlan::TableScan {
            table: table.clone(),
            columns: columns.to_vec(),
            schema: schema.to_vec(),
            groups,
        }),
        predicate: predicate.clone(),
    }
}

fn lower_join(
    left: &LogicalPlan,
    right: &LogicalPlan,
    join_type: JoinType,
    on: Option<&Expr>,
    schema: &[Field],
    opts: PhysicalOptions,
) -> PhysicalPlan {
    let lw = left.width();
    let mut keys = Vec::new();
    let mut residual = Vec::new();
    if let Some(on) = on {
        let mut conjuncts = Vec::new();
        on.clone().into_conjuncts(&mut conjuncts);
        for c in conjuncts {
            match equi_key(&c, lw) {
                Some(k) if opts.join != JoinStrategy::NestedLoop => keys.push(k),
                _ => residual.push(c),
            }
        }
    }
    let (l, r) = (Box::new(lower(left, opts)), Box::new(lower(right, opts)));
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
    if opts.join == JoinStrategy::Merge {
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

fn has_param(e: &Expr) -> bool {
    e.any(&|x| matches!(x, Expr::Param { .. }))
}

/// Lowers `Filter(input, … AND key = param-expr AND …)` to a ParamLookup when
/// `input` does not depend on correlation parameters.
fn param_lookup(
    input: &LogicalPlan,
    predicate: &Expr,
    opts: PhysicalOptions,
) -> Option<PhysicalPlan> {
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
        input: Box::new(lower(input, opts)),
        keys,
        residual: Expr::conjunction(residual),
    })
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

/// Rough cardinality estimate used for build-side selection.
pub fn estimate_rows(plan: &LogicalPlan) -> f64 {
    match plan {
        LogicalPlan::SingleRow => 1.0,
        LogicalPlan::Scan { table, .. } => table.row_count as f64,
        LogicalPlan::Filter { input, predicate } => match &**input {
            LogicalPlan::Scan { table, columns, .. } => {
                let mut conjuncts = Vec::new();
                predicate.clone().into_conjuncts(&mut conjuncts);
                table.row_count as f64 * access::filter_selectivity(table, columns, &conjuncts)
            }
            _ => estimate_rows(input) * access::DEFAULT_SELECTIVITY,
        },
        LogicalPlan::Project { input, .. }
        | LogicalPlan::Sort { input, .. }
        | LogicalPlan::Distinct { input } => estimate_rows(input),
        LogicalPlan::Aggregate {
            input, group_by, ..
        } => {
            if group_by.is_empty() {
                1.0
            } else {
                (estimate_rows(input) / 2.0).max(1.0)
            }
        }
        LogicalPlan::Join {
            left,
            right,
            join_type,
            on,
            ..
        } => {
            let (l, r) = (estimate_rows(left), estimate_rows(right));
            match (join_type, on) {
                (JoinType::Cross, _) | (_, None) => l * r,
                (JoinType::Left, _) => l.max(r),
                _ => l.max(r),
            }
        }
        LogicalPlan::Limit { input, limit, .. } => {
            let n = estimate_rows(input);
            limit.map_or(n, |l| n.min(l as f64))
        }
    }
}

impl PhysicalPlan {
    pub fn schema(&self) -> &[Field] {
        match self {
            PhysicalPlan::Values => &[],
            PhysicalPlan::TableScan { schema, .. }
            | PhysicalPlan::IndexScan { schema, .. }
            | PhysicalPlan::Project { schema, .. }
            | PhysicalPlan::HashAggregate { schema, .. }
            | PhysicalPlan::HashJoin { schema, .. }
            | PhysicalPlan::MergeJoin { schema, .. }
            | PhysicalPlan::NestedLoopJoin { schema, .. } => schema,
            PhysicalPlan::Filter { input, .. }
            | PhysicalPlan::ParamLookup { input, .. }
            | PhysicalPlan::Distinct { input }
            | PhysicalPlan::Sort { input, .. }
            | PhysicalPlan::Limit { input, .. } => input.schema(),
        }
    }

    /// Plan as a JSON tree (indexes-and-planning.md §4 node format).
    pub fn to_json(&self) -> Json {
        self.to_json_with(&|_| Vec::new())
    }

    /// Plan JSON with extra properties per node from `annotate` (placed
    /// before the node's `children`).
    pub fn to_json_with(
        &self,
        annotate: &dyn Fn(&PhysicalPlan) -> Vec<(&'static str, Json)>,
    ) -> Json {
        let mut json = self.node_json(annotate);
        let extra = annotate(self);
        if !extra.is_empty()
            && let Json::Object(fields) = &mut json
        {
            let at = fields.len().saturating_sub(1);
            for (k, (name, v)) in extra.into_iter().enumerate() {
                fields.insert(at + k, (name.to_string(), v));
            }
        }
        json
    }

    fn node_json(&self, annotate: &dyn Fn(&PhysicalPlan) -> Vec<(&'static str, Json)>) -> Json {
        let names =
            |fields: &[Field]| Json::Array(fields.iter().map(|f| Json::str(&f.name)).collect());
        let exprs =
            |es: &[Expr]| Json::Array(es.iter().map(|e| Json::String(e.to_string())).collect());
        let node = |op: &str, mut props: Vec<(&str, Json)>, children: Vec<&PhysicalPlan>| {
            let mut fields = vec![("op", Json::str(op))];
            fields.append(&mut props);
            fields.push((
                "children",
                Json::Array(
                    children
                        .into_iter()
                        .map(|c| c.to_json_with(annotate))
                        .collect(),
                ),
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
        }
    }
}
