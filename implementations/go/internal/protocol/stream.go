package protocol

import (
	"context"

	"polyquery/internal/engine"
	"polyquery/internal/errs"
	"polyquery/internal/plan"
	"polyquery/internal/types"
)

// StartQuery validates a query request and starts the statement, returning
// a cursor over its result together with the decoded options. It is used
// for streamed results (protocol.md §7.2); the caller must Close the cursor.
func (h *Handler) StartQuery(ctx context.Context, req *Request) (*engine.Cursor, engine.QueryOptions, error) {
	sql, err := req.requiredStr("sql")
	if err != nil {
		return nil, engine.QueryOptions{}, err
	}
	qo, err := parseQueryOptions(req)
	if err != nil {
		return nil, qo, err
	}
	cur, err := h.eng.Start(ctx, sql, qo)
	return cur, qo, err
}

func writeResultColumns(w *writer, cols []plan.Column) {
	w.key("columns")
	w.beginArray()
	for _, c := range cols {
		w.beginObject()
		w.key("name")
		w.str(c.Name)
		w.key("type")
		w.str(c.Type.ResultName())
		w.endObject()
	}
	w.endArray()
}

func writeRows(w *writer, rows []types.Row, cols []plan.Column) {
	w.beginArray()
	for _, row := range rows {
		w.beginArray()
		for i, v := range row {
			w.value(v, cols[i].Type)
		}
		w.endArray()
	}
	w.endArray()
}

// StreamHeader renders the header line of a streamed result.
func StreamHeader(queryID string, cols []plan.Column) []byte {
	w := &writer{}
	w.beginObject()
	w.key("type")
	w.str("header")
	w.key("query_id")
	w.str(queryID)
	writeResultColumns(w, cols)
	return finish(w)
}

// StreamRows renders one batch line of a streamed result.
func StreamRows(rows []types.Row, cols []plan.Column) []byte {
	w := &writer{}
	w.beginObject()
	w.key("type")
	w.str("rows")
	w.key("rows")
	writeRows(w, rows, cols)
	return finish(w)
}

// StreamEnd renders the final line of a successfully streamed result.
func StreamEnd(rowCount int64) []byte {
	w := &writer{}
	w.beginObject()
	w.key("type")
	w.str("end")
	w.key("row_count")
	w.int(rowCount)
	return finish(w)
}

// StreamError renders the final line of a stream that failed after its
// header was sent.
func StreamError(e *errs.Error) []byte {
	w := &writer{}
	w.beginObject()
	w.key("type")
	w.str("error")
	w.key("error")
	writeError(w, e)
	return finish(w)
}
