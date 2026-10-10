//go:build !unix

package pqcf

import (
	"io"
	"os"

	"polyquery/internal/errs"
)

// mapFile falls back to reading the whole file on platforms without mmap
// support in the standard library; chunks are still decoded lazily.
func mapFile(f *os.File, size int) (*mapping, error) {
	data := make([]byte, size)
	if _, err := io.ReadFull(f, data); err != nil {
		return nil, errs.New(errs.IOError, "cannot read file: %v", err)
	}
	return newMapping(data, nil), nil
}
