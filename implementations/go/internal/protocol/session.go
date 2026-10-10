package protocol

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
)

// RunSession reads JSON-lines requests from in and writes one response line
// per request to out, flushing after each, until EOF (protocol.md §3).
func (h *Handler) RunSession(in io.Reader, out io.Writer) error {
	r := bufio.NewReaderSize(in, 1<<20)
	w := bufio.NewWriterSize(out, 1<<16)
	for {
		line, err := r.ReadBytes('\n')
		if len(bytes.TrimSpace(line)) > 0 {
			resp := h.HandleLine(line)
			if _, werr := w.Write(append(resp, '\n')); werr != nil {
				return werr
			}
			if werr := w.Flush(); werr != nil {
				return werr
			}
		}
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
	}
}

// RunExec executes a single JSON request or a JSON array of requests and
// writes one response line per request (protocol.md §2, exec mode).
func (h *Handler) RunExec(input []byte, out io.Writer) error {
	w := bufio.NewWriter(out)
	defer w.Flush()
	trimmed := bytes.TrimSpace(input)
	var list []json.RawMessage
	if len(trimmed) > 0 && trimmed[0] == '[' && json.Unmarshal(trimmed, &list) == nil {
		for _, item := range list {
			if _, err := w.Write(append(h.HandleLine(item), '\n')); err != nil {
				return err
			}
		}
		return nil
	}
	_, err := w.Write(append(h.HandleLine(trimmed), '\n'))
	return err
}
