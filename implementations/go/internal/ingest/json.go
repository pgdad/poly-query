package ingest

import (
	"strings"
	"unicode/utf16"
	"unicode/utf8"

	"polyquery/internal/errs"
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

// JSON scalar kinds.
const (
	jNull uint8 = iota
	jBool
	jNumber
	jString
)

type jsonValue struct {
	kind uint8
	text string // number literal, string content, or "true"/"false"
}

type jsonColumn struct {
	name   string
	values []jsonValue
	setAt  int // last row index that assigned this column (duplicate detection)
}

type jsonLoader struct {
	cols  []*jsonColumn
	index map[string]int
	rows  int
	opts  Options
}

// jsonParser is a strict RFC 8259 parser for arrays/lines of flat objects.
type jsonParser struct {
	s    string
	pos  int
	line int // base line number for messages (JSONL)
}

func (p *jsonParser) fail(format string, args ...any) error {
	e := errs.New(errs.IngestError, format, args...)
	if p.line > 0 {
		e.Message += " (line " + itoa(p.line) + ")"
		e = e.With("record", p.line)
	}
	return e
}

func (p *jsonParser) ws() {
	for p.pos < len(p.s) {
		switch p.s[p.pos] {
		case ' ', '\t', '\n', '\r':
			p.pos++
		default:
			return
		}
	}
}

func (p *jsonParser) peek() byte {
	if p.pos < len(p.s) {
		return p.s[p.pos]
	}
	return 0
}

func loadJSON(s string, opts Options) (*storage.Data, error) {
	ld := &jsonLoader{index: map[string]int{}, opts: opts}
	if opts.Format == JSON {
		p := &jsonParser{s: s}
		p.ws()
		if p.peek() != '[' {
			return nil, p.fail("JSON input must be an array of objects")
		}
		p.pos++
		p.ws()
		if p.peek() == ']' {
			p.pos++
		} else {
			for {
				p.ws()
				if p.peek() != '{' {
					return nil, p.fail("array element %d is not an object", ld.rows+1)
				}
				if err := ld.object(p); err != nil {
					return nil, err
				}
				p.ws()
				c := p.peek()
				p.pos++
				if c == ']' {
					break
				}
				if c != ',' {
					return nil, p.fail("expected ',' or ']' in array")
				}
			}
		}
		p.ws()
		if p.pos != len(p.s) {
			return nil, p.fail("unexpected content after JSON array")
		}
	} else {
		lineNo := 0
		for len(s) > 0 {
			lineNo++
			var line string
			if i := strings.IndexByte(s, '\n'); i >= 0 {
				line, s = s[:i], s[i+1:]
			} else {
				line, s = s, ""
			}
			p := &jsonParser{s: line, line: lineNo}
			p.ws()
			if p.pos == len(line) {
				continue
			}
			if p.peek() != '{' {
				return nil, p.fail("JSON Lines record is not an object")
			}
			if err := ld.object(p); err != nil {
				return nil, err
			}
			p.ws()
			if p.pos != len(line) {
				return nil, p.fail("unexpected content after JSON object")
			}
		}
	}
	return ld.build()
}

// object parses one flat object into a new row.
func (ld *jsonLoader) object(p *jsonParser) error {
	row := ld.rows
	ld.rows++
	if err := checkRows(ld.rows, ld.opts); err != nil {
		return err
	}
	p.pos++ // {
	p.ws()
	if p.peek() == '}' {
		p.pos++
		ld.padRow()
		return nil
	}
	for {
		p.ws()
		if p.peek() != '"' {
			return p.fail("expected object key")
		}
		key, err := p.str()
		if err != nil {
			return err
		}
		p.ws()
		if p.peek() != ':' {
			return p.fail("expected ':' after object key")
		}
		p.pos++
		p.ws()
		val, err := p.scalar()
		if err != nil {
			return err
		}
		if err := ld.set(p, row, key, val); err != nil {
			return err
		}
		p.ws()
		c := p.peek()
		p.pos++
		if c == '}' {
			break
		}
		if c != ',' {
			return p.fail("expected ',' or '}' in object")
		}
	}
	ld.padRow()
	return nil
}

func (ld *jsonLoader) set(p *jsonParser, row int, key string, val jsonValue) error {
	idx, ok := ld.index[key]
	if !ok {
		if key == "" {
			return p.fail("empty column name")
		}
		idx = len(ld.cols)
		ld.index[key] = idx
		ld.cols = append(ld.cols, &jsonColumn{name: key, values: make([]jsonValue, row, row+1), setAt: -1})
	}
	c := ld.cols[idx]
	if c.setAt == row {
		return p.fail("duplicate key %q in object", key)
	}
	c.setAt = row
	c.values = append(c.values, val)
	return nil
}

// padRow appends NULL to every column not set in the current row.
func (ld *jsonLoader) padRow() {
	for _, c := range ld.cols {
		if len(c.values) < ld.rows {
			c.values = append(c.values, jsonValue{kind: jNull})
		}
	}
}

func (p *jsonParser) scalar() (jsonValue, error) {
	switch c := p.peek(); {
	case c == '"':
		s, err := p.str()
		return jsonValue{kind: jString, text: s}, err
	case c == '{' || c == '[':
		return jsonValue{}, p.fail("nested objects and arrays are not supported")
	case c == '-' || (c >= '0' && c <= '9'):
		return p.number()
	case strings.HasPrefix(p.s[p.pos:], "true"):
		p.pos += 4
		return jsonValue{kind: jBool, text: "true"}, nil
	case strings.HasPrefix(p.s[p.pos:], "false"):
		p.pos += 5
		return jsonValue{kind: jBool, text: "false"}, nil
	case strings.HasPrefix(p.s[p.pos:], "null"):
		p.pos += 4
		return jsonValue{kind: jNull}, nil
	}
	return jsonValue{}, p.fail("invalid JSON value")
}

func (p *jsonParser) digits() int {
	n := 0
	for p.pos < len(p.s) && p.s[p.pos] >= '0' && p.s[p.pos] <= '9' {
		p.pos++
		n++
	}
	return n
}

func (p *jsonParser) number() (jsonValue, error) {
	start := p.pos
	if p.peek() == '-' {
		p.pos++
	}
	if p.peek() == '0' {
		p.pos++
	} else if p.digits() == 0 {
		return jsonValue{}, p.fail("invalid number")
	}
	if p.peek() == '.' {
		p.pos++
		if p.digits() == 0 {
			return jsonValue{}, p.fail("invalid number")
		}
	}
	if c := p.peek(); c == 'e' || c == 'E' {
		p.pos++
		if c := p.peek(); c == '+' || c == '-' {
			p.pos++
		}
		if p.digits() == 0 {
			return jsonValue{}, p.fail("invalid number")
		}
	}
	return jsonValue{kind: jNumber, text: p.s[start:p.pos]}, nil
}

func hexVal(s string) (rune, bool) {
	if len(s) < 4 {
		return 0, false
	}
	var r rune
	for i := 0; i < 4; i++ {
		c := s[i]
		switch {
		case c >= '0' && c <= '9':
			r = r*16 + rune(c-'0')
		case c >= 'a' && c <= 'f':
			r = r*16 + rune(c-'a'+10)
		case c >= 'A' && c <= 'F':
			r = r*16 + rune(c-'A'+10)
		default:
			return 0, false
		}
	}
	return r, true
}

func (p *jsonParser) str() (string, error) {
	p.pos++ // opening quote
	start := p.pos
	// Fast path: no escapes.
	for p.pos < len(p.s) {
		c := p.s[p.pos]
		if c == '"' {
			p.pos++
			return p.s[start : p.pos-1], nil
		}
		if c == '\\' {
			break
		}
		if c < 0x20 {
			return "", p.fail("control character in string")
		}
		p.pos++
	}
	var sb strings.Builder
	sb.WriteString(p.s[start:p.pos])
	for p.pos < len(p.s) {
		c := p.s[p.pos]
		switch {
		case c == '"':
			p.pos++
			return sb.String(), nil
		case c < 0x20:
			return "", p.fail("control character in string")
		case c != '\\':
			sb.WriteByte(c)
			p.pos++
			continue
		}
		if p.pos+1 >= len(p.s) {
			break
		}
		e := p.s[p.pos+1]
		p.pos += 2
		switch e {
		case '"', '\\', '/':
			sb.WriteByte(e)
		case 'b':
			sb.WriteByte('\b')
		case 'f':
			sb.WriteByte('\f')
		case 'n':
			sb.WriteByte('\n')
		case 'r':
			sb.WriteByte('\r')
		case 't':
			sb.WriteByte('\t')
		case 'u':
			r, ok := hexVal(p.s[p.pos:])
			if !ok {
				return "", p.fail("invalid \\u escape")
			}
			p.pos += 4
			if utf16.IsSurrogate(r) {
				var r2 rune
				if strings.HasPrefix(p.s[p.pos:], `\u`) {
					r2, ok = hexVal(p.s[p.pos+2:])
				} else {
					ok = false
				}
				dec := utf16.DecodeRune(r, r2)
				if !ok || dec == utf8.RuneError {
					return "", p.fail("invalid surrogate pair in string")
				}
				p.pos += 6
				r = dec
			}
			sb.WriteRune(r)
		default:
			return "", p.fail("invalid escape sequence")
		}
	}
	return "", p.fail("unterminated string")
}

func (ld *jsonLoader) build() (*storage.Data, error) {
	t := &storage.Data{Rows: ld.rows}
	if ld.opts.Schema != nil {
		byName := map[string]*jsonColumn{}
		for _, c := range ld.cols {
			if idx := schemaIndex(ld.opts.Schema, c.name); idx < 0 {
				return nil, errs.New(errs.IngestError, "key %q is not in the schema", c.name)
			} else if prev := byName[storage.FoldKey(c.name)]; prev != nil {
				return nil, errs.New(errs.IngestError, "duplicate column name %q", c.name)
			}
			byName[storage.FoldKey(c.name)] = c
		}
		for _, def := range ld.opts.Schema {
			c := byName[storage.FoldKey(def.Name)]
			vec, err := convertJSONColumn(c, def, ld.rows)
			if err != nil {
				return nil, err
			}
			t.Columns = append(t.Columns, def)
			t.Vectors = append(t.Vectors, vec)
		}
		return t, nil
	}
	defs := make([]storage.ColumnDef, len(ld.cols))
	for i, c := range ld.cols {
		defs[i].Name = c.name
	}
	if err := checkColumnNames(defs); err != nil {
		return nil, err
	}
	for i, c := range ld.cols {
		typ, err := inferJSON(c)
		if err != nil {
			return nil, err
		}
		defs[i].Type = typ
		vec, err := convertJSONColumn(c, defs[i], ld.rows)
		if err != nil {
			// Inferred types always convert; a failure is malformed input.
			return nil, errs.New(errs.IngestError, "%s", errs.From(err).Message)
		}
		t.Columns = append(t.Columns, defs[i])
		t.Vectors = append(t.Vectors, vec)
	}
	return t, nil
}

func schemaIndex(schema []storage.ColumnDef, name string) int {
	for i, c := range schema {
		if storage.EqualFold(c.Name, name) {
			return i
		}
	}
	return -1
}

func inferJSON(c *jsonColumn) (types.Type, error) {
	var kinds [4]bool
	allInt, allDate, allTemporal := true, true, true
	for _, v := range c.values {
		kinds[v.kind] = true
		switch v.kind {
		case jNumber:
			if allInt {
				if strings.ContainsAny(v.text, ".eE") {
					allInt = false
				} else if _, st := types.ParseIntText(v.text); st != types.TextOK {
					allInt = false
				}
			}
		case jString:
			if allTemporal {
				if _, ok := types.ParseDate(v.text); !ok {
					allDate = false
					if _, ok := types.ParseTimestamp(v.text); !ok {
						allTemporal = false
					}
				}
			}
		}
	}
	n := 0
	for _, k := range kinds[1:] {
		if k {
			n++
		}
	}
	switch {
	case n == 0:
		return types.String, nil
	case n > 1:
		return types.Type{}, errs.New(errs.IngestError, "column %q mixes JSON value types", c.name)
	case kinds[jBool]:
		return types.Boolean, nil
	case kinds[jNumber]:
		if allInt {
			return types.Int64, nil
		}
		return types.Float64, nil
	}
	switch {
	case allTemporal && allDate:
		return types.Date, nil
	case allTemporal:
		return types.Timestamp, nil
	}
	return types.String, nil
}

func convertJSONColumn(c *jsonColumn, def storage.ColumnDef, rows int) (*storage.Vector, error) {
	typ := def.Type
	vec := storage.NewVector(typ, rows)
	for i := 0; i < rows; i++ {
		var v jsonValue
		if c != nil {
			v = c.values[i]
		}
		if v.kind == jNull {
			vec.Append(types.NullValue)
			continue
		}
		var (
			val types.Value
			ok  bool
		)
		switch v.kind {
		case jBool:
			if typ.Kind == types.KindBoolean {
				val, ok = types.BoolValue(v.text == "true"), true
			}
		case jNumber:
			switch typ.Kind {
			case types.KindInt64, types.KindFloat64, types.KindDecimal:
				val, ok = convertText(v.text, typ)
			}
		case jString:
			switch typ.Kind {
			case types.KindString:
				val, ok = types.StringValue(v.text), true
			case types.KindBoolean:
			default:
				t := types.TrimSpaceTab(v.text)
				val, ok = convertText(t, typ)
			}
		}
		if !ok {
			return nil, conversionError(i+1, def.Name, "cannot convert JSON value %q to %s", v.text, typ)
		}
		vec.Append(val)
	}
	return vec, nil
}
