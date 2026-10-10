(ns polyquery.main
  "Command-line entry point (spec/protocol/protocol.md §2-§3): argument
  parsing and the version, capabilities, session and exec modes."
  (:require [clojure.string :as str]
            [polyquery.errors :as err]
            [polyquery.protocol :as protocol]
            [polyquery.server :as server]
            [polyquery.util.json :as json]
            [polyquery.util.log :as log])
  (:import (java.io BufferedReader BufferedWriter File InputStreamReader OutputStreamWriter Writer)
           (java.nio.charset StandardCharsets))
  (:gen-class))

(set! *warn-on-reflection* true)

(def ^:private value-options
  "Options taking a value: option → [config key, parser]."
  {"--data-dir" [:data-dir identity]
   "--max-query-memory-mb" [:max-query-memory-mb :long]
   "--max-ingest-bytes" [:max-ingest-bytes :long]
   "--max-table-rows" [:max-table-rows :long]
   "--max-join-rows" [:max-join-rows :long]
   "--threads" [:threads :long]
   "--log-level" [:log-level identity]
   "--native-kernels" [:native-kernels identity]
   "--request" [:request identity]
   ;; serve mode (Phase 4)
   "--host" [:host identity]
   "--port" [:port :long]
   "--workers" [:workers :long]
   "--queue-depth" [:queue-depth :long]
   "--query-timeout-ms" [:query-timeout-ms :long]
   "--shutdown-grace-ms" [:shutdown-grace-ms :long]
   "--max-request-bytes" [:max-request-bytes :long]})

(def ^:private flag-options
  {"--enable-test-functions" :test-functions?})

(def defaults
  {:max-query-memory-mb 4096
   :max-ingest-bytes (* 4 1024 1024 1024)
   :max-table-rows 200000000
   :max-join-rows 100000000
   :log-level "info"})

(defn- usage-error [msg]
  (throw (ex-info msg {::usage true})))

(defn parse-args
  "Parses CLI arguments into {:mode … option keys …}; throws a usage error."
  [args]
  (let [[mode & opts] args]
    (when-not (#{"version" "capabilities" "session" "exec" "serve"} mode)
      (usage-error (str "unknown or missing mode '" mode
                        "' (expected version, capabilities, session, exec or serve)")))
    (loop [opts opts cfg (assoc defaults :mode mode)]
      (if-let [[o & more] (seq opts)]
        (let [[o inline] (if (and (str/starts-with? o "--") (str/includes? o "="))
                           (str/split o #"=" 2)
                           [o nil])]
          (cond
            (flag-options o)
            (if inline
              (usage-error (str "option " o " takes no value"))
              (recur more (assoc cfg (flag-options o) true)))

            (value-options o)
            (let [[k parse] (value-options o)
                  [raw more] (if inline [inline more] [(first more) (rest more)])
                  _ (when (nil? raw) (usage-error (str "option " o " requires a value")))
                  val (if (= parse :long)
                        (try (let [n (Long/parseLong raw)]
                               (when (neg? n) (usage-error (str "option " o " must not be negative")))
                               n)
                             (catch NumberFormatException _
                               (usage-error (str "option " o " requires an integer value"))))
                        raw)]
              (recur more (assoc cfg k val)))

            :else (usage-error (str "unknown option '" o "'"))))
        cfg))))

(defn- engine-config [cfg]
  {:data-dir (File. (str (or (:data-dir cfg) ".")))
   :test-functions? (boolean (:test-functions? cfg))
   :limits (select-keys cfg [:max-query-memory-mb :max-ingest-bytes :max-table-rows :max-join-rows])})

(defn- stdout-writer ^Writer []
  (BufferedWriter. (OutputStreamWriter. System/out StandardCharsets/UTF_8) 65536))

(defn- parse-request-line [^String line]
  (try
    (json/read-str line)
    (catch clojure.lang.ExceptionInfo e
      (if (json/syntax-error? e) ::invalid (throw e)))))

(defn- respond [state req]
  (if (= req ::invalid)
    (protocol/error-response nil (err/error "INVALID_REQUEST" "request is not valid JSON"))
    (protocol/handle-request state req)))

(defn run-session [cfg]
  (let [state (protocol/make-state (engine-config cfg))
        in (BufferedReader. (InputStreamReader. System/in StandardCharsets/UTF_8) 65536)
        out (stdout-writer)]
    (log/debug "session started")
    (loop []
      (when-let [line (.readLine in)]
        (when-not (str/blank? line)
          (json/write-line! out (respond state (parse-request-line line))))
        (recur)))
    0))

(defn run-exec [cfg]
  (let [src (or (:request cfg) (usage-error "exec requires --request FILE or --request -"))
        text (if (= src "-")
               (slurp (InputStreamReader. System/in StandardCharsets/UTF_8))
               (let [f (File. ^String src)]
                 (when-not (.isFile f)
                   (throw (ex-info (str "cannot read request file " src) {::fatal true})))
                 (slurp f :encoding "UTF-8")))
        state (protocol/make-state (engine-config cfg))
        out (stdout-writer)
        parsed (parse-request-line text)
        requests (if (vector? parsed) parsed [parsed])]
    (doseq [req requests]
      (json/write-line! out (respond state req)))
    0))

(defn run-serve [cfg]
  (when-not (:port cfg) (usage-error "serve requires --port N"))
  (when (> (long (:port cfg)) 65535) (usage-error "--port must be at most 65535"))
  (server/run-server (protocol/make-state (engine-config cfg))
                     {:host (or (:host cfg) "127.0.0.1")
                      :port (:port cfg)
                      :workers (let [w (long (or (:workers cfg) 0))]
                                 (if (pos? w) w (.availableProcessors (Runtime/getRuntime))))
                      :queue-depth (or (:queue-depth cfg) 64)
                      :query-timeout-ms (or (:query-timeout-ms cfg) 0)
                      :shutdown-grace-ms (or (:shutdown-grace-ms cfg) 10000)
                      :max-request-bytes (or (:max-request-bytes cfg) (* 1024 1024 1024))}))

(defn- print-json [v]
  (let [out (stdout-writer)]
    (json/write-line! out v)
    0))

(defn run
  "Runs the CLI; returns the process exit code."
  [args]
  (try
    (let [cfg (parse-args args)]
      (when-not (log/set-level! (:log-level cfg))
        (usage-error (str "invalid --log-level '" (:log-level cfg) "'")))
      (case (:mode cfg)
        "version" (print-json (protocol/version-info))
        "capabilities" (print-json (protocol/capabilities-info))
        "session" (run-session cfg)
        "exec" (run-exec cfg)
        "serve" (run-serve cfg)))
    (catch clojure.lang.ExceptionInfo e
      (cond
        (::usage (ex-data e))
        (do (binding [*out* *err*] (println (str "polyquery: " (.getMessage e))))
            2)
        :else
        (do (binding [*out* *err*] (println (str "polyquery: fatal: " (.getMessage e))))
            1)))
    (catch Throwable t
      (binding [*out* *err*] (println (str "polyquery: fatal: " t)))
      1)))

(defn -main [& args]
  ;; Run on a thread with a large stack so deeply nested SQL/JSON cannot
  ;; overflow it.
  (let [code (promise)
        t (Thread. nil #(deliver code (run args)) "polyquery-main" (* 256 1024 1024))]
    (.start t)
    (.join t)
    (flush)
    (System/exit (int @code))))
