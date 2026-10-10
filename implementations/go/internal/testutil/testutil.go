// Package testutil provides a small fixture catalog for unit tests of the
// query pipeline.
package testutil

import (
	"testing"

	"polyquery/internal/ingest"
	"polyquery/internal/storage"
)

// Fixtures are CSV tables loaded by Catalog.
var Fixtures = map[string]string{
	"emp": `id,name,dept,salary,boss
1,Ann,eng,100,
2,Ben,eng,80,1
3,Cid,ops,70,1
4,Dee,ops,,3
5,Eva,,60,3
`,
	"dept": `code,title
eng,Engineering
ops,Operations
hr,Human Resources
`,
}

// Catalog returns a catalog holding the fixture tables.
func Catalog(t testing.TB) *storage.Catalog {
	t.Helper()
	cat := storage.NewCatalog()
	for name, data := range Fixtures {
		tab, err := ingest.Load(name, []byte(data), ingest.DefaultOptions(ingest.CSV))
		if err != nil {
			t.Fatalf("load %s: %v", name, err)
		}
		if err := cat.Put(tab, false); err != nil {
			t.Fatal(err)
		}
	}
	return cat
}
