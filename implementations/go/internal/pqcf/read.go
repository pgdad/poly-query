package pqcf

import (
	"cmp"
	"encoding/binary"
	"encoding/json"
	"hash/crc32"
	"io"
	"math"
	"os"
	"slices"
	"strconv"
	"strings"
	"unicode/utf8"

	"polyquery/internal/errs"
	"polyquery/internal/index"
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

// ReadOptions control how a file becomes an in-memory table.
type ReadOptions struct {
	// Mmap memory-maps the file and decodes column chunks lazily, verifying
	// each chunk's CRC on first access (column layout only). Otherwise the
	// file is read and fully verified and decoded at open.
	Mmap       bool
	Layout     storage.Layout
	Dictionary bool
	MaxRows    int64 // 0 = unlimited
}

// File is the validated structure of a PQCF file.
type File struct {
	Columns []storage.ColumnDef
	Indexes []index.Def
	Rows    int
	groups  []fileGroup
	data    []byte
}

type fileGroup struct {
	rows   int
	chunks []fileChunk
}

type fileChunk struct {
	offset, length int
	crc            uint32
	encoding       string
	nullCount      int
	stats          storage.ChunkStats
}

// Read opens the PQCF file f as a table called name and returns the table
// and the index definitions stored in the file.
func Read(f *os.File, name string, opts ReadOptions) (*storage.Table, []index.Def, error) {
	st, err := f.Stat()
	if err != nil {
		return nil, nil, errs.New(errs.IOError, "cannot stat file: %v", err)
	}
	size := st.Size()
	if size < headerSize+footerSize {
		return nil, nil, corrupt("file is too small (%d bytes)", size)
	}
	lazy := opts.Mmap && opts.Layout == storage.ColumnLayout
	var m *mapping
	var data []byte
	if lazy {
		if m, err = mapFile(f, int(size)); err != nil {
			return nil, nil, err
		}
		data = m.data
	} else {
		data = make([]byte, size)
		if _, err := io.ReadFull(f, data); err != nil {
			return nil, nil, errs.New(errs.IOError, "cannot read file: %v", err)
		}
	}
	pf, err := Parse(data, opts.MaxRows)
	if err == nil {
		var t *storage.Table
		if t, err = pf.table(name, opts, m); err == nil {
			return t, pf.Indexes, nil
		}
	}
	if m != nil {
		m.release()
	}
	return nil, nil, err
}

// Parse validates the header, footer, metadata checksum and metadata
// structure of a PQCF file image. Chunk contents are not examined.
func Parse(data []byte, maxRows int64) (*File, error) {
	size := len(data)
	if size < headerSize+footerSize {
		return nil, corrupt("file is too small (%d bytes)", size)
	}
	if string(data[:4]) != Magic {
		return nil, corrupt("bad header magic")
	}
	switch v := binary.LittleEndian.Uint16(data[4:6]); {
	case v == 0:
		return nil, corrupt("format version 0")
	case v > FormatVersion:
		return nil, unsupported("PQCF format version %d is not supported", v)
	}
	if flags := binary.LittleEndian.Uint16(data[6:8]); flags != 0 {
		return nil, unsupported("PQCF header flags %#x are not supported", flags)
	}
	if string(data[size-4:]) != Magic {
		return nil, corrupt("bad trailer magic")
	}
	metaLen := int64(binary.LittleEndian.Uint32(data[size-12:]))
	metaCRC := binary.LittleEndian.Uint32(data[size-8:])
	metaStart := int64(size) - footerSize - metaLen
	if metaStart < headerSize {
		return nil, corrupt("metadata length %d out of range", metaLen)
	}
	meta := data[metaStart : int64(size)-footerSize]
	if crc32.ChecksumIEEE(meta) != metaCRC {
		return nil, corrupt("metadata checksum mismatch")
	}
	if !utf8.Valid(meta) {
		return nil, corrupt("metadata is not valid UTF-8")
	}
	var md metadata
	if err := json.Unmarshal(meta, &md); err != nil {
		return nil, corrupt("invalid metadata JSON: %v", err)
	}
	pf := &File{data: data}
	if err := pf.load(&md, int(metaStart), maxRows); err != nil {
		return nil, err
	}
	return pf, nil
}

func (pf *File) load(md *metadata, dataEnd int, maxRows int64) error {
	if md.FormatVersion == nil || *md.FormatVersion != FormatVersion {
		return corrupt("format_version missing or different from the header")
	}
	if md.Table == nil || md.RowCount == nil || md.Columns == nil || md.RowGroups == nil {
		return corrupt("metadata lacks a required key")
	}
	if *md.RowCount < 0 {
		return corrupt("negative row_count")
	}
	if maxRows > 0 && *md.RowCount > maxRows {
		return errs.New(errs.ResourceLimit, "table has %d rows, more than the limit of %d", *md.RowCount, maxRows)
	}
	seen := map[string]bool{}
	for _, c := range *md.Columns {
		if c.Name == nil || *c.Name == "" || c.Type == nil {
			return corrupt("column without name or type")
		}
		key := storage.FoldKey(*c.Name)
		if seen[key] {
			return corrupt("duplicate column name %q", *c.Name)
		}
		seen[key] = true
		t, err := types.ParseTypeName(*c.Type)
		if err != nil {
			return corrupt("column %q has invalid type %q", *c.Name, *c.Type)
		}
		pf.Columns = append(pf.Columns, storage.ColumnDef{Name: *c.Name, Type: t})
	}
	ixNames := map[string]bool{}
	for _, ix := range md.Indexes {
		if ix.Name == nil || *ix.Name == "" || ix.Column == nil || ix.Kind == nil {
			return corrupt("index entry lacks name, column or kind")
		}
		kind := index.Kind(strings.ToUpper(*ix.Kind))
		if kind != index.Hash && kind != index.BTree {
			return corrupt("index %q has unknown kind %q", *ix.Name, *ix.Kind)
		}
		if !seen[storage.FoldKey(*ix.Column)] {
			return corrupt("index %q references unknown column %q", *ix.Name, *ix.Column)
		}
		if ixNames[storage.FoldKey(*ix.Name)] {
			return corrupt("duplicate index name %q", *ix.Name)
		}
		ixNames[storage.FoldKey(*ix.Name)] = true
		pf.Indexes = append(pf.Indexes, index.Def{Name: *ix.Name, Column: *ix.Column, Kind: kind})
	}
	var total int64
	for gi, g := range *md.RowGroups {
		if g.RowCount == nil || g.Chunks == nil {
			return corrupt("row group %d lacks row_count or chunks", gi)
		}
		n := *g.RowCount
		if n < 0 || n > *md.RowCount-total {
			return corrupt("row group %d has an invalid row_count", gi)
		}
		total += n
		if len(*g.Chunks) != len(pf.Columns) {
			return corrupt("row group %d has %d chunks for %d columns", gi, len(*g.Chunks), len(pf.Columns))
		}
		fg := fileGroup{rows: int(n)}
		for ci, c := range *g.Chunks {
			col := pf.Columns[ci]
			if c.Offset == nil || c.Length == nil || c.CRC32 == nil || c.Encoding == nil || c.NullCount == nil {
				return corrupt("chunk %d of row group %d lacks a required key", ci, gi)
			}
			off, length := *c.Offset, *c.Length
			if off < headerSize || length < 0 || off > int64(dataEnd) || length > int64(dataEnd)-off {
				return corrupt("chunk %d of row group %d is out of bounds", ci, gi)
			}
			if *c.NullCount < 0 || *c.NullCount > n {
				return corrupt("chunk %d of row group %d has an invalid null_count", ci, gi)
			}
			switch enc := *c.Encoding; enc {
			case EncPlain:
			case EncDict:
				if col.Type.Kind != types.KindString {
					return corrupt("DICT encoding on %s column %q", col.Type, col.Name)
				}
			case EncRLE:
				if !rleCapable(col.Type) {
					return corrupt("RLE encoding on %s column %q", col.Type, col.Name)
				}
			default:
				return unsupported("unknown chunk encoding %q", enc)
			}
			fc := fileChunk{offset: int(off), length: int(length), crc: *c.CRC32, encoding: *c.Encoding, nullCount: int(*c.NullCount)}
			fc.stats.NullCount = fc.nullCount
			lo, ok1 := statValue(c.Min, col.Type)
			hi, ok2 := statValue(c.Max, col.Type)
			if ok1 && ok2 && fc.nullCount < int(n) {
				fc.stats.HasRange, fc.stats.Min, fc.stats.Max = true, lo, hi
			}
			fg.chunks = append(fg.chunks, fc)
		}
		pf.groups = append(pf.groups, fg)
	}
	if total != *md.RowCount {
		return corrupt("row_count %d differs from the sum of row group sizes %d", *md.RowCount, total)
	}
	pf.Rows = int(total)
	return pf.checkPadding(dataEnd)
}

// checkPadding verifies that the bytes between the header and the metadata
// not covered by any chunk are zero (the format only allows zero padding).
// Chunk checksums do not cover them, so this detects damage there too.
func (pf *File) checkPadding(dataEnd int) error {
	type span struct{ from, to int }
	var spans []span
	for _, g := range pf.groups {
		for _, c := range g.chunks {
			spans = append(spans, span{c.offset, c.offset + c.length})
		}
	}
	slices.SortFunc(spans, func(a, b span) int { return cmp.Compare(a.from, b.from) })
	pos := headerSize
	check := func(to int) error {
		for ; pos < to; pos++ {
			if pf.data[pos] != 0 {
				return corrupt("non-zero byte at offset %d outside any chunk", pos)
			}
		}
		return nil
	}
	for _, sp := range spans {
		if err := check(sp.from); err != nil {
			return err
		}
		pos = max(pos, sp.to)
	}
	return check(dataEnd)
}

// statValue decodes a min/max statistic; malformed or absent statistics are
// treated as unknown (they only enable row-group skipping).
func statValue(raw json.RawMessage, t types.Type) (types.Value, bool) {
	if len(raw) == 0 || string(raw) == "null" {
		return types.Value{}, false
	}
	var s string
	isString := raw[0] == '"' && json.Unmarshal(raw, &s) == nil
	switch t.Kind {
	case types.KindBoolean:
		switch string(raw) {
		case "true":
			return types.BoolValue(true), true
		case "false":
			return types.BoolValue(false), true
		}
	case types.KindInt64:
		if i, err := strconv.ParseInt(string(raw), 10, 64); err == nil {
			return types.IntValue(i), true
		}
	case types.KindFloat64:
		if f, err := strconv.ParseFloat(string(raw), 64); err == nil && !isString && !math.IsInf(f, 0) {
			return types.FloatValue(f), true
		}
	case types.KindDecimal:
		if u, st := types.ParseDecimalExact(s, t.Precision, t.Scale); isString && st == types.TextOK {
			return types.IntValue(u), true
		}
	case types.KindString:
		if isString {
			return types.StringValue(s), true
		}
	case types.KindDate:
		if d, ok := types.ParseDate(s); isString && ok {
			return types.IntValue(d), true
		}
	case types.KindTimestamp:
		if ts, ok := types.ParseTimestamp(s); isString && ok {
			return types.IntValue(ts), true
		}
	}
	return types.Value{}, false
}

// table builds the in-memory table. With a mapping, chunks are decoded
// lazily from it; otherwise every chunk is verified and decoded now.
func (pf *File) table(name string, opts ReadOptions, m *mapping) (*storage.Table, error) {
	bo := storage.BuildOptions{Layout: opts.Layout, Dictionary: opts.Dictionary}
	groups := make([]*storage.RowGroup, 0, len(pf.groups))
	start := 0
	for _, g := range pf.groups {
		if m != nil {
			chunks := make([]*storage.Chunk, len(g.chunks))
			stats := make([]storage.ChunkStats, len(g.chunks))
			for ci, c := range g.chunks {
				stats[ci] = c.stats
				chunks[ci] = storage.LazyChunk(m.loader(pf.Columns[ci].Type, g.rows, c, opts.Dictionary))
			}
			groups = append(groups, storage.NewColumnGroup(start, g.rows, stats, chunks))
		} else {
			vecs := make([]*storage.Vector, len(g.chunks))
			stats := make([]storage.ChunkStats, len(g.chunks))
			for ci, c := range g.chunks {
				v, err := decodeFileChunk(pf.data, pf.Columns[ci].Type, g.rows, c)
				if err != nil {
					return nil, err
				}
				vecs[ci] = v
				stats[ci] = storage.ComputeStats(v)
			}
			groups = append(groups, storage.GroupFromVectors(start, g.rows, stats, vecs, bo))
		}
		start += g.rows
	}
	return storage.NewTable(name, pf.Columns, opts.Layout, groups), nil
}

// DecodeChunk verifies the checksum of chunk c in the file image and decodes
// its n values of type t.
func decodeFileChunk(data []byte, t types.Type, n int, c fileChunk) (*storage.Vector, error) {
	b := data[c.offset : c.offset+c.length]
	if crc32.ChecksumIEEE(b) != c.crc {
		return nil, corrupt("chunk checksum mismatch at offset %d", c.offset)
	}
	return decodeChunk(b, t, n, c.encoding, c.nullCount)
}

// decoder consumes a chunk's bytes.
type decoder struct {
	b   []byte
	pos int
}

func (d *decoder) take(n int) ([]byte, error) {
	if n < 0 || n > len(d.b)-d.pos {
		return nil, corrupt("chunk is truncated")
	}
	out := d.b[d.pos : d.pos+n]
	d.pos += n
	return out, nil
}

func (d *decoder) u32() (uint32, error) {
	b, err := d.take(4)
	if err != nil {
		return 0, err
	}
	return binary.LittleEndian.Uint32(b), nil
}

func (d *decoder) remaining() int { return len(d.b) - d.pos }

func decodeChunk(b []byte, t types.Type, n int, enc string, nullCount int) (*storage.Vector, error) {
	d := &decoder{b: b}
	var valid storage.Bitmap
	if nullCount > 0 {
		bm, err := d.take((n + 7) / 8)
		if err != nil {
			return nil, err
		}
		valid = storage.NewBitmap(n, false)
		nulls := 0
		for i := 0; i < n; i++ {
			if bm[i>>3]&(1<<uint(i&7)) != 0 {
				valid.Set(i)
			} else {
				nulls++
			}
		}
		if nulls != nullCount {
			return nil, corrupt("validity bitmap has %d NULLs, metadata says %d", nulls, nullCount)
		}
	}
	isNull := func(i int) bool { return valid != nil && !valid.Get(i) }
	var v *storage.Vector
	var err error
	switch enc {
	case EncPlain:
		v, err = decodePlain(d, t, n, valid, isNull)
	case EncDict:
		v, err = decodeDict(d, n, valid, isNull)
	case EncRLE:
		v, err = decodeRLE(d, t, n, valid, isNull)
	default:
		err = unsupported("unknown chunk encoding %q", enc)
	}
	if err != nil {
		return nil, err
	}
	if d.remaining() != 0 {
		return nil, corrupt("chunk has %d trailing bytes", d.remaining())
	}
	return v, nil
}

// checkInt validates a non-NULL int-class value of type t (types.md §1).
func checkInt(t types.Type, x int64) error {
	switch t.Kind {
	case types.KindBoolean:
		if x != 0 && x != 1 {
			return corrupt("BOOLEAN value %d", x)
		}
	case types.KindDecimal:
		if !types.FitsPrecision(x, t.Precision) {
			return corrupt("DECIMAL value exceeds precision %d", t.Precision)
		}
	case types.KindDate:
		if x < types.MinDate || x > types.MaxDate {
			return corrupt("DATE value out of range")
		}
	case types.KindTimestamp:
		if x < minTimestamp || x > maxTimestamp {
			return corrupt("TIMESTAMP value out of range")
		}
	}
	return nil
}

func decodePlain(d *decoder, t types.Type, n int, valid storage.Bitmap, isNull func(int) bool) (*storage.Vector, error) {
	switch t.Kind {
	case types.KindBoolean:
		bm, err := d.take((n + 7) / 8)
		if err != nil {
			return nil, err
		}
		vals := make([]int64, n)
		for i := range vals {
			if bm[i>>3]&(1<<uint(i&7)) != 0 && !isNull(i) {
				vals[i] = 1
			}
		}
		return storage.IntVector(t, vals, valid), nil
	case types.KindInt64, types.KindDecimal, types.KindTimestamp:
		if n > d.remaining()/8 {
			return nil, corrupt("chunk is truncated")
		}
		raw, _ := d.take(8 * n)
		vals := make([]int64, n)
		for i := range vals {
			vals[i] = int64(binary.LittleEndian.Uint64(raw[8*i:]))
			if !isNull(i) {
				if err := checkInt(t, vals[i]); err != nil {
					return nil, err
				}
			}
		}
		return storage.IntVector(t, vals, valid), nil
	case types.KindDate:
		if n > d.remaining()/4 {
			return nil, corrupt("chunk is truncated")
		}
		raw, _ := d.take(4 * n)
		vals := make([]int64, n)
		for i := range vals {
			vals[i] = int64(int32(binary.LittleEndian.Uint32(raw[4*i:])))
			if !isNull(i) {
				if err := checkInt(t, vals[i]); err != nil {
					return nil, err
				}
			}
		}
		return storage.IntVector(t, vals, valid), nil
	case types.KindFloat64:
		if n > d.remaining()/8 {
			return nil, corrupt("chunk is truncated")
		}
		raw, _ := d.take(8 * n)
		vals := make([]float64, n)
		for i := range vals {
			f := math.Float64frombits(binary.LittleEndian.Uint64(raw[8*i:]))
			if isNull(i) {
				f = 0
			} else if math.IsNaN(f) || math.IsInf(f, 0) {
				return nil, corrupt("non-finite FLOAT64 value")
			}
			vals[i] = f
		}
		return storage.FloatVector(vals, valid), nil
	case types.KindString:
		strs, err := decodeStrings(d, n, isNull)
		if err != nil {
			return nil, err
		}
		return storage.StringVector(strs, valid), nil
	}
	return nil, corrupt("unsupported column type %s", t)
}

// decodeStrings decodes (n+1) u32 offsets followed by the string bytes.
// Values for which skip(i) holds are not validated and decode as "".
func decodeStrings(d *decoder, n int, skip func(int) bool) ([]string, error) {
	if n >= d.remaining()/4 {
		return nil, corrupt("chunk is truncated")
	}
	raw, _ := d.take(4 * (n + 1))
	offs := make([]uint32, n+1)
	for i := range offs {
		offs[i] = binary.LittleEndian.Uint32(raw[4*i:])
		if i > 0 && offs[i] < offs[i-1] {
			return nil, corrupt("string offsets are decreasing")
		}
	}
	if offs[0] != 0 {
		return nil, corrupt("first string offset is not 0")
	}
	if int64(offs[n]) > int64(d.remaining()) {
		return nil, corrupt("string offsets out of range")
	}
	body, _ := d.take(int(offs[n]))
	all := string(body) // one allocation; values are substrings
	out := make([]string, n)
	for i := range out {
		if skip != nil && skip(i) {
			continue
		}
		s := all[offs[i]:offs[i+1]]
		if !utf8.ValidString(s) {
			return nil, corrupt("invalid UTF-8 in STRING value")
		}
		out[i] = s
	}
	return out, nil
}

func decodeDict(d *decoder, n int, valid storage.Bitmap, isNull func(int) bool) (*storage.Vector, error) {
	size, err := d.u32()
	if err != nil {
		return nil, err
	}
	if int64(size) >= int64(d.remaining()/4) {
		return nil, corrupt("dictionary size %d out of range", size)
	}
	dict, err := decodeStrings(d, int(size), nil)
	if err != nil {
		return nil, err
	}
	if n > d.remaining()/4 {
		return nil, corrupt("chunk is truncated")
	}
	raw, _ := d.take(4 * n)
	codes := make([]uint32, n)
	for i := range codes {
		c := binary.LittleEndian.Uint32(raw[4*i:])
		if isNull(i) {
			c = 0
		} else if c >= size {
			return nil, corrupt("dictionary code %d out of range", c)
		}
		codes[i] = c
	}
	if size == 0 {
		dict = []string{""} // all rows are NULL; keep code 0 addressable
	}
	return storage.DictVector(dict, codes, valid), nil
}

func decodeRLE(d *decoder, t types.Type, n int, valid storage.Bitmap, isNull func(int) bool) (*storage.Vector, error) {
	runs, err := d.u32()
	if err != nil {
		return nil, err
	}
	if int64(runs) > int64(d.remaining()/12) {
		return nil, corrupt("run count %d out of range", runs)
	}
	raw, _ := d.take(12 * int(runs))
	var total int64
	for r := 0; r < int(runs); r++ {
		l := binary.LittleEndian.Uint32(raw[12*r+8:])
		if l == 0 {
			return nil, corrupt("zero-length run")
		}
		total += int64(l)
	}
	if total != int64(n) {
		return nil, corrupt("runs cover %d rows, expected %d", total, n)
	}
	vals := make([]int64, n)
	pos := 0
	for r := 0; r < int(runs); r++ {
		x := int64(binary.LittleEndian.Uint64(raw[12*r:]))
		l := int(binary.LittleEndian.Uint32(raw[12*r+8:]))
		checked := false
		for i := pos; i < pos+l; i++ {
			if isNull(i) {
				continue
			}
			if !checked {
				if err := checkInt(t, x); err != nil {
					return nil, err
				}
				checked = true
			}
			vals[i] = x
		}
		pos += l
	}
	return storage.IntVector(t, vals, valid), nil
}
