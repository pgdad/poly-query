package storage

import (
	"sort"
	"sync"

	"polyquery/internal/errs"
)

// Catalog maps case-insensitive table names to immutable tables. Mutations are
// atomic; readers obtain table snapshots that remain valid after replacement.
type Catalog struct {
	mu     sync.RWMutex
	tables map[string]*Table
}

// NewCatalog creates an empty catalog.
func NewCatalog() *Catalog { return &Catalog{tables: map[string]*Table{}} }

// Get returns the table with the given name.
func (c *Catalog) Get(name string) (*Table, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	t, ok := c.tables[FoldKey(name)]
	return t, ok
}

// Put publishes a table. Without replace, an existing name is ALREADY_EXISTS.
func (c *Catalog) Put(t *Table, replace bool) error {
	key := FoldKey(t.Name)
	c.mu.Lock()
	defer c.mu.Unlock()
	if old, ok := c.tables[key]; ok && !replace {
		return errs.New(errs.AlreadyExists, "table %q already exists", old.Name)
	}
	c.tables[key] = t
	return nil
}

// Exists reports whether a table name is taken.
func (c *Catalog) Exists(name string) bool {
	_, ok := c.Get(name)
	return ok
}

// Drop removes a table; unknown names are NOT_FOUND.
func (c *Catalog) Drop(name string) error {
	key := FoldKey(name)
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, ok := c.tables[key]; !ok {
		return errs.New(errs.NotFound, "table %q not found", name)
	}
	delete(c.tables, key)
	return nil
}

// Reset removes all tables.
func (c *Catalog) Reset() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.tables = map[string]*Table{}
}

// List returns all tables sorted case-insensitively by name.
func (c *Catalog) List() []*Table {
	c.mu.RLock()
	out := make([]*Table, 0, len(c.tables))
	for _, t := range c.tables {
		out = append(out, t)
	}
	c.mu.RUnlock()
	sort.Slice(out, func(i, j int) bool {
		a, b := FoldKey(out[i].Name), FoldKey(out[j].Name)
		if a != b {
			return a < b
		}
		return out[i].Name < out[j].Name
	})
	return out
}
