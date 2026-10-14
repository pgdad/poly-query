// Package polyquery embeds the PolyQuery analytical database engine in a Go
// program (spec/apps/embedding.md). Everything runs in-process: no
// process is started and no network connection is opened.
//
// An instance (DB) holds a catalog of in-memory tables. Tables are created
// by loading CSV/JSON (LoadFile, LoadText), by reading PQCF files
// (OpenTable), from Go values (CreateTable) or from a query result
// (CreateTableAs); SaveTable writes a table as a PQCF file. Query runs one
// SQL statement and returns a Result; QueryRows streams it.
//
//	db, err := polyquery.New(polyquery.Config{DataDir: "data"})
//	if err != nil { ... }
//	defer db.Close()
//	if _, err := db.LoadFile("t", "t.csv", nil); err != nil { ... }
//	res, err := db.Query(ctx, "SELECT day, COUNT(*) AS n FROM t GROUP BY day", nil)
//
// # Values
//
// Result values are typed Go values; NULL is nil for every type:
//
//	SQL type        Go type
//	BOOLEAN         bool
//	INT64           int64
//	FLOAT64         float64
//	DECIMAL(p,s)    Decimal (exact: unscaled integer and scale)
//	STRING          string
//	DATE            Date (days since 1970-01-01)
//	TIMESTAMP       Timestamp (microseconds since 1970-01-01 00:00:00)
//
// Column types are reported with their canonical names (Type.String),
// e.g. "DECIMAL(18,2)"; a column of the untyped NULL literal is STRING.
//
// # Errors
//
// Every operation returns errors of type *Error, which carries the
// specification's error code (Code, e.g. CodeParseError) and a message;
// use errors.As or ErrorCode. A failed operation leaves the instance
// usable and its catalog unchanged.
//
// # Concurrency
//
// A DB is safe for concurrent use: every statement reads an immutable
// snapshot of the catalog, and catalog changes are published atomically.
// A Rows cursor must be used by one goroutine at a time.
package polyquery
