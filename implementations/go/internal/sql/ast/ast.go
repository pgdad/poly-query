// Package ast defines the abstract syntax tree produced by the parser for the
// full PolyQuery SQL grammar (spec/sql/grammar.md). Semantic analysis decides
// which constructs a given phase supports.
package ast

// Pos is a 1-based source position.
type Pos struct{ Line, Col int }

// Position returns the node position.
func (p Pos) Position() Pos { return p }

// Node is any AST node.
type Node interface{ Position() Pos }

// Statement is a top-level SQL statement.
type Statement interface {
	Node
	stmt()
}

// Expr is a scalar expression.
type Expr interface {
	Node
	expr()
}

// FromItem is an element of a FROM clause.
type FromItem interface {
	Node
	from()
}

// ---------------------------------------------------------------- statements

// Query is a (possibly WITH-prefixed) SELECT with ORDER BY and LIMIT/OFFSET.
type Query struct {
	Pos
	With     []*CTE
	Distinct bool
	Items    []*SelectItem
	From     FromItem // nil if absent
	Where    Expr
	GroupBy  []Expr
	Having   Expr
	OrderBy  []*OrderItem
	Limit    Expr
	Offset   Expr
}

// CTE is one WITH entry.
type CTE struct {
	Pos
	Name    string
	Columns []string
	Query   *Query
}

// SelectItem is `*`, `r.*` or `expr [AS alias]`.
type SelectItem struct {
	Pos
	Star      bool
	Qualifier string // for r.*
	Expr      Expr
	Alias     string
	HasAlias  bool
}

// OrderItem is an ORDER BY key.
type OrderItem struct {
	Pos
	Expr       Expr
	Desc       bool
	NullsFirst *bool // nil = default
}

// Explain is `EXPLAIN query`.
type Explain struct {
	Pos
	Query *Query
}

// CreateIndex is `CREATE INDEX`.
type CreateIndex struct {
	Pos
	IfNotExists bool
	Name        string
	Table       string
	Column      string
	Using       string // "", "HASH" or "BTREE"
}

// DropIndex is `DROP INDEX`.
type DropIndex struct {
	Pos
	IfExists bool
	Name     string
}

func (*Query) stmt()       {}
func (*Explain) stmt()     {}
func (*CreateIndex) stmt() {}
func (*DropIndex) stmt()   {}

// ---------------------------------------------------------------- FROM

// TableRef names a base table or CTE.
type TableRef struct {
	Pos
	Name  string
	Alias string
}

// SubqueryRef is a derived table `(query) alias`.
type SubqueryRef struct {
	Pos
	Query *Query
	Alias string
}

// JoinType enumerates join kinds.
type JoinType uint8

// Join kinds.
const (
	JoinInner JoinType = iota
	JoinLeft
	JoinCross
)

// Join combines two FROM items.
type Join struct {
	Pos
	Type  JoinType
	Left  FromItem
	Right FromItem
	On    Expr
}

func (*TableRef) from()    {}
func (*SubqueryRef) from() {}
func (*Join) from()        {}

// ---------------------------------------------------------------- expressions

// LiteralKind enumerates literal kinds.
type LiteralKind uint8

// Literal kinds.
const (
	LitNumber LiteralKind = iota
	LitString
	LitBool
	LitNull
	LitDate
	LitTimestamp
)

// Literal is a constant as written in the SQL text.
type Literal struct {
	Pos
	Kind LiteralKind
	Text string // number text, string content, date/timestamp text
	Bool bool
}

// ColumnRef is `name` or `qualifier.name`.
type ColumnRef struct {
	Pos
	Qualifier string
	Name      string
}

// Unary is a prefix operator: "-", "+" or "NOT".
type Unary struct {
	Pos
	Op string
	X  Expr
}

// Binary is an infix operator: arithmetic, comparison, "||", "AND", "OR".
type Binary struct {
	Pos
	Op   string
	L, R Expr
}

// IsNull is `x IS [NOT] NULL`.
type IsNull struct {
	Pos
	X   Expr
	Not bool
}

// Between is `x [NOT] BETWEEN lo AND hi`.
type Between struct {
	Pos
	X, Lo, Hi Expr
	Not       bool
}

// InList is `x [NOT] IN (e1, …)`.
type InList struct {
	Pos
	X    Expr
	List []Expr
	Not  bool
}

// InSubquery is `x [NOT] IN (query)`.
type InSubquery struct {
	Pos
	X     Expr
	Query *Query
	Not   bool
}

// Like is `x [NOT] LIKE pattern`.
type Like struct {
	Pos
	X, Pattern Expr
	Not        bool
}

// FuncCall is `name(args)`, `name(*)` or `name(DISTINCT x)`.
type FuncCall struct {
	Pos
	Name     string
	Star     bool
	Distinct bool
	Args     []Expr
}

// TypeName is a type in CAST.
type TypeName struct {
	Pos
	Name   string
	Params []int
}

// Cast is `CAST(x AS type)`.
type Cast struct {
	Pos
	X    Expr
	Type *TypeName
}

// When is one CASE branch.
type When struct {
	Cond, Result Expr
}

// Case is a simple (Operand != nil) or searched CASE.
type Case struct {
	Pos
	Operand Expr
	Whens   []When
	Else    Expr
}

// Exists is `EXISTS (query)`.
type Exists struct {
	Pos
	Query *Query
}

// Subquery is a scalar subquery `(query)`.
type Subquery struct {
	Pos
	Query *Query
}

func (*Literal) expr()    {}
func (*ColumnRef) expr()  {}
func (*Unary) expr()      {}
func (*Binary) expr()     {}
func (*IsNull) expr()     {}
func (*Between) expr()    {}
func (*InList) expr()     {}
func (*InSubquery) expr() {}
func (*Like) expr()       {}
func (*FuncCall) expr()   {}
func (*Cast) expr()       {}
func (*Case) expr()       {}
func (*Exists) expr()     {}
func (*Subquery) expr()   {}
