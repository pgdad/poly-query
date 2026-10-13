package exec

import (
	"polyquery/internal/errs"
	"polyquery/internal/physical"
	"polyquery/internal/plan"
	"polyquery/internal/types"
)

// Build turns a physical plan node into a row-at-a-time (Volcano) operator
// tree.
func Build(ec *Context, n physical.Node) (Operator, error) { return build(ec, n, false) }

// BuildRoot builds the operator tree of a query in the execution mode
// selected by ec.Vectorized.
func BuildRoot(ec *Context, n physical.Node) (Operator, error) { return input(ec, n, ec.Vectorized) }

// input builds the operator of a child node: vectorized children are read
// row by row through an adapter.
func input(ec *Context, n physical.Node, vec bool) (Operator, error) {
	if !vec {
		return build(ec, n, false)
	}
	b, err := BuildBatch(ec, n)
	if err != nil {
		return nil, err
	}
	return newRowReader(b, schemaTypes(n.Schema())), nil
}

// build builds the row operator of n; its inputs are vectorized if vec is
// set.
func build(ec *Context, n physical.Node, vec bool) (Operator, error) {
	if err := ec.Check(); err != nil {
		return nil, err
	}
	switch x := n.(type) {
	case *physical.TableScan:
		if op, ok, err := parallelRowPipeline(ec, x); ok || err != nil {
			return op, err
		}
		return newScan(ec, x, nil), nil
	case *physical.IndexScan:
		return &indexScanOp{ec: ec, node: x, buf: make(types.Row, len(x.Ords))}, nil
	case *physical.Values:
		op := &valuesOp{buf: make(types.Row, 0, len(x.Cols))}
		for _, r := range x.Rows {
			fns, err := compileAll(ec, nil, r)
			if err != nil {
				return nil, err
			}
			op.rows = append(op.rows, fns)
		}
		return op, nil
	case *physical.Filter:
		if op, ok, err := parallelRowPipeline(ec, x); ok || err != nil {
			return op, err
		}
		if scan, root, rest, ok := nativeScanFilter(ec, x); ok && !vec {
			return nativeRowFilter(ec, x, newScan(ec, scan, nil), root, rest)
		}
		in, err := input(ec, x.Input, vec)
		if err != nil {
			return nil, err
		}
		return newFilterOp(ec, in, x.Input.Schema(), x.Pred)
	case *physical.Project:
		if op, ok, err := parallelRowPipeline(ec, x); ok || err != nil {
			return op, err
		}
		in, err := input(ec, x.Input, vec)
		if err != nil {
			return nil, err
		}
		fns, err := compileAll(ec, layoutOf(x.Input.Schema()), x.Exprs)
		if err != nil {
			return nil, err
		}
		return &projectOp{input: in, exprs: fns, buf: make(types.Row, len(fns))}, nil
	case *physical.HashAggregate:
		if ec.isShared(x) {
			return &lazyRowsOp{run: func() ([]types.Row, error) {
				return ec.sharedRows(x, func() ([]types.Row, error) {
					op, err := buildAggregate(ec, x, vec)
					if err != nil {
						return nil, err
					}
					return rowsOf(ec, op)
				})
			}}, nil
		}
		return buildAggregate(ec, x, vec)
	case *physical.HashJoin:
		return buildHashJoin(ec, x, vec)
	case *physical.MergeJoin:
		return buildMergeJoin(ec, x, vec)
	case *physical.NestedLoopJoin:
		left, err := input(ec, x.Left, vec)
		if err != nil {
			return nil, err
		}
		right, err := input(ec, x.Right, vec)
		if err != nil {
			return nil, err
		}
		op := &nestedLoopJoinOp{
			joinCounter: newJoinCounter(ec), kind: x.Kind, left: left, right: right,
			leftW: len(x.Left.Schema()), rightW: len(x.Right.Schema()),
		}
		op.out = make(types.Row, op.leftW+op.rightW)
		if x.Cond != nil {
			if op.cond, err = compile(ec, layoutOf(x.Schema()), x.Cond); err != nil {
				return nil, err
			}
		}
		return op, nil
	case *physical.Sort:
		in, err := input(ec, x.Input, vec)
		if err != nil {
			return nil, err
		}
		keys, err := sortKeys(x)
		if err != nil {
			return nil, err
		}
		return &sortOp{ec: ec, input: in, keys: keys, limit: x.Limit}, nil
	case *physical.Limit:
		return buildLimit(ec, x, vec)
	case *physical.Materialize:
		rows, err := ec.materialized(x)
		if err != nil {
			return nil, err
		}
		return &replayOp{rows: rows}, nil
	case *physical.ParamLookup:
		op := &paramLookupOp{ec: ec, node: x}
		var err error
		if op.outer, err = compileAll(ec, nil, x.OuterKeys); err != nil {
			return nil, err
		}
		for _, k := range x.OuterKeys {
			op.outTypes = append(op.outTypes, k.Type())
		}
		if x.Residual != nil {
			if op.residual, err = compile(ec, layoutOf(x.Input.Schema()), x.Residual); err != nil {
				return nil, err
			}
		}
		return op, nil
	case *physical.HashDistinct:
		in, err := input(ec, x.Input, vec)
		if err != nil {
			return nil, err
		}
		cols := x.Input.Schema()
		ts := make([]types.Type, len(cols))
		for i, c := range cols {
			ts[i] = c.Type
		}
		return &distinctOp{ec: ec, input: in, types: ts, seen: map[string]struct{}{}}, nil
	case *physical.UnionAll:
		return newUnionOp(ec, x, vec), nil
	}
	return nil, errs.New(errs.InternalError, "cannot execute plan node %T", n)
}

func newFilterOp(ec *Context, in Operator, cols []plan.Column, pred plan.Expr) (Operator, error) {
	f, err := compile(ec, layoutOf(cols), pred)
	if err != nil {
		return nil, err
	}
	return &filterOp{ec: ec, input: in, pred: f}, nil
}

// nativeRowFilter attaches the native part of a filter to its scan and
// filters the remaining conjuncts (if any) row by row.
func nativeRowFilter(ec *Context, x *physical.Filter, scan *scanOp, root *npred, rest plan.Expr) (Operator, error) {
	scan.filter = newNFilter(ec.Native, root)
	if rest == nil {
		return scan, nil
	}
	return newFilterOp(ec, scan, x.Input.Schema(), rest)
}

func buildAggregate(ec *Context, x *physical.HashAggregate, vec bool) (Operator, error) {
	if p, ok := planNativeAggregate(ec, x); ok {
		return &nativeAggOp{ec: ec, p: p}, nil
	}
	if !vec {
		if op, ok, err := parallelRowAggregate(ec, x); ok || err != nil {
			return op, err
		}
	}
	in, err := input(ec, x.Input, vec)
	if err != nil {
		return nil, err
	}
	agg, err := newRowAggInput(ec, x)
	if err != nil {
		return nil, err
	}
	return &hashAggregateOp{ec: ec, input: in, in: agg, keyTypes: exprTypes(x.Keys), calls: x.Aggs}, nil
}

func newRowAggInput(ec *Context, x *physical.HashAggregate) (*rowAggInput, error) {
	lay := layoutOf(x.Input.Schema())
	in := &rowAggInput{args: make([]evalFn, len(x.Aggs)), vals: make(types.Row, len(x.Keys))}
	var err error
	if in.keys, err = compileAll(ec, lay, x.Keys); err != nil {
		return nil, err
	}
	for i, c := range x.Aggs {
		if c.Arg != nil {
			if in.args[i], err = compile(ec, lay, c.Arg); err != nil {
				return nil, err
			}
		}
	}
	return in, nil
}

func buildHashJoin(ec *Context, x *physical.HashJoin, vec bool) (Operator, error) {
	if !vec {
		if op, ok, err := parallelRowPipeline(ec, x); ok || err != nil {
			return op, err
		}
	}
	shared, err := newRowJoinBuild(ec, x, vec)
	if err != nil {
		return nil, err
	}
	_, probeNode, _, _ := buildSide(x)
	probe, err := input(ec, probeNode, vec)
	if err != nil {
		return nil, err
	}
	return newHashJoinProbe(ec, x, shared, probe)
}

// limitValue evaluates a constant LIMIT/OFFSET expression; NULL or absent
// yields def.
func limitValue(ec *Context, e plan.Expr, def int64) (int64, error) {
	if e == nil {
		return def, nil
	}
	v, err := evalConstant(ec, e)
	if err != nil {
		return 0, err
	}
	if v.Null {
		return def, nil
	}
	if v.I < 0 {
		return 0, errs.New(errs.InvalidArgument, "LIMIT/OFFSET must not be negative")
	}
	return v.I, nil
}

func buildLimit(ec *Context, x *physical.Limit, vec bool) (Operator, error) {
	count, err := limitValue(ec, x.Count, -1)
	if err != nil {
		return nil, err
	}
	offset, err := limitValue(ec, x.Offset, 0)
	if err != nil {
		return nil, err
	}
	in, err := input(ec, x.Input, vec)
	if err != nil {
		return nil, err
	}
	return &limitOp{input: in, offset: offset, count: count}, nil
}
