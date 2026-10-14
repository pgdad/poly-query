// Command pqledger is a personal-finance ledger for bank-statement CSV
// exports, built on the embedded PolyQuery engine (spec/apps/pqledger.md).
package main

import (
	"os"

	"polyquery/app/internal/cli"
)

func main() {
	os.Exit(cli.Main(os.Args[1:], os.Stdout, os.Stderr))
}
