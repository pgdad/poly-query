package plan

import (
	"testing"

	"polyquery/internal/storage"
	"polyquery/internal/types"
)

func TestFormat(t *testing.T) {
	tbl := &storage.Table{Name: "t"}
	id := Column{ID: 1, Name: "id", Type: types.Int64}
	n := Column{ID: 2, Name: "n", Type: types.Int64}
	scan := &Scan{Table: tbl, Ords: []int{0}, Cols: []Column{id}}
	sub := &Subquery{Kind: SubExists, Seq: 1, T: types.Boolean, Correlated: []Column{id},
		Plan: &Filter{Input: &Scan{Table: tbl, Ords: []int{1}, Cols: []Column{n}},
			Pred: &Binary{Op: OpEq, L: n.Ref(), R: id.Ref(), T: types.Boolean}}}
	root := &Limit{
		Count: &Literal{Val: types.IntValue(3), T: types.Int64},
		Input: &Sort{
			Keys:  []SortKey{{Expr: id.Ref(), Desc: true}},
			Input: &Filter{Input: scan, Pred: sub},
		},
	}
	want := `Limit count=3
  Sort [#1:id DESC]
    Filter EXISTS($subquery1)
      $subquery1: correlated [#1:id]
        Filter (#2:n = #1:id)
          Scan t [#2:n]
      Scan t [#1:id]
`
	if got := Format(root); got != want {
		t.Fatalf("got:\n%s\nwant:\n%s", got, want)
	}
}
