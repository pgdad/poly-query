// Command polyquery is the PolyQuery engine CLI (spec/protocol/protocol.md §2).
package main

import (
	"fmt"
	"io"
	"log/slog"
	"os"
	"strconv"
	"strings"
	"time"

	"polyquery/internal/engine"
	"polyquery/internal/protocol"
)

const usage = `usage: polyquery (version | capabilities | session | exec | serve) [options]

options:
  --data-dir DIR              root for request file paths (default: current directory)
  --enable-test-functions     enable PQ_SLEEP and the sleep op
  --max-query-memory-mb N     per-query memory budget (default 4096)
  --max-ingest-bytes N        ingestion size limit (default 4 GiB)
  --max-table-rows N          maximum rows per table (default 500000000)
  --max-join-rows N           maximum join rows (default 100000000)
  --threads N                 worker threads per query (default 1)
  --log-level LEVEL           debug, info, warn, error, off (default info)
  --native-kernels PATH       native kernel library (unused)
  --request FILE|-            exec mode: request file, or - for stdin
`

type options struct {
	cfg     engine.Config
	request string
	level   string
}

func usageError(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "polyquery: "+format+"\n", args...)
	fmt.Fprint(os.Stderr, usage)
	os.Exit(2)
}

func parseArgs(mode string, args []string) options {
	o := options{cfg: engine.DefaultConfig(), level: "info"}
	serveOnly := map[string]bool{"--host": true, "--port": true, "--workers": true, "--queue-depth": true,
		"--query-timeout-ms": true, "--shutdown-grace-ms": true, "--max-request-bytes": true}
	for i := 0; i < len(args); i++ {
		name, value, hasValue := strings.Cut(args[i], "=")
		next := func() string {
			if hasValue {
				return value
			}
			if i+1 >= len(args) {
				usageError("option %s requires a value", name)
			}
			i++
			return args[i]
		}
		number := func() int64 {
			v := next()
			n, err := strconv.ParseInt(v, 10, 64)
			if err != nil || n < 0 {
				usageError("option %s requires a non-negative integer, got %q", name, v)
			}
			return n
		}
		switch name {
		case "--data-dir":
			o.cfg.DataDir = next()
		case "--enable-test-functions":
			if hasValue {
				usageError("option %s takes no value", name)
			}
			o.cfg.TestFunctions = true
		case "--max-query-memory-mb":
			o.cfg.MaxQueryMemoryMB = number()
		case "--max-ingest-bytes":
			o.cfg.MaxIngestBytes = number()
		case "--max-table-rows":
			o.cfg.MaxTableRows = number()
		case "--max-join-rows":
			o.cfg.MaxJoinRows = number()
		case "--threads":
			o.cfg.Threads = int(number())
		case "--log-level":
			o.level = next()
			switch o.level {
			case "debug", "info", "warn", "error", "off":
			default:
				usageError("invalid log level %q", o.level)
			}
		case "--native-kernels":
			next()
		case "--request":
			if mode != "exec" {
				usageError("option --request is only valid in exec mode")
			}
			o.request = next()
		default:
			if mode == "serve" && serveOnly[name] {
				next()
				continue
			}
			usageError("unknown option %q", args[i])
		}
	}
	return o
}

func logger(level string, w io.Writer) *slog.Logger {
	var l slog.Level
	switch level {
	case "off":
		return slog.New(slog.NewJSONHandler(io.Discard, nil))
	case "debug":
		l = slog.LevelDebug
	case "warn":
		l = slog.LevelWarn
	case "error":
		l = slog.LevelError
	default:
		l = slog.LevelInfo
	}
	return slog.New(slog.NewJSONHandler(w, &slog.HandlerOptions{
		Level: l,
		ReplaceAttr: func(groups []string, a slog.Attr) slog.Attr {
			if len(groups) == 0 && a.Key == slog.TimeKey {
				return slog.String("ts", a.Value.Time().UTC().Format(time.RFC3339Nano))
			}
			return a
		},
	}))
}

func main() {
	if len(os.Args) < 2 {
		usageError("missing mode")
	}
	mode := os.Args[1]
	switch mode {
	case "version", "capabilities", "session", "exec", "serve":
	case "-h", "--help", "help":
		fmt.Print(usage)
		return
	default:
		usageError("unknown mode %q", mode)
	}
	o := parseArgs(mode, os.Args[2:])
	o.cfg.Logger = logger(o.level, os.Stderr)

	switch mode {
	case "version":
		os.Stdout.Write(append(protocol.VersionJSON(), '\n'))
	case "capabilities":
		os.Stdout.Write(append(protocol.CapabilitiesJSON(), '\n'))
	case "session":
		h := protocol.NewHandler(engine.New(o.cfg))
		if err := h.RunSession(os.Stdin, os.Stdout); err != nil {
			fmt.Fprintf(os.Stderr, "polyquery: %v\n", err)
			os.Exit(1)
		}
	case "exec":
		if o.request == "" {
			usageError("exec mode requires --request FILE or --request -")
		}
		var input []byte
		var err error
		if o.request == "-" {
			input, err = io.ReadAll(os.Stdin)
		} else {
			input, err = os.ReadFile(o.request)
		}
		if err != nil {
			fmt.Fprintf(os.Stderr, "polyquery: cannot read request: %v\n", err)
			os.Exit(1)
		}
		h := protocol.NewHandler(engine.New(o.cfg))
		if err := h.RunExec(input, os.Stdout); err != nil {
			fmt.Fprintf(os.Stderr, "polyquery: %v\n", err)
			os.Exit(1)
		}
	case "serve":
		fmt.Fprintln(os.Stderr, "polyquery: serve mode (HTTP, Phase 4) is not implemented yet")
		os.Exit(1)
	}
}
