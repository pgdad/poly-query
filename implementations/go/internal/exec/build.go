package exec

import (
	"polyquery/internal/errs"
	"polyquery/internal/physical"
	"polyquery/internal/plan"
	"polyquery/internal/types"
)

// Build turns a physical plan node into an executable operator tree.
func Build(ec *Context, n physical.Node) (Operator, error) {
	switch x := n.(type) {
	case *physical.TableScan:
		return &scanOp{ec: ec, table: x.Table, ords: x.Ords, filters: x.Filters, buf: make(types.Row, len(x.Ords))}, nil
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
		in, err := Build(ec, x.Input)
		if err != nil {
			return nil, err
		}
		pred, err := compile(ec, layoutOf(x.Input.Schema()), x.Pred)
		if err != nil {
			return nil, err
		}
		return &filterOp{ec: ec, input: in, pred: pred}, nil
	case *physical.Project:
		in, err := Build(ec, x.Input)
		if err != nil {
			return nil, err
		}
		fns, err := compileAll(ec, layoutOf(x.Input.Schema()), x.Exprs)
		if err != nil {
			return nil, err
		}
		return &projectOp{input: in, exprs: fns, buf: make(types.Row, len(fns))}, nil
	case *physical.HashAggregate:
		return buildAggregate(ec, x)
	case *physical.HashJoin:
		return buildHashJoin(ec, x)
	case *physical.NestedLoopJoin:
		left, err := Build(ec, x.Left)
		if err != nil {
			return nil, err
		}
		right, err := Build(ec, x.Right)
		if err != nil {
			return nil, err
		}
		op := &nestedLoopJoinOp{
			joinCounter: joinCounter{ec: ec}, kind: x.Kind, left: left, right: right,
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
		in, err := Build(ec, x.Input)
		if err != nil {
			return nil, err
		}
		lay := layoutOf(x.Input.Schema())
		keys := make([]sortKey, len(x.Keys))
		for i, k := range x.Keys {
			ref, ok := k.Expr.(*plan.ColumnRef)
			if !ok {
				return nil, errs.New(errs.InternalError, "sort key is not a column")
			}
			idx, ok := lay[ref.ID]
			if !ok {
				return nil, errs.New(errs.InternalError, "unbound sort key %s", ref)
			}
			keys[i] = sortKey{index: idx, typ: ref.T, desc: k.Desc, nullsFirst: k.NullsFirst}
		}
		return &sortOp{ec: ec, input: in, keys: keys, limit: x.Limit}, nil
	case *physical.Limit:
		return buildLimit(ec, x)
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
		in, err := Build(ec, x.Input)
		if err != nil {
			return nil, err
		}
		cols := x.Input.Schema()
		ts := make([]types.Type, len(cols))
		for i, c := range cols {
			ts[i] = c.Type
		}
		return &distinctOp{ec: ec, input: in, types: ts, seen: map[string]struct{}{}}, nil
	}
	return nil, errs.New(errs.InternalError, "cannot execute plan node %T", n)
}

func buildAggregate(ec *Context, x *physical.HashAggregate) (Operator, error) {
	in, err := Build(ec, x.Input)
	if err != nil {
		return nil, err
	}
	lay := layoutOf(x.Input.Schema())
	op := &hashAggregateOp{ec: ec, input: in, calls: x.Aggs, args: make([]evalFn, len(x.Aggs))}
	if op.keys, err = compileAll(ec, lay, x.Keys); err != nil {
		return nil, err
	}
	for _, k := range x.Keys {
		op.keyTypes = append(op.keyTypes, k.Type())
	}
	for i, c := range x.Aggs {
		if c.Arg != nil {
			if op.args[i], err = compile(ec, lay, c.Arg); err != nil {
				return nil, err
			}
		}
	}
	return op, nil
}

func buildHashJoin(ec *Context, x *physical.HashJoin) (Operator, error) {
	left, err := Build(ec, x.Left)
	if err != nil {
		return nil, err
	}
	right, err := Build(ec, x.Right)
	if err != nil {
		return nil, err
	}
	lk, err := compileAll(ec, layoutOf(x.Left.Schema()), x.LeftKeys)
	if err != nil {
		return nil, err
	}
	rk, err := compileAll(ec, layoutOf(x.Right.Schema()), x.RightKeys)
	if err != nil {
		return nil, err
	}
	keyTypes := func(es []plan.Expr) []types.Type {
		ts := make([]types.Type, len(es))
		for i, e := range es {
			ts[i] = e.Type()
		}
		return ts
	}
	op := &hashJoinOp{
		joinCounter: joinCounter{ec: ec}, kind: x.Kind, buildLeft: x.BuildLeft,
		leftW: len(x.Left.Schema()), rightW: len(x.Right.Schema()),
	}
	op.out = make(types.Row, op.leftW+op.rightW)
	if x.BuildLeft {
		op.build, op.probe = left, right
		op.buildKeys, op.probeKeys = lk, rk
		op.buildTypes, op.probeTypes = keyTypes(x.LeftKeys), keyTypes(x.RightKeys)
	} else {
		op.build, op.probe = right, left
		op.buildKeys, op.probeKeys = rk, lk
		op.buildTypes, op.probeTypes = keyTypes(x.RightKeys), keyTypes(x.LeftKeys)
	}
	if x.Residual != nil {
		if op.residual, err = compile(ec, layoutOf(x.Schema()), x.Residual); err != nil {
			return nil, err
		}
	}
	return op, nil
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

func buildLimit(ec *Context, x *physical.Limit) (Operator, error) {
	count, err := limitValue(ec, x.Count, -1)
	if err != nil {
		return nil, err
	}
	offset, err := limitValue(ec, x.Offset, 0)
	if err != nil {
		return nil, err
	}
	in, err := Build(ec, x.Input)
	if err != nil {
		return nil, err
	}
	return &limitOp{input: in, offset: offset, count: count}, nil
}
