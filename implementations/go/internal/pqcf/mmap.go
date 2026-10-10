package pqcf

import (
	"runtime"

	"polyquery/internal/storage"
	"polyquery/internal/types"
)

// mapping is a file image backing lazily decoded chunks. A memory-mapped
// image is unmapped once no table references it any more (all its chunks
// have been decoded into copies, or the table was dropped).
type mapping struct {
	data    []byte
	unmap   func([]byte) error
	cleanup runtime.Cleanup
}

func newMapping(data []byte, unmap func([]byte) error) *mapping {
	m := &mapping{data: data, unmap: unmap}
	if unmap != nil {
		m.cleanup = runtime.AddCleanup(m, func(b []byte) { _ = unmap(b) }, data)
	}
	return m
}

// release unmaps the image immediately (open failed).
func (m *mapping) release() {
	if m.unmap != nil {
		m.cleanup.Stop()
		_ = m.unmap(m.data)
		m.unmap = nil
	}
}

// loader returns a function that verifies and decodes chunk c on demand.
func (m *mapping) loader(t types.Type, n int, c fileChunk, dict bool) func() (*storage.Vector, error) {
	return func() (*storage.Vector, error) {
		v, err := decodeFileChunk(m.data, t, n, c)
		if err != nil {
			return nil, err
		}
		if dict {
			v = v.DictEncode()
		}
		return v, nil
	}
}
