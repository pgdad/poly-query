package server

import (
	"container/list"
	"context"
	"sync"

	"polyquery/internal/errs"
	"polyquery/internal/exec"
)

// admission limits the number of concurrently executing queries to a fixed
// number of workers, with a bounded FIFO queue of waiting queries
// (concurrency.md §2).
type admission struct {
	mu      sync.Mutex
	workers int
	depth   int
	running int
	queue   list.List // of chan struct{}: closed when the waiter is granted a slot
}

func newAdmission(workers, depth int) *admission {
	return &admission{workers: workers, depth: depth}
}

// acquire obtains a worker slot, waiting in the queue if all workers are
// busy. A full queue is OVERLOADED; if ctx ends while waiting, the context
// error (TIMEOUT or CANCELLED) is returned. On success the caller must call
// release.
func (a *admission) acquire(ctx context.Context) error {
	a.mu.Lock()
	if a.running < a.workers && a.queue.Len() == 0 {
		a.running++
		a.mu.Unlock()
		return nil
	}
	if a.queue.Len() >= a.depth {
		a.mu.Unlock()
		return errs.New(errs.Overloaded, "server overloaded: %d queries running and %d queued", a.running, a.queue.Len())
	}
	granted := make(chan struct{})
	elem := a.queue.PushBack(granted)
	a.mu.Unlock()

	select {
	case <-granted:
		return nil
	case <-ctx.Done():
	}
	a.mu.Lock()
	select {
	case <-granted:
		// Granted concurrently with the context ending: hand the slot on.
		a.mu.Unlock()
		a.release()
	default:
		a.queue.Remove(elem)
		a.mu.Unlock()
	}
	return exec.ContextError(ctx.Err())
}

// release frees a worker slot, passing it to the oldest waiter if any.
func (a *admission) release() {
	a.mu.Lock()
	defer a.mu.Unlock()
	if front := a.queue.Front(); front != nil {
		a.queue.Remove(front)
		close(front.Value.(chan struct{}))
		return
	}
	a.running--
}

// stats returns the number of running and queued queries.
func (a *admission) stats() (running, queued int) {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.running, a.queue.Len()
}
