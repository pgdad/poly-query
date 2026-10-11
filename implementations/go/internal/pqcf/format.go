// Package pqcf reads and writes PQCF, the PolyQuery columnar file format
// (spec/storage/pqcf-v1.md): an 8-byte header, column chunks (PLAIN, DICT or
// RLE encoded, each with an optional LSB-first validity bitmap and a CRC-32),
// a JSON metadata block and a 12-byte footer. Readers validate everything
// and report damage as STORAGE_CORRUPT; writers replace files atomically.
//
// Format version 2 (change request CR-2, spec/changes/decimal38.md §7) adds
// wide DECIMAL columns (precision 19–38) whose values are 128-bit
// two's-complement little-endian integers. Tables with a wide DECIMAL column
// are written as v2, all others as v1; both versions are read.
package pqcf

import (
	"encoding/json"
	"fmt"

	"polyquery/internal/errs"
	"polyquery/internal/types"
)

// Format constants.
const (
	Magic = "PQCF"
	// FormatV1 is the base format; FormatV2 adds 128-bit wide DECIMALs.
	FormatV1         = 1
	FormatV2         = 2
	maxFormatVersion = FormatV2
	headerSize       = 8
	footerSize       = 12
)

// Encodings.
const (
	EncPlain = "PLAIN"
	EncDict  = "DICT"
	EncRLE   = "RLE"
)

// Timestamp range of types.md §1 in microseconds.
const (
	minTimestamp = types.MinDate * types.MicrosPerDay
	maxTimestamp = (types.MaxDate+1)*types.MicrosPerDay - 1
)

func corrupt(format string, args ...any) error {
	return errs.New(errs.StorageCorrupt, "corrupt PQCF file: %s", fmt.Sprintf(format, args...))
}

func unsupported(format string, args ...any) error {
	return errs.New(errs.StorageVersion, format, args...)
}

// formatVersion is the version a table with the given columns is written
// as: v2 iff some column is a wide DECIMAL.
func formatVersion(cols []types.Type) int {
	for _, t := range cols {
		if t.IsWide() {
			return FormatV2
		}
	}
	return FormatV1
}

// rleCapable reports whether a type may be RLE-encoded.
func rleCapable(t types.Type) bool {
	switch t.Kind {
	case types.KindBoolean, types.KindInt64, types.KindDecimal, types.KindDate, types.KindTimestamp:
		return true
	}
	return false
}

// metadata mirrors the metadata JSON object. Pointer fields detect missing
// required keys; unknown keys are ignored.
type metadata struct {
	FormatVersion *int64        `json:"format_version"`
	Writer        string        `json:"writer,omitempty"`
	Table         *string       `json:"table"`
	RowCount      *int64        `json:"row_count"`
	Columns       *[]columnMeta `json:"columns"`
	Indexes       []indexMeta   `json:"indexes"`
	RowGroups     *[]groupMeta  `json:"row_groups"`
}

type columnMeta struct {
	Name *string `json:"name"`
	Type *string `json:"type"`
}

type indexMeta struct {
	Name   *string `json:"name"`
	Column *string `json:"column"`
	Kind   *string `json:"kind"`
}

type groupMeta struct {
	RowCount *int64       `json:"row_count"`
	Chunks   *[]chunkMeta `json:"chunks"`
}

type chunkMeta struct {
	Offset    *int64          `json:"offset"`
	Length    *int64          `json:"length"`
	CRC32     *uint32         `json:"crc32"`
	Encoding  *string         `json:"encoding"`
	NullCount *int64          `json:"null_count"`
	Min       json.RawMessage `json:"min,omitempty"`
	Max       json.RawMessage `json:"max,omitempty"`
}
