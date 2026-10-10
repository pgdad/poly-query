package pqcf

import (
	"encoding/binary"
	"hash/crc32"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"polyquery/internal/errs"
	"polyquery/internal/index"
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

const fixtures = "../../../../tests/conformance/fixtures/pqcf"

// sample builds a table exercising every type, NULLs, runs and repeated
// strings.
func sample(rows int) *storage.Table {
	cols := []storage.ColumnDef{
		{Name: "b", Type: types.Boolean}, {Name: "i", Type: types.Int64}, {Name: "f", Type: types.Float64},
		{Name: "d", Type: types.Decimal(10, 2)}, {Name: "s", Type: types.String},
		{Name: "dt", Type: types.Date}, {Name: "ts", Type: types.Timestamp},
	}
	vecs := make([]*storage.Vector, len(cols))
	for c, def := range cols {
		vecs[c] = storage.NewVector(def.Type, rows)
	}
	words := []string{"red", "", "grün", "blue"}
	for r := 0; r < rows; r++ {
		vals := []types.Value{
			types.BoolValue(r%3 == 0), types.IntValue(int64(r / 4)), types.FloatValue(float64(r) * 0.5),
			types.IntValue(int64(r*137%20000 - 10000)), types.StringValue(words[r%len(words)]),
			types.IntValue(types.MinDate + int64(r)), types.IntValue(int64(r) * 1_000_001),
		}
		for c := range cols {
			if (r+c)%5 == 0 {
				vals[c] = types.NullValue
			}
			vecs[c].Append(vals[c])
		}
	}
	return storage.Build("sample", &storage.Data{Columns: cols, Vectors: vecs, Rows: rows}, storage.BuildOptions{})
}

func rowsOf(t *testing.T, tb *storage.Table) []types.Row {
	t.Helper()
	var out []types.Row
	ords := make([]int, len(tb.Columns))
	for i := range ords {
		ords[i] = i
	}
	for _, g := range tb.Groups {
		r, err := g.Reader(ords)
		if err != nil {
			t.Fatal(err)
		}
		for i := 0; i < g.Rows; i++ {
			row := make(types.Row, len(ords))
			r.Read(i, row)
			out = append(out, row)
		}
	}
	return out
}

func readFile(t *testing.T, path string, opts ReadOptions) (*storage.Table, []index.Def, error) {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	return Read(f, "t", opts)
}

func TestRoundTrip(t *testing.T) {
	src := sample(1000)
	want := rowsOf(t, src)
	dir := t.TempDir()
	defs := []index.Def{{Name: "ix", Column: "i", Kind: index.BTree}}
	for _, enc := range []string{"auto", "plain", "dict", "rle"} {
		for _, rg := range []int{0, 1, 7, 64, 999} {
			path := filepath.Join(dir, "t.pqcf")
			size, err := Write(path, src, defs, WriteOptions{RowGroupSize: rg, Encoding: enc})
			if err != nil {
				t.Fatal(err)
			}
			if st, _ := os.Stat(path); st.Size() != size {
				t.Fatalf("reported size %d, file has %d", size, st.Size())
			}
			for _, opts := range []ReadOptions{{}, {Mmap: true}, {Layout: storage.RowLayout}, {Mmap: true, Dictionary: true}} {
				got, gotDefs, err := readFile(t, path, opts)
				if err != nil {
					t.Fatalf("%s/%d: %v", enc, rg, err)
				}
				if !reflect.DeepEqual(rowsOf(t, got), want) {
					t.Fatalf("%s/%d %+v: data differs", enc, rg, opts)
				}
				if !reflect.DeepEqual(gotDefs, defs) {
					t.Fatalf("index definitions %v", gotDefs)
				}
			}
		}
	}
	if m, _ := filepath.Glob(filepath.Join(dir, ".*tmp*")); len(m) != 0 {
		t.Fatalf("temporary files left behind: %v", m)
	}
}

func TestEmptyTable(t *testing.T) {
	path := filepath.Join(t.TempDir(), "e.pqcf")
	if _, err := Write(path, sample(0), nil, WriteOptions{}); err != nil {
		t.Fatal(err)
	}
	got, _, err := readFile(t, path, ReadOptions{})
	if err != nil || got.Rows != 0 || len(got.Columns) != 7 {
		t.Fatalf("got %v, %v", got, err)
	}
}

func TestGoldenFiles(t *testing.T) {
	want := map[string]int{"types_plain": 2000, "types_dict": 2000, "types_rle": 2000, "types_auto": 2000, "people": 8, "empty": 0, "forward_compat": 2}
	var ref []types.Row
	for name, rows := range want {
		for _, mmap := range []bool{false, true} {
			tb, _, err := readFile(t, filepath.Join(fixtures, name+".pqcf"), ReadOptions{Mmap: mmap})
			if err != nil {
				t.Fatalf("%s: %v", name, err)
			}
			if tb.Rows != rows {
				t.Fatalf("%s: %d rows", name, tb.Rows)
			}
			data := rowsOf(t, tb)
			if len(data) == 2000 {
				if ref == nil {
					ref = data
				} else if !reflect.DeepEqual(ref, data) {
					t.Fatalf("%s decodes differently from the other encodings", name)
				}
			}
		}
	}
}

func TestCorruptFixtures(t *testing.T) {
	cases := map[string]errs.Code{
		"bad_header_magic": errs.StorageCorrupt, "bad_trailer_magic": errs.StorageCorrupt,
		"bad_type": errs.StorageCorrupt, "chunk_bitflip": errs.StorageCorrupt,
		"chunk_out_of_bounds": errs.StorageCorrupt, "empty_file": errs.StorageCorrupt,
		"flags": errs.StorageVersion, "invalid_utf8": errs.StorageCorrupt,
		"meta_bitflip": errs.StorageCorrupt, "missing_chunk": errs.StorageCorrupt,
		"not_json_meta": errs.StorageCorrupt, "row_count_mismatch": errs.StorageCorrupt,
		"truncated_half": errs.StorageCorrupt, "truncated_tail": errs.StorageCorrupt,
		"unknown_encoding": errs.StorageVersion, "version2": errs.StorageVersion,
	}
	for name, code := range cases {
		_, _, err := readFile(t, filepath.Join(fixtures, "corrupt", name+".pqcf"), ReadOptions{})
		if !errs.Is(err, code) {
			t.Errorf("%s: got %v, want %s", name, err, code)
		}
	}
}

// TestBitFlips flips every bit of a small file: the reader must report an
// error, eagerly or (memory-mapped) when the data is read.
func TestBitFlips(t *testing.T) {
	dir := t.TempDir()
	src := sample(20)
	path := filepath.Join(dir, "s.pqcf")
	if _, err := Write(path, src, nil, WriteOptions{RowGroupSize: 8}); err != nil {
		t.Fatal(err)
	}
	orig, _ := os.ReadFile(path)
	bad := filepath.Join(dir, "bad.pqcf")
	for i := 0; i < len(orig)*8; i++ {
		data := append([]byte(nil), orig...)
		data[i/8] ^= 1 << uint(i%8)
		if err := os.WriteFile(bad, data, 0o644); err != nil {
			t.Fatal(err)
		}
		for _, mmap := range []bool{false, true} {
			tb, _, err := readFile(t, bad, ReadOptions{Mmap: mmap})
			if err == nil {
				err = fullScan(tb)
			}
			if err == nil {
				t.Fatalf("bit %d flipped (mmap=%v): no error", i, mmap)
			}
			if c := errs.From(err).Code; c != errs.StorageCorrupt && c != errs.StorageVersion {
				t.Fatalf("bit %d: unexpected error %v", i, err)
			}
		}
	}
	for n := 0; n < len(orig); n++ {
		if err := os.WriteFile(bad, orig[:n], 0o644); err != nil {
			t.Fatal(err)
		}
		if _, _, err := readFile(t, bad, ReadOptions{}); !errs.Is(err, errs.StorageCorrupt) {
			t.Fatalf("truncated to %d bytes: %v", n, err)
		}
	}
}

func fullScan(tb *storage.Table) error {
	for _, g := range tb.Groups {
		for c := range tb.Columns {
			if _, err := g.Reader([]int{c}); err != nil {
				return err
			}
		}
	}
	return nil
}

// TestValueValidation crafts files with valid checksums but invalid values.
func TestValueValidation(t *testing.T) {
	cases := []struct {
		typ   types.Type
		enc   string
		chunk []byte
		n     int
	}{
		{types.Decimal(3, 0), EncPlain, le64(1000), 1},
		{types.Date, EncPlain, le32(uint32(types.MaxDate + 1)), 1},
		{types.Float64, EncPlain, le64(0x7ff0000000000000), 1},
		{types.Boolean, EncRLE, append(le32(1), append(le64(2), le32(1)...)...), 1},
		{types.Int64, EncRLE, append(le32(1), append(le64(2), le32(2)...)...), 1},
		{types.String, EncPlain, append(append(le32(0), le32(1)...), 0xff), 1},
		{types.String, EncPlain, append(append(le32(0), le32(2)...), 'a'), 1},
		{types.String, EncDict, concat(le32(1), le32(0), le32(1), []byte("a"), le32(1)), 1},
		{types.Int64, EncPlain, append(le64(1), 0), 1},
	}
	for i, c := range cases {
		_, err := decodeChunk(c.chunk, c.typ, c.n, c.enc, 0)
		if !errs.Is(err, errs.StorageCorrupt) {
			t.Errorf("case %d: got %v", i, err)
		}
	}
}

func le32(v uint32) []byte { return binary.LittleEndian.AppendUint32(nil, v) }
func le64(v uint64) []byte { return binary.LittleEndian.AppendUint64(nil, v) }
func concat(parts ...[]byte) []byte {
	var out []byte
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

func TestCRC(t *testing.T) {
	if crc32.ChecksumIEEE([]byte("123456789")) != 0xCBF43926 {
		t.Fatal("CRC-32 check value mismatch")
	}
}
