// Package catalog maps table and index names (ASCII case-insensitive) to
// immutable tables and their indexes. The catalog state is an immutable
// Snapshot replaced atomically by every mutation (copy-on-write), so a query
// holding a snapshot sees one consistent catalog version for its whole
// execution, and mutations are atomic and linearizable.
package catalog

import (
	"sort"
	"sync"
	"sync/atomic"

	"polyquery/internal/errs"
	"polyquery/internal/index"
	"polyquery/internal/storage"
)

// Entry is a table together with its indexes (in creation order).
type Entry struct {
	Table   *storage.Table
	Indexes []*index.Index
}

// Snapshot is an immutable catalog version.
type Snapshot struct {
	tables  map[string]*Entry
	indexes map[string]*index.Index
}

// Get returns the table with the given name.
func (s *Snapshot) Get(name string) (*storage.Table, bool) {
	e, ok := s.tables[storage.FoldKey(name)]
	if !ok {
		return nil, false
	}
	return e.Table, true
}

// Entry returns the catalog entry of a table.
func (s *Snapshot) Entry(name string) (*Entry, bool) {
	e, ok := s.tables[storage.FoldKey(name)]
	return e, ok
}

// IndexesOf returns the indexes of exactly this table version.
func (s *Snapshot) IndexesOf(t *storage.Table) []*index.Index {
	e, ok := s.tables[storage.FoldKey(t.Name)]
	if !ok || e.Table != t {
		return nil
	}
	return e.Indexes
}

// Index returns an index by name.
func (s *Snapshot) Index(name string) (*index.Index, bool) {
	ix, ok := s.indexes[storage.FoldKey(name)]
	return ix, ok
}

// List returns all tables sorted case-insensitively by name.
func (s *Snapshot) List() []*storage.Table {
	out := make([]*storage.Table, 0, len(s.tables))
	for _, e := range s.tables {
		out = append(out, e.Table)
	}
	sort.Slice(out, func(i, j int) bool {
		a, b := storage.FoldKey(out[i].Name), storage.FoldKey(out[j].Name)
		if a != b {
			return a < b
		}
		return out[i].Name < out[j].Name
	})
	return out
}

// clone returns a mutable copy of the snapshot's maps.
func (s *Snapshot) clone() *Snapshot {
	c := &Snapshot{
		tables:  make(map[string]*Entry, len(s.tables)+1),
		indexes: make(map[string]*index.Index, len(s.indexes)+1),
	}
	for k, v := range s.tables {
		c.tables[k] = v
	}
	for k, v := range s.indexes {
		c.indexes[k] = v
	}
	return c
}

// removeTable deletes a table and its indexes from a mutable copy.
func (s *Snapshot) removeTable(key string) {
	if e, ok := s.tables[key]; ok {
		for _, ix := range e.Indexes {
			delete(s.indexes, storage.FoldKey(ix.Name))
		}
		delete(s.tables, key)
	}
}

// Catalog is the mutable catalog of an engine.
type Catalog struct {
	mu  sync.Mutex // serializes mutations
	cur atomic.Pointer[Snapshot]
}

// New creates an empty catalog.
func New() *Catalog {
	c := &Catalog{}
	c.cur.Store(&Snapshot{tables: map[string]*Entry{}, indexes: map[string]*index.Index{}})
	return c
}

// Snapshot returns the current catalog version.
func (c *Catalog) Snapshot() *Snapshot { return c.cur.Load() }

// Get returns a table of the current version.
func (c *Catalog) Get(name string) (*storage.Table, bool) { return c.Snapshot().Get(name) }

// Exists reports whether a table name is taken.
func (c *Catalog) Exists(name string) bool {
	_, ok := c.Get(name)
	return ok
}

// List returns the tables of the current version sorted by name.
func (c *Catalog) List() []*storage.Table { return c.Snapshot().List() }

// update applies fn to a copy of the current snapshot and publishes it if
// fn succeeds.
func (c *Catalog) update(fn func(s *Snapshot) error) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	next := c.cur.Load().clone()
	if err := fn(next); err != nil {
		return err
	}
	c.cur.Store(next)
	return nil
}

// Put publishes a table with prebuilt indexes. Without replace an existing
// table name is ALREADY_EXISTS. With replace the old table's indexes are
// dropped first; any index name still taken is ALREADY_EXISTS (and nothing
// changes).
func (c *Catalog) Put(t *storage.Table, indexes []*index.Index, replace bool) error {
	return c.update(func(s *Snapshot) error {
		key := storage.FoldKey(t.Name)
		if old, ok := s.tables[key]; ok {
			if !replace {
				return errs.New(errs.AlreadyExists, "table %q already exists", old.Table.Name)
			}
			s.removeTable(key)
		}
		for _, ix := range indexes {
			ik := storage.FoldKey(ix.Name)
			if _, taken := s.indexes[ik]; taken {
				return errs.New(errs.AlreadyExists, "index %q already exists", ix.Name)
			}
			s.indexes[ik] = ix
		}
		s.tables[key] = &Entry{Table: t, Indexes: append([]*index.Index(nil), indexes...)}
		return nil
	})
}

// Drop removes a table and its indexes; unknown names are NOT_FOUND.
func (c *Catalog) Drop(name string) error {
	return c.update(func(s *Snapshot) error {
		key := storage.FoldKey(name)
		if _, ok := s.tables[key]; !ok {
			return errs.New(errs.NotFound, "table %q not found", name)
		}
		s.removeTable(key)
		return nil
	})
}

// Reset removes all tables and indexes.
func (c *Catalog) Reset() {
	_ = c.update(func(s *Snapshot) error {
		s.tables = map[string]*Entry{}
		s.indexes = map[string]*index.Index{}
		return nil
	})
}

// CreateIndex builds and publishes an index (semantics.md §14). Unknown
// table or column ⇒ SEMANTIC_ERROR; an existing name ⇒ ALREADY_EXISTS unless
// ifNotExists (then nothing happens). The index is built while holding the
// mutation lock; concurrent readers are not blocked.
func (c *Catalog) CreateIndex(def index.Def, table string, ifNotExists bool) error {
	return c.update(func(s *Snapshot) error {
		e, ok := s.tables[storage.FoldKey(table)]
		if !ok {
			return errs.New(errs.SemanticError, "unknown table %q", table)
		}
		if e.Table.ColumnIndex(def.Column) < 0 {
			return errs.New(errs.SemanticError, "unknown column %q in table %q", def.Column, e.Table.Name)
		}
		ik := storage.FoldKey(def.Name)
		if _, taken := s.indexes[ik]; taken {
			if ifNotExists {
				return nil
			}
			return errs.New(errs.AlreadyExists, "index %q already exists", def.Name)
		}
		ix, err := index.Build(def, e.Table)
		if err != nil {
			return err
		}
		s.indexes[ik] = ix
		s.tables[storage.FoldKey(table)] = &Entry{Table: e.Table, Indexes: append(append([]*index.Index(nil), e.Indexes...), ix)}
		return nil
	})
}

// DropIndex removes an index; unknown ⇒ NOT_FOUND unless ifExists.
func (c *Catalog) DropIndex(name string, ifExists bool) error {
	return c.update(func(s *Snapshot) error {
		ik := storage.FoldKey(name)
		ix, ok := s.indexes[ik]
		if !ok {
			if ifExists {
				return nil
			}
			return errs.New(errs.NotFound, "index %q not found", name)
		}
		delete(s.indexes, ik)
		tk := storage.FoldKey(ix.Table.Name)
		if e, ok := s.tables[tk]; ok {
			var rest []*index.Index
			for _, other := range e.Indexes {
				if other != ix {
					rest = append(rest, other)
				}
			}
			s.tables[tk] = &Entry{Table: e.Table, Indexes: rest}
		}
		return nil
	})
}
