package server

import (
	"context"
	"sort"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"polyquery/internal/errs"
)

// activeQuery is a queued or running query known to the server.
type activeQuery struct {
	id      string
	start   time.Time
	cancel  context.CancelFunc
	running atomic.Bool
}

// registry tracks the queued and running queries by query id, for listing
// and cancellation (protocol.md §7).
type registry struct {
	mu      sync.Mutex
	queries map[string]*activeQuery
	seq     atomic.Int64
}

func newRegistry() *registry {
	return &registry{queries: map[string]*activeQuery{}}
}

// add registers a query. An empty id is replaced by a server-assigned one;
// an id already in use is ALREADY_EXISTS.
func (r *registry) add(id string, cancel context.CancelFunc) (*activeQuery, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if id == "" {
		for {
			id = "q-" + strconv.FormatInt(r.seq.Add(1), 10)
			if _, taken := r.queries[id]; !taken {
				break
			}
		}
	} else if _, taken := r.queries[id]; taken {
		return nil, errs.New(errs.AlreadyExists, "query id %q is already in use", id)
	}
	q := &activeQuery{id: id, start: time.Now(), cancel: cancel}
	r.queries[id] = q
	return q, nil
}

// remove unregisters a finished query.
func (r *registry) remove(q *activeQuery) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.queries[q.id] == q {
		delete(r.queries, q.id)
	}
}

// cancel requests cancellation of a query; false if the id is unknown.
func (r *registry) cancel(id string) bool {
	r.mu.Lock()
	q, ok := r.queries[id]
	r.mu.Unlock()
	if ok {
		q.cancel()
	}
	return ok
}

// cancelAll cancels every registered query.
func (r *registry) cancelAll() {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, q := range r.queries {
		q.cancel()
	}
}

// list returns the registered queries ordered by arrival.
func (r *registry) list() []*activeQuery {
	r.mu.Lock()
	out := make([]*activeQuery, 0, len(r.queries))
	for _, q := range r.queries {
		out = append(out, q)
	}
	r.mu.Unlock()
	sort.Slice(out, func(i, j int) bool { return out[i].start.Before(out[j].start) })
	return out
}
