package interrupt

import (
	"context"
	"testing"

	"polyquery/internal/errs"
)

func TestChecker(t *testing.T) {
	var none *Checker
	if none.Check() != nil || none.Tick() != nil || none.Context() == nil {
		t.Fatal("a nil checker never interrupts")
	}
	ctx, cancel := context.WithCancel(context.Background())
	c := New(ctx)
	for i := 0; i < 2*ticksPerCheck; i++ {
		if err := c.Tick(); err != nil {
			t.Fatal(err)
		}
	}
	cancel()
	if !errs.Is(c.Check(), errs.Cancelled) {
		t.Fatal("cancelled context: want CANCELLED")
	}
	var err error
	for i := 0; i < ticksPerCheck && err == nil; i++ {
		err = c.Tick()
	}
	if !errs.Is(err, errs.Cancelled) {
		t.Fatal("Tick must observe the context within ticksPerCheck calls")
	}
	expired, cancel2 := context.WithTimeout(context.Background(), 0)
	defer cancel2()
	if !errs.Is(New(expired).Check(), errs.Timeout) {
		t.Fatal("expired deadline: want TIMEOUT")
	}
}
