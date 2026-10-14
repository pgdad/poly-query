// Command pq-embed-demo is the minimal embedding example
// (spec/apps/embedding.md §5): it loads a CSV file into an in-process
// PolyQuery instance, runs one SQL statement and prints the result as CSV.
//
//	pq-embed-demo DATA_DIR CSV_FILE SQL
//
// It uses only the public polyquery package and builds as a separate
// module (see go.mod: require + replace).
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"

	"polyquery"
)

func main() {
	if len(os.Args) != 4 {
		fmt.Fprintln(os.Stderr, "usage: pq-embed-demo DATA_DIR CSV_FILE SQL")
		os.Exit(2)
	}
	if err := run(os.Args[1], os.Args[2], os.Args[3]); err != nil {
		var pe *polyquery.Error
		if errors.As(err, &pe) {
			fmt.Fprintf(os.Stderr, "error: %s: %s\n", pe.Code, pe.Message)
		} else {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
		}
		os.Exit(1)
	}
}

func run(dataDir, csvFile, sql string) error {
	db, err := polyquery.New(polyquery.Config{DataDir: dataDir})
	if err != nil {
		return err
	}
	defer db.Close()
	if _, err := db.LoadFile("t", csvFile, nil); err != nil {
		return err
	}
	res, err := db.Query(context.Background(), sql, nil)
	if err != nil {
		return err
	}
	var b strings.Builder
	for i, c := range res.Columns {
		if i > 0 {
			b.WriteByte(',')
		}
		writeField(&b, c.Name)
	}
	b.WriteByte('\n')
	for _, row := range res.Rows {
		for i, v := range row {
			if i > 0 {
				b.WriteByte(',')
			}
			if v != nil {
				writeField(&b, text(v))
			}
		}
		b.WriteByte('\n')
	}
	_, err = os.Stdout.WriteString(b.String())
	return err
}

// text renders a non-NULL value as in pqledger's csv format
// (spec/apps/pqledger.md §7).
func text(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case int64:
		return strconv.FormatInt(x, 10)
	case bool:
		return strconv.FormatBool(x)
	case float64:
		s := strconv.FormatFloat(x, 'f', 6, 64)
		if s == "-0.000000" {
			s = "0.000000"
		}
		return s
	case fmt.Stringer: // polyquery.Decimal, Date, Timestamp
		return x.String()
	}
	return fmt.Sprint(v)
}

// writeField writes a CSV field, quoted when it is an empty string or
// contains a delimiter, quote, CR or LF, or starts or ends with a space.
func writeField(b *strings.Builder, s string) {
	if s == "" || strings.ContainsAny(s, ",\"\r\n") || strings.HasPrefix(s, " ") || strings.HasSuffix(s, " ") {
		b.WriteByte('"')
		b.WriteString(strings.ReplaceAll(s, `"`, `""`))
		b.WriteByte('"')
		return
	}
	b.WriteString(s)
}
