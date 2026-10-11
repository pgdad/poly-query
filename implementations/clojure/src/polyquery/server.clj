(ns polyquery.server
  "The `serve` mode (spec/protocol/protocol.md §7, spec/concurrency/
  concurrency.md): HTTP endpoints, query lifecycle (registration under a
  query id, admission control, timeouts, cancellation, client-disconnect
  detection), NDJSON streaming with backpressure, metrics, structured logs
  and graceful shutdown.

  Threading model: one platform thread per connection parses requests and
  writes responses. Queries execute on separate worker threads while the
  connection thread watches for completion, cancellation and client
  disconnects. Each query works on the catalog snapshot it took when it
  started (polyquery.catalog is an immutable value in an atom)."
  (:require [clojure.string :as str]
            [polyquery.errors :as err]
            [polyquery.exec.context :as ctx]
            [polyquery.protocol :as protocol]
            [polyquery.server.admission :as adm]
            [polyquery.server.http :as http]
            [polyquery.server.metrics :as metrics]
            [polyquery.util.json :as json]
            [polyquery.util.log :as log])
  (:import (java.io FileDescriptor FileOutputStream IOException PrintStream)
           (java.net InetAddress InetSocketAddress ServerSocket Socket SocketException)
           (java.nio.charset StandardCharsets)
           (java.util ArrayList UUID)
           (java.util.concurrent ArrayBlockingQueue ConcurrentHashMap ExecutorService Executors
                                 Future ThreadFactory TimeUnit TimeoutException)
           (java.util.concurrent.atomic AtomicBoolean AtomicLong)))

(set! *warn-on-reflection* true)

(def ^:private stream-batch-rows
  "Rows per streamed `rows` line (protocol.md §7.2: at most 10,000)."
  1000)

(def ^:private stream-queue-batches
  "Batches buffered between execution and the client (§7.2: at most 16)."
  8)

(def ^:private poll-ms
  "Granularity of the connection thread's watch loop."
  10)

(def ^:private http-status
  "Error code → HTTP status (protocol.md §7.1)."
  {"PARSE_ERROR" 400 "SEMANTIC_ERROR" 400 "TYPE_ERROR" 400 "CONVERSION_ERROR" 400
   "INVALID_ARGUMENT" 400 "INVALID_REQUEST" 400 "INGEST_ERROR" 400 "NUMERIC_OVERFLOW" 400
   "DIVISION_BY_ZERO" 400 "SUBQUERY_CARDINALITY" 400 "UNSUPPORTED" 400
   "ACCESS_DENIED" 403
   "NOT_FOUND" 404
   "ALREADY_EXISTS" 409 "CANCELLED" 409
   "RESOURCE_LIMIT" 413
   "INTERNAL_ERROR" 500 "IO_ERROR" 500 "STORAGE_CORRUPT" 500 "STORAGE_VERSION_UNSUPPORTED" 500
   "OVERLOADED" 503 "SHUTTING_DOWN" 503
   "TIMEOUT" 504})

(defn status-of-code ^long [code] (get http-status code 500))

;; ---------------------------------------------------------------------------
;; Replies: {:status n :body json-value :headers {…}} or {:status n :text s}

(defn- reply
  ([status body] {:status status :body body})
  ([status body headers] {:status status :body body :headers headers}))

(defn- protocol-reply
  "Reply for a protocol response object: ok-status on success, else the
  status of its error code."
  [resp ok-status]
  (reply (if (get resp "ok") ok-status (status-of-code (get-in resp ["error" "code"]))) resp))

(defn- error-reply
  ([t] (error-reply nil t))
  ([id t] (protocol-reply (protocol/error-response id t) 200)))

(defn- error-reply* [code message]
  (error-reply (err/error code message)))

(defn- json-line ^bytes [v]
  (.getBytes (str (json/write-str v) "\n") StandardCharsets/UTF_8))

;; ---------------------------------------------------------------------------
;; Server state

(defn- thread-factory
  "Daemon platform threads with a large stack (deeply nested SQL/JSON)."
  ^ThreadFactory [prefix]
  (let [n (AtomicLong.)]
    (reify ThreadFactory
      (newThread [_ r]
        (doto (Thread. nil r (str prefix "-" (.incrementAndGet n)) (* 256 1024 1024))
          (.setDaemon true))))))

(defn make-server
  "opts: :workers :queue-depth :query-timeout-ms :shutdown-grace-ms
  :max-request-bytes."
  [engine-state opts]
  {:state engine-state
   :opts opts
   :admission (adm/make-admission (:workers opts) (:queue-depth opts))
   :metrics (metrics/make-metrics)
   :queries (ConcurrentHashMap.)
   :shutting-down (AtomicBoolean. false)
   :connections (ConcurrentHashMap/newKeySet)
   :active-requests (AtomicLong.)
   :query-pool (Executors/newCachedThreadPool (thread-factory "pq-query"))
   :connection-pool (Executors/newCachedThreadPool (thread-factory "pq-conn"))})

(defn- shutting-down? [srv] (.get ^AtomicBoolean (:shutting-down srv)))

(defn- queries ^ConcurrentHashMap [srv] (:queries srv))

;; ---------------------------------------------------------------------------
;; Query lifecycle

(defrecord QueryEntry [id ^long start-ns state ^AtomicBoolean cancel ^AtomicBoolean client-gone
                       ^AtomicBoolean holds-worker ^AtomicBoolean finished])

(defn- new-entry [id start-ns]
  (->QueryEntry id start-ns (volatile! "queued") (AtomicBoolean.) (AtomicBoolean.)
                (AtomicBoolean.) (AtomicBoolean.)))

(defn- query-id
  "The client's options.query_id, or a fresh server-assigned id."
  [options]
  (let [id (get options "query_id")]
    (if (string? id) id (str "pq-" (UUID/randomUUID)))))

(defn- deadline-ns
  "Absolute deadline of a query arriving at `arrival` (concurrency.md §3:
  options.timeout_ms if > 0, else --query-timeout-ms if > 0, else none = 0).
  Time spent queued counts toward it."
  ^long [srv options ^long arrival]
  (let [t (get options "timeout_ms")
        ms (if (and (instance? Long t) (pos? (long t)))
             (long t)
             (long (or (:query-timeout-ms (:opts srv)) 0)))]
    (if (pos? ms) (+ arrival (* ms 1000000)) 0)))

(defn- finish-query!
  "Unregisters a query, returns its worker and records metrics and the
  completion log event. Idempotent."
  [srv ^QueryEntry entry error-code rows]
  (when (.compareAndSet ^AtomicBoolean (:finished entry) false true)
    (.remove (queries srv) (:id entry) entry)
    (when (.compareAndSet ^AtomicBoolean (:holds-worker entry) true false)
      (adm/release! (:admission srv)))
    (let [duration (- (System/nanoTime) (:start-ns entry))]
      (metrics/record-query! (:metrics srv) error-code duration)
      (log/info "query finished"
                (cond-> {"query_id" (:id entry)
                         "status" (if error-code "error" "ok")
                         "duration_ms" (/ (Math/round (/ duration 1000.0)) 1000.0)
                         "rows" (or rows 0)}
                  error-code (assoc "error_code" error-code))))))

(defn- mark-client-gone! [^QueryEntry entry]
  (.set ^AtomicBoolean (:client-gone entry) true)
  (.set ^AtomicBoolean (:cancel entry) true))

(defn- client-gone? [^QueryEntry entry] (.get ^AtomicBoolean (:client-gone entry)))

(defn- stop-reason
  "Error code that should stop a waiting query now, or nil."
  [^QueryEntry entry ^long deadline conn]
  (cond
    (.get ^AtomicBoolean (:cancel entry)) "CANCELLED"
    (and (pos? deadline) (>= (- (System/nanoTime) deadline) 0)) "TIMEOUT"
    (http/client-gone? conn) (do (mark-client-gone! entry) "CANCELLED")
    :else nil))

(defn- acquire-worker!
  "Admits the query (concurrency.md §2), waiting in the FIFO queue if
  needed. Throws OVERLOADED, or TIMEOUT/CANCELLED while queued."
  [srv conn ^QueryEntry entry ^long deadline]
  (let [admission (:admission srv)
        ticket (adm/try-admit! admission)]
    (cond
      (nil? ticket)
      (err/fail! "OVERLOADED" "all workers are busy and the queue is full")

      (= :running ticket) nil

      :else
      (loop []
        (when-let [code (stop-reason entry deadline conn)]
          (adm/abandon! admission ticket)
          (err/fail! code (if (= code "TIMEOUT")
                            "query timed out while queued"
                            "query was cancelled while queued")))
        (when-not (adm/await-ticket ticket poll-ms)
          (recur))))
    (.set ^AtomicBoolean (:holds-worker entry) true)
    (vreset! (:state entry) "running")))

(defn- query-state
  "Engine state carrying the external controls of a query."
  [srv ^QueryEntry entry ^long deadline]
  (assoc (:state srv) :query-control {:cancel-flag (:cancel entry) :deadline-ns deadline}))

(defn- submit ^Future [srv ^Callable f]
  (.submit ^ExecutorService (:query-pool srv) f))

(defn- await-result
  "Waits for a query's future while watching for client disconnects (which
  cancel the query)."
  [^Future fut conn ^QueryEntry entry]
  (loop []
    (let [r (try (.get fut poll-ms TimeUnit/MILLISECONDS)
                 (catch TimeoutException _ ::pending))]
      (if (= r ::pending)
        (do (when (and (not (client-gone? entry)) (http/client-gone? conn))
              (mark-client-gone! entry))
            (recur))
        r))))

(defn- run-query
  "Executes an admitted (non-streaming) query request; returns the protocol
  response object."
  [srv conn ^QueryEntry entry req deadline]
  (let [state (query-state srv entry deadline)]
    (await-result (submit srv #(protocol/handle-request state req)) conn entry)))

;; --- streaming (protocol.md §7.2)

(defn- offer!
  "Puts msg into the bounded queue, blocking while it is full (backpressure).
  check is called while waiting and may throw to abort."
  [^ArrayBlockingQueue q msg check]
  (loop []
    (when-not (.offer q msg poll-ms TimeUnit/MILLISECONDS)
      (check)
      (recur))))

(defn- produce-stream
  "Worker side of a streamed query: opens the statement and pushes
  [:header columns], [:rows batch]…, then [:end n] or [:error throwable]."
  [state req ^ArrayBlockingQueue q ^QueryEntry entry]
  (try
    (let [{:keys [columns rows ctx count-only?]} (protocol/open-query state req)
          check #(ctx/check! ctx)
          batch (ArrayList. ^long stream-batch-rows)
          flush-batch! (fn []
                         (when-not (.isEmpty batch)
                           (offer! q [:rows (vec batch)] check)
                           (.clear batch)))]
      (offer! q [:header columns] check)
      (let [n (reduce (fn [^long n row]
                        (when-not count-only?
                          (.add batch row)
                          (when (>= (.size batch) (long stream-batch-rows))
                            (flush-batch!)))
                        (inc n))
                      0 rows)]
        (flush-batch!)
        (offer! q [:end n] check)))
    (catch Throwable t
      (when-not (err/error-code t)
        (log/error "streamed query failed" {"query_id" (:id entry) "exception" (str t)}))
      ;; the consumer either takes it or has gone away
      (offer! q [:error t] #(when (client-gone? entry)
                              (throw (ex-info "client gone" {::client-gone true})))))))

(defn- stream-step
  "Handles one message of the producer. Returns ::continue, ::header-sent,
  ::handled (response complete) or an error reply (failure before the
  header)."
  [srv conn ^QueryEntry entry msg header? headers]
  (let [[kind x] msg]
    (case kind
      :header (do (http/start-chunked! conn 200 (assoc headers "Content-Type" "application/x-ndjson"))
                  (http/write-chunk! conn (json-line {"type" "header" "query_id" (:id entry) "columns" x}))
                  ::header-sent)
      :rows (do (http/write-chunk! conn (json-line {"type" "rows" "rows" x}))
                ::continue)
      :end (do (finish-query! srv entry nil x)
               (http/write-chunk! conn (json-line {"type" "end" "row_count" x}))
               (http/end-chunked! conn)
               ::handled)
      :error (let [code (or (err/error-code x) (get (err/->error-object x) "code"))]
               (finish-query! srv entry code 0)
               (if header?
                 (do (http/write-chunk! conn (json-line {"type" "error" "error" (err/->error-object x)}))
                     (http/end-chunked! conn)
                     ::handled)
                 (assoc (error-reply x) :headers headers))))))

(defn- stream-query
  "Executes an admitted streaming query, writing the chunked NDJSON
  response. Returns ::handled, ::close or an error reply."
  [srv conn ^QueryEntry entry req deadline headers]
  (let [q (ArrayBlockingQueue. (int stream-queue-batches))
        state (query-state srv entry deadline)
        fut (submit srv #(produce-stream state req q entry))
        abandon (fn []
                  (mark-client-gone! entry)
                  (try (.get fut) (catch Exception _ nil))
                  (finish-query! srv entry "CANCELLED" 0)
                  ::close)]
    (loop [header? false]
      (let [msg (.poll q poll-ms TimeUnit/MILLISECONDS)]
        (cond
          (nil? msg)
          (if (http/client-gone? conn)
            (abandon)
            (recur header?))

          :else
          (let [step (try (stream-step srv conn entry msg header? headers)
                          (catch IOException _ ::gone))]
            (case step
              ::gone (abandon)
              ::continue (recur header?)
              ::header-sent (recur true)
              step)))))))

;; --- entry point for query requests

(defn- handle-query
  "Runs a query request (POST /v1/query, /v1/query/stream, or /v1/request
  with op query) through registration, admission and execution."
  [srv conn req stream? keep-alive?]
  (let [arrival (System/nanoTime)
        options (let [o (get req "options")] (if (map? o) o {}))
        qid (query-id options)
        headers {"X-PolyQuery-Query-Id" qid "Connection" (if keep-alive? "keep-alive" "close")}
        deadline (deadline-ns srv options arrival)
        entry (new-entry qid arrival)
        fail-reply (fn [t] (assoc (error-reply (get req "id") t) :headers headers))]
    (cond
      (shutting-down? srv)
      (do (metrics/record-query! (:metrics srv) "SHUTTING_DOWN" 0)
          (fail-reply (err/error "SHUTTING_DOWN" "the server is shutting down")))

      (.putIfAbsent (queries srv) qid entry)
      (do (metrics/record-query! (:metrics srv) "ALREADY_EXISTS" 0)
          (fail-reply (err/error "ALREADY_EXISTS" (str "query id '" qid "' is already in use"))))

      :else
      (try
        (acquire-worker! srv conn entry deadline)
        (if stream?
          (stream-query srv conn entry req deadline headers)
          (let [resp (run-query srv conn entry req deadline)]
            (finish-query! srv entry (when-not (get resp "ok") (get-in resp ["error" "code"]))
                           (get resp "row_count"))
            (if (client-gone? entry)
              ::close
              (assoc (protocol-reply resp 200) :headers headers))))
        (catch clojure.lang.ExceptionInfo e
          (if-let [code (err/error-code e)]
            (do (finish-query! srv entry code 0)
                (fail-reply e))
            (throw e)))
        (finally
          (finish-query! srv entry "INTERNAL_ERROR" 0))))))

;; ---------------------------------------------------------------------------
;; Endpoints

(defn- json-body
  "Parses a JSON request body; INVALID_REQUEST when malformed."
  [^bytes body]
  (try
    (json/read-str (String. body StandardCharsets/UTF_8))
    (catch clojure.lang.ExceptionInfo e
      (if (json/syntax-error? e)
        (err/fail! "INVALID_REQUEST" (str "malformed JSON body: " (.getMessage e)))
        (throw e)))))

(defn- json-object-body [req]
  (let [v (json-body (:body req))]
    (if (map? v) v (err/fail! "INVALID_REQUEST" "request body must be a JSON object"))))

(defn- protocol-op
  "Runs a (non-query) protocol request on the connection thread."
  [srv req ok-status]
  (protocol-reply (protocol/handle-request (:state srv) req) ok-status))

(defn- bool-param [params k default]
  (case (get params k)
    nil default
    "true" true
    "false" false
    (err/fail! "INVALID_REQUEST" (str "query parameter '" k "' must be true or false"))))

(defn- put-table
  "PUT /v1/tables/{name}?format=…[&replace=true][&header=false]: the body is
  the raw data."
  [srv table {:keys [params body]}]
  (let [options (cond-> {"header" (bool-param params "header" true)}
                  (get params "delimiter") (assoc "delimiter" (get params "delimiter"))
                  (get params "layout") (assoc "layout" (get params "layout"))
                  (get params "dictionary") (assoc "dictionary" (bool-param params "dictionary" nil)))]
    (protocol-op srv {"op" "load" "table" table "format" (get params "format")
                      "replace" (bool-param params "replace" false)
                      "options" options
                      ::protocol/data-bytes body}
                 201)))

(defn- list-queries [srv]
  (let [now (System/nanoTime)]
    (reply 200 {"ok" true
                "queries" (->> (.values (queries srv))
                               (sort-by :start-ns)
                               (mapv (fn [^QueryEntry e]
                                       {"query_id" (:id e)
                                        "state" @(:state e)
                                        "elapsed_ms" (quot (- now (:start-ns e)) 1000000)})))})))

(defn- cancel-query [srv id]
  (if-let [^QueryEntry e (.get (queries srv) id)]
    (do (.set ^AtomicBoolean (:cancel e) true)
        (log/info "query cancellation requested" {"query_id" id})
        (reply 200 {"ok" true "cancelled" true}))
    (error-reply* "NOT_FOUND" (str "no running or queued query with id '" id "'"))))

(defn- metrics-reply [srv]
  (let [admission (:admission srv)]
    {:status 200
     :content-type "text/plain; version=0.0.4; charset=utf-8"
     :text (metrics/render (:metrics srv)
                           {:in-flight (adm/running-count admission)
                            :queued (adm/queued-count admission)
                            :tables (count (:tables @(:catalog (:state srv))))})}))

(defn- health [srv]
  (if (shutting-down? srv)
    (reply 503 {"status" "shutting_down"})
    (reply 200 {"status" "ok"})))

(defn- route
  "Dispatches a parsed request; returns a reply, ::handled or ::close."
  [srv conn {:keys [method segments] :as req} keep-alive?]
  (let [segs segments
        n (count segs)
        only (fn [allowed f]
               (if (contains? allowed method)
                 (f)
                 (assoc (error-reply* "INVALID_REQUEST" (str "method " method " is not allowed here"))
                        :status 405
                        :headers {"Allow" (str/join ", " (sort allowed))})))
        tables-path? (and (>= n 3) (= ["v1" "tables"] (subvec segs 0 2)))]
    (cond
      (= segs ["health"]) (only #{"GET"} #(health srv))
      (= segs ["metrics"]) (only #{"GET"} #(metrics-reply srv))
      (= segs ["v1" "version"]) (only #{"GET"} #(reply 200 (protocol/version-info)))
      (= segs ["v1" "capabilities"]) (only #{"GET"} #(reply 200 (protocol/capabilities-info)))
      (= segs ["v1" "query"])
      (only #{"POST"} #(handle-query srv conn (assoc (json-object-body req) "op" "query") false keep-alive?))
      (= segs ["v1" "query" "stream"])
      (only #{"POST"} #(handle-query srv conn (assoc (json-object-body req) "op" "query") true keep-alive?))
      (= segs ["v1" "explain"])
      (only #{"POST"} #(protocol-op srv (assoc (json-object-body req) "op" "explain") 200))
      (= segs ["v1" "request"])
      (only #{"POST"} #(let [body (json-body (:body req))]
                         (if (and (map? body) (= "query" (get body "op")))
                           (handle-query srv conn body false keep-alive?)
                           (protocol-op srv body 200))))
      (= segs ["v1" "tables"]) (only #{"GET"} #(protocol-op srv {"op" "tables"} 200))
      (and tables-path? (= n 3))
      (only #{"PUT" "DELETE"} #(if (= method "PUT")
                                 (put-table srv (nth segs 2) req)
                                 (protocol-op srv {"op" "drop" "table" (nth segs 2)} 200)))
      (and tables-path? (= n 4) (#{"schema" "stats"} (nth segs 3)))
      (only #{"GET"} #(protocol-op srv {"op" (nth segs 3) "table" (nth segs 2)} 200))
      (= segs ["v1" "queries"]) (only #{"GET"} #(list-queries srv))
      (and (= n 3) (= ["v1" "queries"] (subvec segs 0 2)))
      (only #{"DELETE"} #(cancel-query srv (nth segs 2)))
      :else (error-reply* "NOT_FOUND" (str "no endpoint " (:path req))))))

(defn- write-reply! [conn {:keys [status body text content-type headers]} keep-alive?]
  (http/write-response! conn status
                        (merge {"Content-Type" (or content-type "application/json")
                                "Connection" (if keep-alive? "keep-alive" "close")}
                               headers)
                        (if text (.getBytes ^String text StandardCharsets/UTF_8) (json-line body))))

(defn- serve-request
  "Handles one request; returns true to keep the connection open."
  [srv conn req]
  (let [started (System/nanoTime)
        keep-alive? (and (:keep-alive? req) (not (shutting-down? srv)))
        result (if-let [{:keys [status code message]} (:error req)]
                 (assoc (error-reply* code message) :status status)
                 (try
                   (route srv conn req keep-alive?)
                   (catch Throwable t
                     (when-not (err/error-code t)
                       (log/error "request failed" {"path" (:path req) "exception" (str t)}))
                     (error-reply t))))]
    (when (map? result)
      (write-reply! conn result keep-alive?))
    (log/debug "request" {"method" (:method req) "path" (:path req)
                          "status" (if (map? result) (:status result) (name result))
                          "duration_ms" (quot (- (System/nanoTime) started) 1000000)})
    (and keep-alive? (not= ::close result))))

(defn- serve-connection [srv ^Socket socket]
  (let [conn (http/make-conn socket)
        ^java.util.Set conns (:connections srv)
        ^AtomicLong active (:active-requests srv)
        max-bytes (long (:max-request-bytes (:opts srv)))]
    (.add conns conn)
    (try
      (loop []
        (when-let [req (http/read-request conn max-bytes)]
          (.incrementAndGet active)
          (when (try (serve-request srv conn req)
                     (finally (.decrementAndGet active)))
            (recur))))
      (catch IOException _ nil)
      (catch Throwable t
        (log/error "connection failed" {"exception" (str t)}))
      (finally
        (.remove conns conn)
        (http/close! conn)))))

;; ---------------------------------------------------------------------------
;; Startup and shutdown (concurrency.md §5)

(defn- busy? [srv]
  (or (pos? (.get ^AtomicLong (:active-requests srv)))
      (not (.isEmpty (queries srv)))))

(defn- wait-until-idle
  "Waits up to ms milliseconds for all requests to finish; true if idle."
  [srv ^long ms]
  (let [end (+ (System/nanoTime) (* ms 1000000))]
    (loop []
      (cond
        (not (busy? srv)) true
        (>= (- (System/nanoTime) end) 0) false
        :else (do (Thread/sleep 5) (recur))))))

(defn shutdown!
  "Graceful shutdown: stop accepting connections, let running and queued
  queries finish within the grace period, then cancel the rest and close all
  connections."
  [srv ^ServerSocket server-socket]
  (when (.compareAndSet ^AtomicBoolean (:shutting-down srv) false true)
    (log/info "shutting down" {"grace_ms" (:shutdown-grace-ms (:opts srv))})
    (try (.close server-socket) (catch IOException _ nil))
    (when-not (wait-until-idle srv (long (:shutdown-grace-ms (:opts srv))))
      (log/warn "grace period expired, cancelling queries" {"queries" (.size (queries srv))})
      (doseq [^QueryEntry e (.values (queries srv))]
        (.set ^AtomicBoolean (:cancel e) true))
      (wait-until-idle srv 2000))
    (doseq [conn (vec (:connections srv))]
      (http/close! conn))
    (log/info "server stopped")))

(defn- announce!
  "Prints the single `listening` line on stdout (protocol.md §2)."
  [host port]
  (let [out (PrintStream. (FileOutputStream. FileDescriptor/out) true "UTF-8")]
    (.print out (str (json/write-str {"event" "listening" "host" host "port" port}) "\n"))
    (.flush out)))

(defn start!
  "Binds the server socket and starts accepting connections on a background
  thread. Returns the server (with :server-socket and :port)."
  [engine-state {:keys [host port] :as opts}]
  (let [srv (make-server engine-state opts)
        ss (ServerSocket.)]
    (.setReuseAddress ss true)
    (.bind ss (InetSocketAddress. (InetAddress/getByName host) (int port)) 1024)
    (let [^ExecutorService pool (:connection-pool srv)]
      (doto (Thread. ^Runnable (fn []
                                 (loop []
                                   (when-let [socket (try (.accept ss) (catch SocketException _ nil))]
                                     (.execute pool #(serve-connection srv socket))
                                     (recur))))
                     "pq-accept")
        (.setDaemon true)
        (.start)))
    (assoc srv :server-socket ss :port (.getLocalPort ss))))

(defn stop!
  "Graceful shutdown of a server returned by start!."
  [srv]
  (shutdown! srv (:server-socket srv)))

(defn run-server
  "Runs the HTTP server until SIGTERM/SIGINT; never returns (the shutdown
  hook halts the JVM with status 0 after the graceful shutdown)."
  [engine-state {:keys [host] :as opts}]
  (let [srv (start! engine-state opts)]
    (.addShutdownHook (Runtime/getRuntime)
                      (Thread. ^Runnable (fn []
                                           (try (stop! srv)
                                                (catch Throwable t
                                                  (log/error "shutdown failed" {"exception" (str t)}))
                                                (finally
                                                  (.flush System/err)
                                                  (.halt (Runtime/getRuntime) 0))))
                               "pq-shutdown"))
    (log/info "server listening" {"host" host "port" (:port srv)
                                  "workers" (:workers opts) "queue_depth" (:queue-depth opts)})
    (announce! host (:port srv))
    @(promise)))
