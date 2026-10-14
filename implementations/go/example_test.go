package polyquery_test

import (
	"context"
	"fmt"
	"log"
	"os"

	"polyquery"
)

func Example() {
	dir, err := os.MkdirTemp("", "pq-example")
	if err != nil {
		log.Fatal(err)
	}
	defer os.RemoveAll(dir)

	db, err := polyquery.New(polyquery.Config{DataDir: dir})
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()

	csv := "day,amount\n2026-01-01,10.50\n2026-01-02,-3.25\n2026-01-02,0.75\n"
	schema := []polyquery.Column{
		{Name: "day", Type: polyquery.TypeDate},
		{Name: "amount", Type: polyquery.DecimalType(18, 2)},
	}
	if _, err := db.LoadText("t", csv, &polyquery.LoadOptions{Schema: schema}); err != nil {
		log.Fatal(err)
	}
	res, err := db.Query(context.Background(),
		"SELECT day, SUM(amount) AS total, COUNT(*) AS n FROM t GROUP BY day ORDER BY day", nil)
	if err != nil {
		log.Fatal(err)
	}
	for _, row := range res.Rows {
		day := row[0].(polyquery.Date)
		total := row[1].(polyquery.Decimal)
		n := row[2].(int64)
		fmt.Println(day, total, n)
	}

	_, err = db.Query(context.Background(), "SELECT nope FROM t", nil)
	fmt.Println(polyquery.ErrorCode(err))
	// Output:
	// 2026-01-01 10.50 1
	// 2026-01-02 -2.50 2
	// SEMANTIC_ERROR
}
