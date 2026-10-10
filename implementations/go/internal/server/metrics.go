package server

import (
	"fmt"
	"io"
	"sync"
	"sync/atomic"
	"time"

	"polyquery/internal/errs"
)

// metrics holds the server's Prometheus counters (protocol.md §7.3).
type metrics struct {
	start     time.Time
	ok        atomic.Int64
	failed    atomic.Int64
	rejected  atomic.Int64
	cancelled atomic.Int64
	timeouts  atomic.Int64

	mu          sync.Mutex
	durationSum float64
	durationN   int64
}

func newMetrics() *metrics { return &metrics{start: time.Now()} }

// observe records a finished query; err is nil on success.
func (m *metrics) observe(d time.Duration, err *errs.Error) {
	if err == nil {
		m.ok.Add(1)
	} else {
		m.failed.Add(1)
		switch err.Code {
		case errs.Overloaded:
			m.rejected.Add(1)
			return // never executed: no duration
		case errs.Cancelled:
			m.cancelled.Add(1)
		case errs.Timeout:
			m.timeouts.Add(1)
		}
	}
	m.mu.Lock()
	m.durationSum += d.Seconds()
	m.durationN++
	m.mu.Unlock()
}

// gauges are the point-in-time values exported with the counters.
type gauges struct {
	running, queued, tables int
}

// write renders the metrics in the Prometheus text format 0.0.4.
func (m *metrics) write(w io.Writer, g gauges) {
	m.mu.Lock()
	sum, n := m.durationSum, m.durationN
	m.mu.Unlock()
	family := func(name, kind, help string) {
		fmt.Fprintf(w, "# HELP %s %s\n# TYPE %s %s\n", name, help, name, kind)
	}
	family("polyquery_queries_total", "counter", "Finished queries by status.")
	fmt.Fprintf(w, "polyquery_queries_total{status=\"ok\"} %d\n", m.ok.Load())
	fmt.Fprintf(w, "polyquery_queries_total{status=\"error\"} %d\n", m.failed.Load())
	family("polyquery_queries_in_flight", "gauge", "Queries currently executing.")
	fmt.Fprintf(w, "polyquery_queries_in_flight %d\n", g.running)
	family("polyquery_queries_queued", "gauge", "Queries waiting for a worker.")
	fmt.Fprintf(w, "polyquery_queries_queued %d\n", g.queued)
	family("polyquery_queries_rejected_total", "counter", "Queries rejected with OVERLOADED.")
	fmt.Fprintf(w, "polyquery_queries_rejected_total %d\n", m.rejected.Load())
	family("polyquery_queries_cancelled_total", "counter", "Queries that ended CANCELLED.")
	fmt.Fprintf(w, "polyquery_queries_cancelled_total %d\n", m.cancelled.Load())
	family("polyquery_queries_timeout_total", "counter", "Queries that ended with TIMEOUT.")
	fmt.Fprintf(w, "polyquery_queries_timeout_total %d\n", m.timeouts.Load())
	family("polyquery_query_duration_seconds", "summary", "Query duration including queueing.")
	fmt.Fprintf(w, "polyquery_query_duration_seconds_sum %g\n", sum)
	fmt.Fprintf(w, "polyquery_query_duration_seconds_count %d\n", n)
	family("polyquery_tables", "gauge", "Tables in the catalog.")
	fmt.Fprintf(w, "polyquery_tables %d\n", g.tables)
	family("polyquery_uptime_seconds", "gauge", "Seconds since the server started.")
	fmt.Fprintf(w, "polyquery_uptime_seconds %g\n", time.Since(m.start).Seconds())
}
