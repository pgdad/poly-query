package engine

import (
	"context"

	"polyquery/internal/errs"
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

// CreateRequest describes a table built from in-memory rows (embedding
// API). Every value must already have the representation of its column's
// type (see types.Value).
type CreateRequest struct {
	Table   string
	Columns []storage.ColumnDef
	Rows    []types.Row
	Replace bool
}

// Create builds a table from rows and publishes it atomically.
func (e *Engine) Create(req CreateRequest) (*storage.Table, error) {
	if err := e.checkNewTable(req.Table, req.Columns, req.Replace); err != nil {
		return nil, err
	}
	if int64(len(req.Rows)) > e.cfg.MaxTableRows {
		return nil, errs.New(errs.ResourceLimit, "table exceeds the maximum of %d rows", e.cfg.MaxTableRows)
	}
	vecs := make([]*storage.Vector, len(req.Columns))
	for i, c := range req.Columns {
		vecs[i] = storage.NewVector(c.Type, len(req.Rows))
	}
	for r, row := range req.Rows {
		if len(row) != len(req.Columns) {
			return nil, errs.New(errs.InvalidArgument, "row %d has %d values, expected %d", r+1, len(row), len(req.Columns))
		}
		for i, v := range row {
			vecs[i].Append(v)
		}
	}
	return e.publish(req.Table, req.Columns, vecs, len(req.Rows), req.Replace)
}

// CreateAs runs a query and publishes its result as a table (like CREATE
// TABLE … AS SELECT). Result columns of the untyped NULL type become
// STRING columns.
func (e *Engine) CreateAs(ctx context.Context, table, sql string, opts QueryOptions, replace bool) (*storage.Table, error) {
	if !replace && e.catalog.Exists(table) {
		return nil, errs.New(errs.AlreadyExists, "table %q already exists", table)
	}
	cur, err := e.Start(ctx, sql, opts)
	if err != nil {
		return nil, err
	}
	defer cur.Close()
	cols := make([]storage.ColumnDef, len(cur.Columns))
	for i, c := range cur.Columns {
		t := c.Type
		if t.Kind == types.KindNull {
			t = types.String
		}
		cols[i] = storage.ColumnDef{Name: c.Name, Type: t}
	}
	if err := e.checkNewTable(table, cols, replace); err != nil {
		return nil, err
	}
	vecs := make([]*storage.Vector, len(cols))
	for i, c := range cols {
		vecs[i] = storage.NewVector(c.Type, 0)
	}
	rows := 0
	for {
		row, err := cur.Next()
		if err != nil {
			return nil, err
		}
		if row == nil {
			break
		}
		if rows++; int64(rows) > e.cfg.MaxTableRows {
			return nil, errs.New(errs.ResourceLimit, "table exceeds the maximum of %d rows", e.cfg.MaxTableRows)
		}
		for i, v := range row {
			vecs[i].Append(v)
		}
	}
	return e.publish(table, cols, vecs, rows, replace)
}

// checkNewTable validates the name and columns of a table to be created.
func (e *Engine) checkNewTable(name string, cols []storage.ColumnDef, replace bool) error {
	if name == "" {
		return errs.New(errs.InvalidArgument, "table name must not be empty")
	}
	if len(cols) == 0 {
		return errs.New(errs.InvalidArgument, "a table needs at least one column")
	}
	seen := make(map[string]bool, len(cols))
	for _, c := range cols {
		if c.Name == "" {
			return errs.New(errs.InvalidArgument, "empty column name")
		}
		key := storage.FoldKey(c.Name)
		if seen[key] {
			return errs.New(errs.InvalidArgument, "duplicate column name %q", c.Name)
		}
		seen[key] = true
		if c.Type.Kind == types.KindNull {
			return errs.New(errs.InvalidArgument, "column %q has no type", c.Name)
		}
	}
	if !replace && e.catalog.Exists(name) {
		return errs.New(errs.AlreadyExists, "table %q already exists", name)
	}
	return nil
}

func (e *Engine) publish(name string, cols []storage.ColumnDef, vecs []*storage.Vector, rows int, replace bool) (*storage.Table, error) {
	t := storage.Build(name, &storage.Data{Columns: cols, Vectors: vecs, Rows: rows}, storage.BuildOptions{})
	if err := e.catalog.Put(t, nil, replace); err != nil {
		return nil, err
	}
	e.cfg.Logger.Info("table created", "table", t.Name, "rows", t.Rows)
	return t, nil
}
