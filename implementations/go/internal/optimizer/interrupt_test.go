package optimizer_test

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"polyquery/internal/errs"
	"polyquery/internal/interrupt"
	"polyquery/internal/optimizer"
)

// manyJoins is a chain of k joined copies of emp.
func manyJoins(k int) string {
	from := make([]string, k)
	conds := make([]string, k-1)
	for i := range from {
		from[i] = fmt.Sprintf("emp e%d", i)
		if i > 0 {
			conds[i-1] = fmt.Sprintf("e%d.id = e%d.id", i-1, i)
		}
	}
	return "SELECT e0.name FROM " + strings.Join(from, ", ") + " WHERE " + strings.Join(conds, " AND ")
}

// TestRulesStopAtDeadline: a rule observes the deadline inside its work and
// the optimizer reports TIMEOUT instead of a plan.
func TestRulesStopAtDeadline(t *testing.T) {
	n := logical(t, manyJoins(200))
	ctx, cancel := context.WithTimeout(context.Background(), 0)
	defer cancel()
	expired := interrupt.New(ctx)
	for _, r := range []optimizer.Rule{
		optimizer.PredicatePushdown{Interrupt: expired},
		optimizer.JoinReorder{Interrupt: expired},
		optimizer.ColumnPruning{Interrupt: expired},
	} {
		out, err := (&optimizer.Optimizer{Rules: []optimizer.Rule{r}}).Optimize(n)
		if !errs.Is(err, errs.Timeout) || out != nil {
			t.Errorf("%s: got %v, %v; want TIMEOUT", r.Name(), out, err)
		}
	}
}

// TestJoinReorderManyInputs: the greedy reordering of a long chain of joins
// joins every input once, attaching each conjunct to a join.
func TestJoinReorderManyInputs(t *testing.T) {
	out := apply(t, manyJoins(300), optimizer.PredicatePushdown{}, optimizer.JoinReorder{})
	if strings.Contains(out, "Join CROSS") || strings.Count(out, "Join INNER") != 299 || strings.Count(out, "Scan emp") != 300 {
		t.Fatalf("unexpected plan:\n%.2000s", out)
	}
}
