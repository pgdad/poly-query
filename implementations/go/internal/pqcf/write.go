package pqcf

import (
	"bufio"
	"encoding/binary"
	"encoding/json"
	"hash/crc32"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"sync"

	"polyquery/internal/errs"
	"polyquery/internal/index"
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

// DefaultRowGroupSize is the number of rows per written row group.
const DefaultRowGroupSize = 65536

// WriteOptions control how a table is written.
type WriteOptions struct {
	RowGroupSize int    // rows per row group; 0 = DefaultRowGroupSize
	Encoding     string // "auto" (default), "plain", "dict" or "rle"
	Writer       string // value of the metadata "writer" key
}

// inFlight holds the temporary files of saves in progress in this process,
// which stale-file cleanup must not remove.
var inFlight sync.Map

// Write saves table t (with the given index definitions) to path as a PQCF
// file, atomically: the file is written to a temporary file in the same
// directory, synced, renamed over path, and the directory is synced. It
// returns the file size.
func Write(path string, t *storage.Table, indexes []index.Def, opts WriteOptions) (int64, error) {
	if opts.RowGroupSize <= 0 {
		opts.RowGroupSize = DefaultRowGroupSize
	}
	dir, base := filepath.Dir(path), filepath.Base(path)
	removeStale(dir, base)
	tmp, err := os.CreateTemp(dir, "."+base+".tmp-*")
	if err != nil {
		return 0, ioError("cannot create temporary file", err)
	}
	tmpName := tmp.Name()
	inFlight.Store(tmpName, true)
	defer inFlight.Delete(tmpName)
	_ = tmp.Chmod(0o644) // CreateTemp uses 0600; saved tables are ordinary files
	size, err := writeFile(tmp, t, indexes, opts)
	if err == nil {
		err = tmp.Sync()
		if err != nil {
			err = ioError("cannot sync file", err)
		}
	}
	if cerr := tmp.Close(); err == nil && cerr != nil {
		err = ioError("cannot close file", cerr)
	}
	if err == nil {
		if rerr := os.Rename(tmpName, path); rerr != nil {
			err = ioError("cannot replace target file", rerr)
		}
	}
	if err != nil {
		_ = os.Remove(tmpName)
		return 0, err
	}
	syncDir(dir)
	return size, nil
}

func ioError(what string, err error) error {
	return errs.New(errs.IOError, "%s: %v", what, err)
}

// removeStale deletes temporary files left behind by crashed saves to the
// same target.
func removeStale(dir, base string) {
	matches, _ := filepath.Glob(filepath.Join(dir, "."+escapeGlob(base)+".tmp-*"))
	for _, m := range matches {
		if _, busy := inFlight.Load(m); !busy {
			_ = os.Remove(m)
		}
	}
}

func escapeGlob(s string) string {
	out := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '*', '?', '[', '\\':
			out = append(out, '\\')
		}
		out = append(out, s[i])
	}
	return string(out)
}

// syncDir fsyncs a directory so that a rename in it is durable (best effort:
// not every platform supports syncing directories).
func syncDir(dir string) {
	d, err := os.Open(dir)
	if err != nil {
		return
	}
	_ = d.Sync()
	_ = d.Close()
}

type outMeta struct {
	FormatVersion int         `json:"format_version"`
	Writer        string      `json:"writer"`
	Table         string      `json:"table"`
	RowCount      int         `json:"row_count"`
	Columns       []outColumn `json:"columns"`
	Indexes       []outIndex  `json:"indexes"`
	RowGroups     []outGroup  `json:"row_groups"`
}

type outColumn struct {
	Name string `json:"name"`
	Type string `json:"type"`
}

type outIndex struct {
	Name   string `json:"name"`
	Column string `json:"column"`
	Kind   string `json:"kind"`
}

type outGroup struct {
	RowCount int        `json:"row_count"`
	Chunks   []outChunk `json:"chunks"`
}

type outChunk struct {
	Offset    int64           `json:"offset"`
	Length    int             `json:"length"`
	CRC32     uint32          `json:"crc32"`
	Encoding  string          `json:"encoding"`
	NullCount int             `json:"null_count"`
	Min       json.RawMessage `json:"min,omitempty"`
	Max       json.RawMessage `json:"max,omitempty"`
}

// writeFile writes the complete PQCF image of t to f and returns its size.
func writeFile(f *os.File, t *storage.Table, indexes []index.Def, opts WriteOptions) (int64, error) {
	w := bufio.NewWriterSize(f, 1<<20)
	var offset int64
	write := func(b []byte) error {
		n, err := w.Write(b)
		offset += int64(n)
		if err != nil {
			return ioError("cannot write file", err)
		}
		return nil
	}
	colTypes := make([]types.Type, len(t.Columns))
	for i, c := range t.Columns {
		colTypes[i] = c.Type
	}
	version := formatVersion(colTypes)
	header := []byte{'P', 'Q', 'C', 'F', byte(version), 0, 0, 0}
	if err := write(header); err != nil {
		return 0, err
	}
	meta := outMeta{
		FormatVersion: version, Writer: opts.Writer, Table: t.Name, RowCount: t.Rows,
		Columns: []outColumn{}, Indexes: []outIndex{}, RowGroups: []outGroup{},
	}
	for _, c := range t.Columns {
		meta.Columns = append(meta.Columns, outColumn{Name: c.Name, Type: c.Type.String()})
	}
	for _, ix := range indexes {
		meta.Indexes = append(meta.Indexes, outIndex{Name: ix.Name, Column: ix.Column, Kind: string(ix.Kind)})
	}
	vals := make([]types.Value, 0, min(opts.RowGroupSize, t.Rows))
	var padding [8]byte
	for start := 0; start < t.Rows; start += opts.RowGroupSize {
		end := min(start+opts.RowGroupSize, t.Rows)
		g := outGroup{RowCount: end - start}
		for ord, col := range t.Columns {
			var err error
			if vals, err = readRange(t, ord, start, end, vals[:0]); err != nil {
				return 0, err
			}
			chunk, oc := encodeChunk(vals, col.Type, opts.Encoding)
			if pad := (8 - offset%8) % 8; pad != 0 {
				if err := write(padding[:pad]); err != nil {
					return 0, err
				}
			}
			oc.Offset = offset
			if err := write(chunk); err != nil {
				return 0, err
			}
			g.Chunks = append(g.Chunks, oc)
		}
		meta.RowGroups = append(meta.RowGroups, g)
	}
	mb, err := json.Marshal(meta)
	if err != nil {
		return 0, errs.New(errs.InternalError, "cannot encode metadata: %v", err)
	}
	footer := make([]byte, footerSize)
	binary.LittleEndian.PutUint32(footer, uint32(len(mb)))
	binary.LittleEndian.PutUint32(footer[4:], crc32.ChecksumIEEE(mb))
	copy(footer[8:], Magic)
	if err := write(mb); err != nil {
		return 0, err
	}
	if err := write(footer); err != nil {
		return 0, err
	}
	if err := w.Flush(); err != nil {
		return 0, ioError("cannot write file", err)
	}
	return offset, nil
}

// readRange appends the values of column ord for rows [start, end) to dst.
func readRange(t *storage.Table, ord, start, end int, dst []types.Value) ([]types.Value, error) {
	for gi := t.GroupOf(start); gi < len(t.Groups) && start < end; gi++ {
		g := t.Groups[gi]
		r, err := g.Reader([]int{ord})
		if err != nil {
			return nil, err
		}
		stop := min(end, g.Start+g.Rows)
		for id := start; id < stop; id++ {
			dst = append(dst, r.Value(id-g.Start, 0))
		}
		start = stop
	}
	return dst, nil
}

// chooseEncoding picks the chunk encoding for the requested mode.
func chooseEncoding(vals []types.Value, t types.Type, mode string) string {
	switch mode {
	case "plain":
		return EncPlain
	case "dict":
		if t.Kind == types.KindString {
			return EncDict
		}
		return EncPlain
	case "rle":
		if rleCapable(t) {
			return EncRLE
		}
		return EncPlain
	}
	n := len(vals)
	switch {
	case t.Kind == types.KindString:
		seen := map[string]struct{}{}
		for _, v := range vals {
			if !v.Null {
				seen[v.S] = struct{}{}
				if len(seen) >= n/2 {
					return EncPlain
				}
			}
		}
		return EncDict
	case rleCapable(t):
		if len(runs(vals)) < n/4 {
			return EncRLE
		}
	}
	return EncPlain
}

// run is a run of equal int-class values; hi is the high word of wide
// DECIMALs (zero otherwise).
type run struct {
	value, hi int64
	length    uint32
}

// runs splits int-class values into runs; NULL slots extend the current run.
func runs(vals []types.Value) []run {
	var out []run
	for i, v := range vals {
		x := run{value: v.I, hi: v.Hi, length: 1}
		if v.Null {
			if i > 0 {
				x.value, x.hi = out[len(out)-1].value, out[len(out)-1].hi
			} else {
				x.value, x.hi = 0, 0
			}
		}
		if last := len(out) - 1; last >= 0 && out[last].value == x.value && out[last].hi == x.hi && out[last].length < math.MaxUint32 {
			out[len(out)-1].length++
		} else {
			out = append(out, x)
		}
	}
	return out
}

// encodeChunk encodes one column chunk and describes it (without offset).
func encodeChunk(vals []types.Value, t types.Type, mode string) ([]byte, outChunk) {
	n := len(vals)
	enc := chooseEncoding(vals, t, mode)
	oc := outChunk{Encoding: enc}
	var b []byte
	var lo, hi types.Value
	hasRange := false
	for _, v := range vals {
		if v.Null {
			oc.NullCount++
			continue
		}
		if !hasRange {
			lo, hi, hasRange = v, v, true
		} else {
			if types.Compare(t, v, t, lo) < 0 {
				lo = v
			}
			if types.Compare(t, v, t, hi) > 0 {
				hi = v
			}
		}
	}
	if oc.NullCount > 0 {
		bm := make([]byte, (n+7)/8)
		for i, v := range vals {
			if !v.Null {
				bm[i>>3] |= 1 << uint(i&7)
			}
		}
		b = append(b, bm...)
	}
	switch enc {
	case EncDict:
		b = appendDict(b, vals)
	case EncRLE:
		rs := runs(vals)
		b = binary.LittleEndian.AppendUint32(b, uint32(len(rs)))
		for _, r := range rs {
			b = binary.LittleEndian.AppendUint64(b, uint64(r.value))
			if t.IsWide() {
				b = binary.LittleEndian.AppendUint64(b, uint64(r.hi))
			}
			b = binary.LittleEndian.AppendUint32(b, r.length)
		}
	default:
		b = appendPlain(b, vals, t)
	}
	oc.Length = len(b)
	oc.CRC32 = crc32.ChecksumIEEE(b)
	if hasRange && t.Kind != types.KindString {
		oc.Min, oc.Max = jsonValue(lo, t), jsonValue(hi, t)
	}
	return b, oc
}

func appendPlain(b []byte, vals []types.Value, t types.Type) []byte {
	switch t.Kind {
	case types.KindBoolean:
		bm := make([]byte, (len(vals)+7)/8)
		for i, v := range vals {
			if !v.Null && v.I != 0 {
				bm[i>>3] |= 1 << uint(i&7)
			}
		}
		return append(b, bm...)
	case types.KindDate:
		for _, v := range vals {
			b = binary.LittleEndian.AppendUint32(b, uint32(int32(v.I)))
		}
		return b
	case types.KindFloat64:
		for _, v := range vals {
			b = binary.LittleEndian.AppendUint64(b, math.Float64bits(v.F))
		}
		return b
	case types.KindString:
		return appendStrings(b, vals)
	}
	for _, v := range vals {
		b = binary.LittleEndian.AppendUint64(b, uint64(v.I))
		if t.IsWide() {
			b = binary.LittleEndian.AppendUint64(b, uint64(v.Hi))
		}
	}
	return b
}

// appendStrings writes (n+1) offsets and the concatenated bytes; NULL slots
// have zero length.
func appendStrings(b []byte, vals []types.Value) []byte {
	var off uint32
	b = binary.LittleEndian.AppendUint32(b, 0)
	for _, v := range vals {
		off += uint32(len(v.S))
		b = binary.LittleEndian.AppendUint32(b, off)
	}
	for _, v := range vals {
		b = append(b, v.S...)
	}
	return b
}

func appendDict(b []byte, vals []types.Value) []byte {
	codes := make([]uint32, len(vals))
	ids := map[string]uint32{}
	var dict []types.Value
	for i, v := range vals {
		if v.Null {
			continue
		}
		c, ok := ids[v.S]
		if !ok {
			c = uint32(len(dict))
			ids[v.S] = c
			dict = append(dict, v)
		}
		codes[i] = c
	}
	b = binary.LittleEndian.AppendUint32(b, uint32(len(dict)))
	b = appendStrings(b, dict)
	for _, c := range codes {
		b = binary.LittleEndian.AppendUint32(b, c)
	}
	return b
}

// jsonValue serializes a non-NULL value per types.md §9.
func jsonValue(v types.Value, t types.Type) json.RawMessage {
	switch t.Kind {
	case types.KindBoolean:
		return json.RawMessage(strconv.FormatBool(v.I != 0))
	case types.KindInt64:
		return json.RawMessage(strconv.FormatInt(v.I, 10))
	case types.KindFloat64:
		return json.RawMessage(types.AppendFloat(nil, v.F))
	case types.KindDecimal:
		return json.RawMessage(strconv.Quote(types.FormatDecimalValue(v, t)))
	case types.KindDate:
		return json.RawMessage(strconv.Quote(types.FormatDate(v.I)))
	case types.KindTimestamp:
		return json.RawMessage(strconv.Quote(types.FormatTimestamp(v.I)))
	}
	return nil
}
