//go:build unix

package pqcf

import (
	"os"
	"syscall"

	"polyquery/internal/errs"
)

// mapFile memory-maps the whole file read-only.
func mapFile(f *os.File, size int) (*mapping, error) {
	data, err := syscall.Mmap(int(f.Fd()), 0, size, syscall.PROT_READ, syscall.MAP_SHARED)
	if err != nil {
		return nil, errs.New(errs.IOError, "cannot memory-map file: %v", err)
	}
	return newMapping(data, syscall.Munmap), nil
}
