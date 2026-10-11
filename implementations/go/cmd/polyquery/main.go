// Command polyquery is the PolyQuery engine CLI (spec/protocol/protocol.md §2).
package main

import (
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"polyquery/internal/engine"
	"polyquery/internal/native"
	"polyquery/internal/protocol"
	"polyquery/internal/server"
)

const usage = `usage: polyquery (version | capabilities | session | exec | serve) [options]

options:
  --data-dir DIR              root for request file paths (default: current directory)
  --enable-test-functions     enable PQ_SLEEP and the sleep op
  --max-query-memory-mb N     per-query memory budget (default 4096)
  --max-ingest-bytes N        ingestion size limit (default 4 GiB)
  --max-table-rows N          maximum rows per table (default 500000000)
  --max-join-rows N           maximum join rows (default 100000000)
  --threads N                 worker threads per query (default: min(4, CPU count))
  --log-level LEVEL           debug, info, warn, error, off (default info)
  --native-kernels PATH       load libpqkernels; queries with "native": true use it
  --request FILE|-            exec mode: request file, or - for stdin

serve options:
  --host HOST                 listen address (default 127.0.0.1)
  --port N                    listen port, 0 = any free port (required)
  --workers N                 max concurrently executing queries (default: CPU count)
  --queue-depth N             max queries waiting for a worker (default 64)
  --query-timeout-ms N        default query timeout, 0 = none (default 0)
  --shutdown-grace-ms N       grace period for running queries on shutdown (default 10000)
  --max-request-bytes N       max HTTP request body size (default 1 GiB)
`

type options struct {
	cfg     engine.Config
	serve   server.Config
	hasPort bool
	request string
	level   string
	native  string // --native-kernels PATH
}

func usageError(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "polyquery: "+format+"\n", args...)
	fmt.Fprint(os.Stderr, usage)
	os.Exit(2)
}

func parseArgs(mode string, args []string) options {
	o := options{cfg: engine.DefaultConfig(), level: "info", serve: server.Config{
		Host:            "127.0.0.1",
		Workers:         runtime.NumCPU(),
		QueueDepth:      64,
		ShutdownGrace:   10 * time.Second,
		MaxRequestBytes: 1 << 30,
	}}
	// Testing aid: tiny morsels make small tables use parallel execution.
	if v, err := strconv.Atoi(os.Getenv("POLYQUERY_MORSEL_ROWS")); err == nil && v > 0 {
		o.cfg.MorselRows = v
	}
	// Testing aid: a small threshold makes small tables use partitioned
	// (scattering) parallel aggregation.
	if v, err := strconv.Atoi(os.Getenv("POLYQUERY_SCATTER_ROWS")); err == nil && v > 0 {
		o.cfg.ScatterRows = v
	}
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
			if o.cfg.Threads < 1 {
				usageError("--threads must be at least 1")
			}
		case "--log-level":
			o.level = next()
			switch o.level {
			case "debug", "info", "warn", "error", "off":
			default:
				usageError("invalid log level %q", o.level)
			}
		case "--native-kernels":
			o.native = next()
		case "--request":
			if mode != "exec" {
				usageError("option --request is only valid in exec mode")
			}
			o.request = next()
		default:
			if mode != "serve" {
				usageError("unknown option %q", args[i])
			}
			parseServeOption(&o, name, next, number)
		}
	}
	return o
}

// parseServeOption handles the options only valid in serve mode.
func parseServeOption(o *options, name string, next func() string, number func() int64) {
	switch name {
	case "--host":
		o.serve.Host = next()
	case "--port":
		n := number()
		if n > 65535 {
			usageError("invalid port %d", n)
		}
		o.serve.Port, o.hasPort = int(n), true
	case "--workers":
		if o.serve.Workers = int(number()); o.serve.Workers < 1 {
			usageError("--workers must be at least 1")
		}
	case "--queue-depth":
		o.serve.QueueDepth = int(number())
	case "--query-timeout-ms":
		o.serve.QueryTimeout = time.Duration(number()) * time.Millisecond
	case "--shutdown-grace-ms":
		o.serve.ShutdownGrace = time.Duration(number()) * time.Millisecond
	case "--max-request-bytes":
		o.serve.MaxRequestBytes = number()
	default:
		usageError("unknown option %q", name)
	}
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
	if o.native != "" && mode != "version" && mode != "capabilities" {
		loadNative(&o)
	}

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
		if !o.hasPort {
			usageError("serve mode requires --port N")
		}
		if err := serve(o); err != nil {
			o.cfg.Logger.Error("server failed", "error", err.Error())
			os.Exit(1)
		}
	}
}

// loadNative loads the native kernel library. Native kernels are optional:
// if the library cannot be loaded the engine logs a warning and runs with
// its own code paths only.
func loadNative(o *options) {
	lib, err := native.Load(o.native)
	if err != nil {
		o.cfg.Logger.Warn("native kernels unavailable", "path", o.native, "error", err.Error())
		return
	}
	o.cfg.Native = lib
	o.cfg.Logger.Info("native kernels loaded", "path", o.native, "variant", lib.Variant())
}

// serve runs the HTTP server until SIGTERM or SIGINT.
func serve(o options) error {
	srv := server.New(engine.New(o.cfg), o.serve)
	ln, err := srv.Listen()
	if err != nil {
		return err
	}
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT)
	stop := make(chan struct{})
	go func() {
		<-signals
		close(stop)
	}()
	if _, err := os.Stdout.Write(append(server.ListeningEvent(o.serve.Host, ln), '\n')); err != nil {
		return err
	}
	return srv.Serve(ln, stop)
}
