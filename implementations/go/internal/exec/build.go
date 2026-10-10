package exec

import (
	"polyquery/internal/errs"
	"polyquery/internal/plan"
	"polyquery/internal/types"
)

// Build turns a logical plan into an executable operator tree.
func Build(ec *Context, n plan.Node) (Operator, error) {
	switch x := n.(type) {
	case *plan.Scan:
		return &scanOp{ec: ec, table: x.Table, needed: x.Needed, buf: make(types.Row, len(x.Table.Columns))}, nil
	case *plan.Values:
		op := &valuesOp{buf: make(types.Row, 0, 8)}
		for _, r := range x.Rows {
			fns := make([]evalFn, len(r))
			for i, e := range r {
				f, err := compile(ec, e)
				if err != nil {
					return nil, err
				}
				fns[i] = f
			}
			op.rows = append(op.rows, fns)
		}
		return op, nil
	case *plan.Filter:
		in, err := Build(ec, x.Input)
		if err != nil {
			return nil, err
		}
		pred, err := compile(ec, x.Pred)
		if err != nil {
			return nil, err
		}
		return &filterOp{ec: ec, input: in, pred: pred}, nil
	case *plan.Project:
		in, err := Build(ec, x.Input)
		if err != nil {
			return nil, err
		}
		fns, err := compileAll(ec, x.Exprs)
		if err != nil {
			return nil, err
		}
		return &projectOp{input: in, exprs: fns, buf: make(types.Row, len(fns))}, nil
	case *plan.Aggregate:
		if len(x.GroupBy) > 0 {
			return nil, errs.New(errs.Unsupported, "GROUP BY is not supported")
		}
		in, err := Build(ec, x.Input)
		if err != nil {
			return nil, err
		}
		op := &aggregateOp{ec: ec, input: in, calls: x.Aggs, args: make([]evalFn, len(x.Aggs))}
		for i, c := range x.Aggs {
			if c.Arg != nil {
				if op.args[i], err = compile(ec, c.Arg); err != nil {
					return nil, err
				}
			}
		}
		return op, nil
	case *plan.Sort:
		return buildSort(ec, x, x.Limit)
	case *plan.Limit:
		return buildLimit(ec, x)
	}
	return nil, errs.New(errs.InternalError, "cannot execute plan node %T", n)
}

func compileAll(ec *Context, exprs []plan.Expr) ([]evalFn, error) {
	fns := make([]evalFn, len(exprs))
	for i, e := range exprs {
		f, err := compile(ec, e)
		if err != nil {
			return nil, err
		}
		fns[i] = f
	}
	return fns, nil
}

func buildSort(ec *Context, x *plan.Sort, limit int64) (Operator, error) {
	in, err := Build(ec, x.Input)
	if err != nil {
		return nil, err
	}
	cols := x.Input.Columns()
	keys := make([]sortKey, len(x.Keys))
	for i, k := range x.Keys {
		keys[i] = sortKey{index: k.Index, typ: cols[k.Index].Type, desc: k.Desc, nullsFirst: k.NullsFirst}
	}
	return &sortOp{ec: ec, input: in, keys: keys, limit: limit}, nil
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

func buildLimit(ec *Context, x *plan.Limit) (Operator, error) {
	count, err := limitValue(ec, x.Count, -1)
	if err != nil {
		return nil, err
	}
	offset, err := limitValue(ec, x.Offset, 0)
	if err != nil {
		return nil, err
	}
	var in Operator
	if s, ok := x.Input.(*plan.Sort); ok && count >= 0 && count+offset >= 0 {
		in, err = buildSort(ec, s, count+offset)
	} else {
		in, err = Build(ec, x.Input)
	}
	if err != nil {
		return nil, err
	}
	return &limitOp{input: in, offset: offset, count: count}, nil
}
