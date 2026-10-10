package protocol

import (
	"sort"
	"strconv"
	"unicode/utf8"

	"polyquery/internal/types"
)

// writer builds single-line JSON documents.
type writer struct {
	b        []byte
	first    []bool // per nesting level: no element written yet
	afterKey bool   // a key was just written; the next value needs no comma
}

func (w *writer) sep() {
	if w.afterKey {
		w.afterKey = false
		return
	}
	if n := len(w.first); n > 0 {
		if !w.first[n-1] {
			w.b = append(w.b, ',')
		}
		w.first[n-1] = false
	}
}

func (w *writer) beginObject() { w.sep(); w.b = append(w.b, '{'); w.first = append(w.first, true) }
func (w *writer) endObject()   { w.b = append(w.b, '}'); w.first = w.first[:len(w.first)-1] }
func (w *writer) beginArray()  { w.sep(); w.b = append(w.b, '['); w.first = append(w.first, true) }
func (w *writer) endArray()    { w.b = append(w.b, ']'); w.first = w.first[:len(w.first)-1] }

// key writes an object key; the next value call writes its value.
func (w *writer) key(k string) {
	w.sep()
	w.b = appendString(w.b, k)
	w.b = append(w.b, ':')
	w.afterKey = true
}

func (w *writer) str(s string) { w.sep(); w.b = appendString(w.b, s) }
func (w *writer) int(i int64)  { w.sep(); w.b = strconv.AppendInt(w.b, i, 10) }
func (w *writer) raw(r []byte) { w.sep(); w.b = append(w.b, r...) }
func (w *writer) null()        { w.sep(); w.b = append(w.b, "null"...) }
func (w *writer) bool(v bool)  { w.sep(); w.b = strconv.AppendBool(w.b, v) }
func (w *writer) float(f float64) {
	w.sep()
	w.b = types.AppendFloat(w.b, f)
}

// any writes simple Go values (used for error details).
func (w *writer) any(v any) {
	switch x := v.(type) {
	case nil:
		w.null()
	case string:
		w.str(x)
	case int:
		w.int(int64(x))
	case int64:
		w.int(x)
	case bool:
		w.bool(x)
	case float64:
		w.float(x)
	case map[string]any:
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		w.beginObject()
		for _, k := range keys {
			w.key(k)
			w.any(x[k])
		}
		w.endObject()
	default:
		w.str("?")
	}
}

// value writes a typed SQL value per types.md §9.
func (w *writer) value(v types.Value, t types.Type) {
	if v.Null {
		w.null()
		return
	}
	w.sep()
	switch t.Kind {
	case types.KindBoolean:
		w.b = strconv.AppendBool(w.b, v.I != 0)
	case types.KindInt64:
		w.b = strconv.AppendInt(w.b, v.I, 10)
	case types.KindFloat64:
		w.b = types.AppendFloat(w.b, v.F)
	case types.KindDecimal:
		w.b = append(w.b, '"')
		w.b = append(w.b, types.FormatDecimal(v.I, t.Scale)...)
		w.b = append(w.b, '"')
	case types.KindDate:
		w.b = append(w.b, '"')
		w.b = types.AppendDate(w.b, v.I)
		w.b = append(w.b, '"')
	case types.KindTimestamp:
		w.b = append(w.b, '"')
		w.b = types.AppendTimestamp(w.b, v.I)
		w.b = append(w.b, '"')
	case types.KindString:
		w.b = appendString(w.b, v.S)
	default:
		w.b = append(w.b, "null"...)
	}
}

const hexDigits = "0123456789abcdef"

// appendString appends a JSON string literal, escaping quotes, backslashes,
// control characters and invalid UTF-8 (as U+FFFD).
func appendString(b []byte, s string) []byte {
	b = append(b, '"')
	start := 0
	for i := 0; i < len(s); {
		c := s[i]
		if c >= 0x20 && c != '"' && c != '\\' && c < utf8.RuneSelf {
			i++
			continue
		}
		if c >= utf8.RuneSelf {
			r, size := utf8.DecodeRuneInString(s[i:])
			if r == utf8.RuneError && size == 1 {
				b = append(b, s[start:i]...)
				b = append(b, `�`...)
				i++
				start = i
				continue
			}
			i += size
			continue
		}
		b = append(b, s[start:i]...)
		switch c {
		case '"':
			b = append(b, '\\', '"')
		case '\\':
			b = append(b, '\\', '\\')
		case '\n':
			b = append(b, '\\', 'n')
		case '\r':
			b = append(b, '\\', 'r')
		case '\t':
			b = append(b, '\\', 't')
		default:
			b = append(b, '\\', 'u', '0', '0', hexDigits[c>>4], hexDigits[c&0xF])
		}
		i++
		start = i
	}
	b = append(b, s[start:]...)
	return append(b, '"')
}
