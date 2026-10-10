// Package lexer turns SQL text into tokens (spec/sql/grammar.md §1).
package lexer

import (
	"strings"
	"unicode/utf8"

	"polyquery/internal/errs"
)

// Kind is a token kind.
type Kind uint8

// Token kinds.
const (
	EOF     Kind = iota
	Ident        // unquoted identifier (not a reserved keyword)
	QIdent       // double-quoted identifier
	Keyword      // reserved keyword; Text is upper case
	Number       // numeric literal; Text is the literal as written
	String       // string literal; Text is the unescaped content
	Op           // operator or punctuation; Text is the operator
)

func (k Kind) String() string {
	switch k {
	case EOF:
		return "end of input"
	case Ident, QIdent:
		return "identifier"
	case Keyword:
		return "keyword"
	case Number:
		return "number"
	case String:
		return "string"
	}
	return "operator"
}

// Token is a lexical token with its 1-based source position.
type Token struct {
	Kind Kind
	Text string
	Line int
	Col  int
}

// Is reports whether the token is the given keyword or operator.
func (t Token) Is(text string) bool {
	return (t.Kind == Keyword || t.Kind == Op) && t.Text == text
}

// Describe renders the token for error messages.
func (t Token) Describe() string {
	switch t.Kind {
	case EOF:
		return "end of input"
	case String:
		return "'" + t.Text + "'"
	case QIdent:
		return `"` + t.Text + `"`
	}
	return t.Text
}

var reserved = map[string]bool{}

func init() {
	for _, k := range strings.Fields(`ALL AND AS ASC BETWEEN BY CASE CAST CREATE CROSS DATE DESC DISTINCT DROP ELSE
  END EXISTS EXPLAIN FALSE FIRST FROM FULL GROUP HAVING IF IN INDEX INNER IS JOIN
  LAST LEFT LIKE LIMIT NOT NULL NULLS OFFSET ON OR ORDER OUTER RIGHT SELECT THEN
  TIMESTAMP TRUE UNION USING WHEN WHERE WITH`) {
		reserved[k] = true
	}
}

// IsReserved reports whether an (upper-case) word is a reserved keyword.
func IsReserved(upper string) bool { return reserved[upper] }

type lexer struct {
	src       string
	pos       int
	line, col int
}

// Tokenize splits SQL text into tokens, ending with an EOF token.
func Tokenize(src string) ([]Token, error) {
	lx := &lexer{src: src, line: 1, col: 1}
	var toks []Token
	for {
		t, err := lx.next()
		if err != nil {
			return nil, err
		}
		toks = append(toks, t)
		if t.Kind == EOF {
			return toks, nil
		}
	}
}

func (lx *lexer) advance(n int) {
	for i := 0; i < n && lx.pos < len(lx.src); i++ {
		c := lx.src[lx.pos]
		lx.pos++
		if c == '\n' {
			lx.line++
			lx.col = 1
		} else if c < 0x80 || c >= 0xC0 {
			lx.col++ // count code points, not continuation bytes
		}
	}
}

func (lx *lexer) peek(off int) byte {
	if lx.pos+off < len(lx.src) {
		return lx.src[lx.pos+off]
	}
	return 0
}

func (lx *lexer) errAt(line, col int, format string, args ...any) error {
	return errs.At(errs.ParseError, line, col, format, args...)
}

func isIdentStart(c byte) bool { return c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' }
func isDigit(c byte) bool      { return c >= '0' && c <= '9' }

func (lx *lexer) skipSpaceAndComments() error {
	for lx.pos < len(lx.src) {
		c := lx.src[lx.pos]
		switch {
		case c == ' ' || c == '\t' || c == '\r' || c == '\n':
			lx.advance(1)
		case c == '-' && lx.peek(1) == '-':
			for lx.pos < len(lx.src) && lx.src[lx.pos] != '\n' {
				lx.advance(1)
			}
		case c == '/' && lx.peek(1) == '*':
			line, col := lx.line, lx.col
			end := strings.Index(lx.src[lx.pos+2:], "*/")
			if end < 0 {
				return lx.errAt(line, col, "unterminated block comment")
			}
			lx.advance(end + 4)
		default:
			return nil
		}
	}
	return nil
}

func (lx *lexer) next() (Token, error) {
	if err := lx.skipSpaceAndComments(); err != nil {
		return Token{}, err
	}
	line, col := lx.line, lx.col
	tok := func(k Kind, text string) Token { return Token{Kind: k, Text: text, Line: line, Col: col} }
	if lx.pos >= len(lx.src) {
		return tok(EOF, ""), nil
	}
	c := lx.src[lx.pos]
	switch {
	case isIdentStart(c):
		start := lx.pos
		for lx.pos < len(lx.src) && (isIdentStart(lx.src[lx.pos]) || isDigit(lx.src[lx.pos])) {
			lx.advance(1)
		}
		word := lx.src[start:lx.pos]
		if upper := strings.ToUpper(word); reserved[upper] {
			return tok(Keyword, upper), nil
		}
		return tok(Ident, word), nil
	case isDigit(c) || (c == '.' && isDigit(lx.peek(1))):
		return lx.number(line, col)
	case c == '\'':
		s, err := lx.quoted('\'', line, col, "string literal")
		if err != nil {
			return Token{}, err
		}
		return tok(String, s), nil
	case c == '"':
		s, err := lx.quoted('"', line, col, "quoted identifier")
		if err != nil {
			return Token{}, err
		}
		return tok(QIdent, s), nil
	}
	two := ""
	if lx.pos+1 < len(lx.src) {
		two = lx.src[lx.pos : lx.pos+2]
	}
	switch two {
	case "<>", "!=", "<=", ">=", "||":
		lx.advance(2)
		return tok(Op, two), nil
	}
	switch c {
	case '+', '-', '*', '/', '%', '=', '<', '>', '(', ')', ',', '.', ';':
		lx.advance(1)
		return tok(Op, string(c)), nil
	}
	r, _ := utf8.DecodeRuneInString(lx.src[lx.pos:])
	return Token{}, lx.errAt(line, col, "unexpected character %q", r)
}

func (lx *lexer) number(line, col int) (Token, error) {
	start := lx.pos
	for isDigit(lx.peek(0)) {
		lx.advance(1)
	}
	if lx.peek(0) == '.' {
		lx.advance(1)
		for isDigit(lx.peek(0)) {
			lx.advance(1)
		}
	}
	if c := lx.peek(0); c == 'e' || c == 'E' {
		off := 1
		if s := lx.peek(1); s == '+' || s == '-' {
			off = 2
		}
		if isDigit(lx.peek(off)) {
			lx.advance(off)
			for isDigit(lx.peek(0)) {
				lx.advance(1)
			}
		}
	}
	if c := lx.peek(0); isIdentStart(c) || isDigit(c) || c == '.' {
		return Token{}, lx.errAt(lx.line, lx.col, "invalid numeric literal")
	}
	return Token{Kind: Number, Text: lx.src[start:lx.pos], Line: line, Col: col}, nil
}

func (lx *lexer) quoted(q byte, line, col int, what string) (string, error) {
	lx.advance(1)
	var sb strings.Builder
	for {
		i := strings.IndexByte(lx.src[lx.pos:], q)
		if i < 0 {
			return "", lx.errAt(line, col, "unterminated %s", what)
		}
		sb.WriteString(lx.src[lx.pos : lx.pos+i])
		lx.advance(i + 1)
		if lx.peek(0) == q {
			sb.WriteByte(q)
			lx.advance(1)
			continue
		}
		return sb.String(), nil
	}
}
