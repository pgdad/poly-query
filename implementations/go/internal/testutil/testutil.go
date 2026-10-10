// Package testutil provides a small fixture catalog for unit tests of the
// query pipeline.
package testutil

import (
	"testing"

	"polyquery/internal/catalog"
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
func Catalog(t testing.TB) *catalog.Catalog {
	t.Helper()
	cat := catalog.New()
	for name, data := range Fixtures {
		d, err := ingest.Load([]byte(data), ingest.DefaultOptions(ingest.CSV))
		if err != nil {
			t.Fatalf("load %s: %v", name, err)
		}
		if err := cat.Put(storage.Build(name, d, storage.BuildOptions{}), nil, false); err != nil {
			t.Fatal(err)
		}
	}
	return cat
}
