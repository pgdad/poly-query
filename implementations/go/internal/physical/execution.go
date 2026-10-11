package physical

import "polyquery/internal/plan"

// Execution holds the plan-wide execution decisions of a physical plan.
type Execution struct {
	// Vectorized selects batch execution; otherwise operators run
	// row-at-a-time (Volcano).
	Vectorized bool
	// Threads is the number of worker goroutines for parallel pipelines
	// (≤ 1: serial execution).
	Threads int
	// Native lets operators use the native kernel library.
	Native bool
}

// chooseExecution decides how plan p is executed. Plans that evaluate
// PQ_SLEEP (a test function) always run row-at-a-time without native
// kernels: its per-row evaluation count is observable through timing, and
// batch execution would evaluate it for rows a LIMIT never needs, native
// filters in a different conjunct order.
func chooseExecution(p *Plan, opts Options) Execution {
	sleeps := callsSleep(p)
	threads := opts.Threads
	if threads <= 0 {
		threads = opts.DefaultThreads
	}
	return Execution{
		Vectorized: opts.Mode != "row" && !sleeps,
		Threads:    threads,
		Native:     opts.Native && !sleeps,
	}
}

// callsSleep reports whether a plan evaluates PQ_SLEEP.
func callsSleep(p *Plan) bool {
	found := false
	var visit func(n Node)
	visit = func(n Node) {
		for _, e := range Exprs(n) {
			plan.Walk(e, func(x plan.Expr) {
				if f, ok := x.(*plan.Func); ok && f.Name == "PQ_SLEEP" {
					found = true
				}
			})
		}
		for _, c := range n.Children() {
			visit(c)
		}
	}
	visit(p.Root)
	for _, sub := range p.Subplans {
		visit(sub)
	}
	return found
}
