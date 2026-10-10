package server

import (
	"context"
	"fmt"
	"net/http"
	"time"

	"polyquery/internal/engine"
	"polyquery/internal/errs"
	"polyquery/internal/exec"
	"polyquery/internal/protocol"
	"polyquery/internal/types"
)

const (
	// streamBatchRows is the maximum number of rows per "rows" line
	// (protocol.md §7.2 allows up to 10,000).
	streamBatchRows = 1000
	// streamBatchDelay flushes a partial batch of a slow query.
	streamBatchDelay = 100 * time.Millisecond
	// streamBuffer is the number of batches execution may run ahead of the
	// client (≤ 16); a client that stops reading blocks execution.
	streamBuffer = 4
)

// batch is one message from the producing query to the response writer.
// The last message of a stream has end or err set.
type batch struct {
	rows  []types.Row
	end   bool
	count int64
	err   *errs.Error
}

// stream executes an admitted query and writes its result as NDJSON
// (protocol.md §7.2). Execution runs in its own goroutine and hands batches
// to the writer through a bounded channel, which provides backpressure. The
// header is sent with the first batch, so errors that occur before any row
// was produced get a normal error response.
func (s *Server) stream(ctx context.Context, cancel context.CancelFunc, w http.ResponseWriter, req *protocol.Request, qr *queryRun) {
	cur, qo, err := s.startQuery(ctx, req)
	if err != nil {
		e := errs.From(err)
		qr.finish(0, e)
		s.respond(w, protocol.ErrorResponse(req.ID(), e), e, http.StatusOK)
		return
	}
	defer cur.Close()

	batches := make(chan batch, streamBuffer)
	produced := make(chan struct{})
	go func() {
		defer close(produced)
		s.produce(ctx, cur, qo.CountOnly, batches)
	}()
	// On return, stop execution and wait for it before the cursor closes.
	defer func() {
		cancel()
		for range batches {
		}
		<-produced
	}()

	rc := http.NewResponseController(w)
	headerSent := false
	writeLine := func(line []byte) bool {
		if _, err := w.Write(append(line, '\n')); err != nil {
			return false
		}
		return rc.Flush() == nil
	}
	sendHeader := func() bool {
		headerSent = true
		h := w.Header()
		h.Set("Content-Type", "application/x-ndjson")
		h.Set("Cache-Control", "no-store")
		w.WriteHeader(http.StatusOK)
		return writeLine(protocol.StreamHeader(qr.q.id, cur.Columns))
	}

	for b := range batches {
		switch {
		case b.err != nil:
			qr.finish(cur.RowCount(), b.err)
			if headerSent {
				writeLine(protocol.StreamError(b.err))
			} else {
				s.respond(w, protocol.ErrorResponse(req.ID(), b.err), b.err, http.StatusOK)
			}
			return
		case b.end:
			qr.finish(b.count, nil)
			if headerSent || sendHeader() {
				writeLine(protocol.StreamEnd(b.count))
			}
			return
		}
		if (!headerSent && !sendHeader()) || !writeLine(protocol.StreamRows(b.rows, cur.Columns)) {
			// The client went away: cancel the query.
			s.log.Debug("stream client disconnected", "query_id", qr.q.id)
			return
		}
	}
	// The producer stopped without a final message: the context ended.
	e := errs.From(exec.ContextError(ctx.Err()))
	qr.finish(cur.RowCount(), e)
	if headerSent {
		writeLine(protocol.StreamError(e))
	} else {
		s.respond(w, protocol.ErrorResponse(req.ID(), e), e, http.StatusOK)
	}
}

// produce pulls rows from the cursor and sends them in batches.
func (s *Server) produce(ctx context.Context, cur *engine.Cursor, countOnly bool, out chan<- batch) {
	defer close(out)
	send := func(b batch) bool {
		select {
		case out <- b:
			return true
		case <-ctx.Done():
			return false
		}
	}
	defer func() {
		if r := recover(); r != nil {
			s.log.Error("internal error", "panic", fmt.Sprint(r))
			send(batch{err: errs.New(errs.InternalError, "internal error: %v", r)})
		}
	}()
	var rows []types.Row
	started := time.Now()
	for {
		row, err := cur.Next()
		if err != nil {
			send(batch{err: errs.From(err)})
			return
		}
		if row == nil {
			if len(rows) > 0 && !send(batch{rows: rows}) {
				return
			}
			send(batch{end: true, count: cur.RowCount()})
			return
		}
		if countOnly {
			continue
		}
		if len(rows) == 0 {
			started = time.Now()
		}
		rows = append(rows, append(types.Row(nil), row...))
		if len(rows) >= streamBatchRows || time.Since(started) >= streamBatchDelay {
			if !send(batch{rows: rows}) {
				return
			}
			rows = nil
		}
	}
}
