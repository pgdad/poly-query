(ns polyquery.server-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing use-fixtures]]
            [polyquery.protocol :as protocol]
            [polyquery.server :as server]
            [polyquery.server.admission :as adm]
            [polyquery.server.metrics :as metrics]
            [polyquery.util.json :as json]
            [polyquery.util.log :as log])
  (:import (java.io BufferedReader InputStreamReader)
           (java.net Socket URI)
           (java.net.http HttpClient HttpClient$Version HttpRequest HttpRequest$BodyPublishers HttpResponse
                          HttpResponse$BodyHandlers)
           (java.nio.charset StandardCharsets)
           (java.nio.file Files)
           (java.nio.file.attribute FileAttribute)))

(use-fixtures :once (fn [f] (log/set-level! "off") (try (f) (finally (log/set-level! "info")))))

(deftest admission-control
  (let [a (adm/make-admission 1 1)
        first-query (adm/try-admit! a)
        ticket (adm/try-admit! a)]
    (is (= :running first-query))
    (is (some? ticket) "second query is queued")
    (is (nil? (adm/try-admit! a)) "third query is rejected")
    (is (= [1 1] [(adm/running-count a) (adm/queued-count a)]))
    (is (false? (adm/await-ticket ticket 1)))
    (adm/release! a)
    (testing "the queued query inherits the worker"
      (is (true? (adm/await-ticket ticket 1)))
      (is (= [1 0] [(adm/running-count a) (adm/queued-count a)])))
    (testing "abandoning a granted ticket returns its worker"
      (adm/abandon! a ticket)
      (is (= 0 (adm/running-count a))))
    (testing "abandoning a queued ticket removes it"
      (adm/try-admit! a)
      (let [t (adm/try-admit! a)]
        (adm/abandon! a t)
        (is (= [1 0] [(adm/running-count a) (adm/queued-count a)]))))))

(deftest metrics-exposition
  (let [m (metrics/make-metrics)]
    (metrics/record-query! m nil 2000000)
    (metrics/record-query! m "TIMEOUT" 1000000)
    (metrics/record-query! m "OVERLOADED" 0)
    (let [text (metrics/render m {:in-flight 2 :queued 1 :tables 3})]
      (doseq [line ["polyquery_queries_total{status=\"ok\"} 1"
                    "polyquery_queries_total{status=\"error\"} 2"
                    "polyquery_queries_in_flight 2" "polyquery_queries_queued 1"
                    "polyquery_queries_rejected_total 1" "polyquery_queries_timeout_total 1"
                    "polyquery_queries_cancelled_total 0" "polyquery_query_duration_seconds_count 2"
                    "polyquery_query_duration_seconds_sum 0.003000" "polyquery_tables 3"]]
        (is (str/includes? text (str line "\n")) line))
      (is (re-find #"(?m)^polyquery_uptime_seconds \d+\.\d{3}$" text)))))

(deftest status-mapping
  (is (= [400 403 404 409 409 413 500 503 504]
         (mapv server/status-of-code ["PARSE_ERROR" "ACCESS_DENIED" "NOT_FOUND" "ALREADY_EXISTS"
                                      "CANCELLED" "RESOURCE_LIMIT" "IO_ERROR" "OVERLOADED" "TIMEOUT"]))))

;; ---------------------------------------------------------------------------
;; End-to-end over a real socket

(def ^:dynamic *base* nil)

(def ^:private ^HttpClient client
  (-> (HttpClient/newBuilder) (.version HttpClient$Version/HTTP_1_1) (.build)))

(defn- http
  "Returns [status headers body-string]."
  ([method path] (http method path nil))
  ([method path ^String body]
   (let [req (-> (HttpRequest/newBuilder (URI. (str *base* path)))
                 (.method method (if body
                                   (HttpRequest$BodyPublishers/ofString body)
                                   (HttpRequest$BodyPublishers/noBody)))
                 (.build))
         ^HttpResponse resp (.send client req (HttpResponse$BodyHandlers/ofString))]
     [(.statusCode resp) (.map (.headers resp)) (.body resp)])))

(defn- http-json [method path & [body]]
  (let [[status headers text] (http method path (if (string? body) body (some-> body json/write-str)))]
    [status (json/read-str text) headers]))

(defn- with-server [opts f]
  (let [dir (.toFile (Files/createTempDirectory "pq-server" (make-array FileAttribute 0)))
        state (protocol/make-state {:data-dir dir :test-functions? true
                                    :limits {:max-ingest-bytes 100000000 :max-table-rows 1000000
                                             :max-query-memory-mb 256 :max-join-rows 1000000}})
        srv (server/start! state (merge {:host "127.0.0.1" :port 0 :workers 2 :queue-depth 1
                                         :query-timeout-ms 0 :shutdown-grace-ms 1000
                                         :max-request-bytes 100000}
                                        opts))]
    (try
      (binding [*base* (str "http://127.0.0.1:" (:port srv))]
        (f srv))
      (finally (server/stop! srv)))))

(deftest http-endpoints
  (with-server {}
    (fn [_]
      (is (= [200 {"status" "ok"}] (take 2 (http-json "GET" "/health"))))
      (is (= 201 (first (http-json "PUT" "/v1/tables/t?format=csv" "a,b\n1,x\n2,y\n3,z\n"))))
      (is (= [409 "ALREADY_EXISTS"]
             (let [[s b] (http-json "PUT" "/v1/tables/t?format=csv" "a\n1\n")] [s (get-in b ["error" "code"])])))
      (let [[status body headers] (http-json "POST" "/v1/query" {"sql" "SELECT a, b FROM t ORDER BY a DESC"
                                                                "options" {"query_id" "abc"}})]
        (is (= 200 status))
        (is (= [[3 "z"] [2 "y"] [1 "x"]] (get body "rows")))
        (is (= ["abc"] (vec (get headers "x-polyquery-query-id")))))
      (doseq [[sql status code] [["SELEC 1" 400 "PARSE_ERROR"] ["SELECT 1/0" 400 "DIVISION_BY_ZERO"]
                                 ["SELECT * FROM nope" 400 "SEMANTIC_ERROR"]]]
        (let [[s b] (http-json "POST" "/v1/query" {"sql" sql})]
          (is (= [status code] [s (get-in b ["error" "code"])]) sql)))
      (is (= 400 (first (http-json "POST" "/v1/query" "{oops"))))
      (is (= 404 (first (http-json "GET" "/v1/nothing"))))
      (is (= 405 (first (http-json "DELETE" "/v1/query"))))
      (is (= 413 (first (http-json "PUT" "/v1/tables/big?format=csv" (apply str "a\n" (repeat 60000 "1\n"))))))
      (is (= [200 3] (let [[s b] (http-json "GET" "/v1/tables/t/schema")] [s (get b "row_count")])))
      (is (= 200 (first (http-json "GET" "/v1/tables/t/stats"))))
      (is (= [200 true] (let [[s b] (http-json "POST" "/v1/request" {"op" "tables" "id" 9})]
                          [s (= 9 (get b "id"))])))
      (is (= 403 (first (http-json "POST" "/v1/request" {"op" "load" "table" "x" "format" "csv"
                                                          "path" "../x"}))))
      (let [[status _ text] (http "GET" "/metrics")]
        (is (= 200 status))
        (is (str/includes? text "polyquery_tables 1\n")))
      (is (= 200 (first (http-json "DELETE" "/v1/tables/t"))))
      (is (= 404 (first (http-json "GET" "/v1/tables/t/schema")))))))

(deftest streaming
  (with-server {}
    (fn [_]
      (http-json "PUT" "/v1/tables/n?format=csv" (str "n\n" (str/join "\n" (range 2500)) "\n"))
      (let [[status headers text] (http "POST" "/v1/query/stream" (json/write-str {"sql" "SELECT n FROM n"}))
            lines (mapv json/read-str (str/split-lines text))]
        (is (= 200 status))
        (is (str/includes? (first (get headers "content-type")) "ndjson"))
        (is (= {"type" "header" "columns" [{"name" "n" "type" "INT64"}]}
               (dissoc (first lines) "query_id")))
        (is (= (range 2500) (map first (mapcat #(get % "rows") (filter #(= "rows" (get % "type")) lines)))))
        (is (= {"type" "end" "row_count" 2500} (peek lines))))
      (testing "runtime errors after the header end the stream with an error line"
        (let [[_ _ text] (http "POST" "/v1/query/stream"
                               (json/write-str {"sql" "SELECT 10 / (n - 2000) FROM n"}))
              lines (mapv json/read-str (str/split-lines text))]
          (is (= "DIVISION_BY_ZERO" (get-in (peek lines) ["error" "code"])))))
      (testing "errors before the header are plain error responses"
        (is (= 400 (first (http-json "POST" "/v1/query/stream" {"sql" "SELECT x FROM n"}))))))))

(deftest admission-timeouts-and-cancellation
  (with-server {:workers 1 :queue-depth 1}
    (fn [_]
      (let [slow (future (http-json "POST" "/v1/query" {"sql" "SELECT PQ_SLEEP(1500)"
                                                        "options" {"query_id" "slow"}}))
            _ (Thread/sleep 200)
            queued (future (http-json "POST" "/v1/query" {"sql" "SELECT 1" "options" {"query_id" "q2"}}))
            _ (Thread/sleep 200)]
        (is (= ["slow" "q2"] (mapv #(get % "query_id") (get (second (http-json "GET" "/v1/queries")) "queries"))))
        (is (= [503 "OVERLOADED"] (let [[s b] (http-json "POST" "/v1/query" {"sql" "SELECT 1"})]
                                    [s (get-in b ["error" "code"])])))
        (is (= [409 "ALREADY_EXISTS"]
               (let [[s b] (http-json "POST" "/v1/query" {"sql" "SELECT 1" "options" {"query_id" "slow"}})]
                 [s (get-in b ["error" "code"])])))
        (is (= 200 (first (http-json "DELETE" "/v1/queries/q2"))))
        (is (= [409 "CANCELLED"] (let [[s b] (deref queued 2000 nil)] [s (get-in b ["error" "code"])])))
        (is (= 200 (first (http-json "DELETE" "/v1/queries/slow"))))
        (is (= 409 (first (deref slow 2000 nil))))
        (is (= 404 (first (http-json "DELETE" "/v1/queries/slow")))))
      (let [[s b] (http-json "POST" "/v1/query" {"sql" "SELECT PQ_SLEEP(3000)" "options" {"timeout_ms" 100}})]
        (is (= [504 "TIMEOUT"] [s (get-in b ["error" "code"])]))))))

(deftest keep-alive-and-disconnect
  (with-server {}
    (fn [srv]
      (with-open [sock (Socket. "127.0.0.1" (int (:port srv)))]
        (let [out (.getOutputStream sock)
              in (BufferedReader. (InputStreamReader. (.getInputStream sock) StandardCharsets/UTF_8))]
          (dotimes [_ 3]
            (.write out (.getBytes "GET /health HTTP/1.1\r\nHost: x\r\n\r\n" StandardCharsets/UTF_8))
            (.flush out)
            (is (= "HTTP/1.1 200 OK" (.readLine in)))
            (let [len (loop [len 0]
                        (let [l (.readLine in)]
                          (cond (= "" l) len
                                (str/starts-with? (str/lower-case l) "content-length:")
                                (recur (parse-long (str/trim (subs l 15))))
                                :else (recur len))))]
              (dotimes [_ len] (.read in))))))
      (testing "a client disconnect cancels its query"
        (let [sock (Socket. "127.0.0.1" (int (:port srv)))
              body (json/write-str {"sql" "SELECT PQ_SLEEP(10000)" "options" {"query_id" "gone"}})]
          (.write (.getOutputStream sock)
                  (.getBytes (str "POST /v1/query HTTP/1.1\r\nHost: x\r\nContent-Length: " (count body)
                                  "\r\n\r\n" body)
                             StandardCharsets/UTF_8))
          (Thread/sleep 300)
          (.close sock)
          (Thread/sleep 300)
          (is (empty? (get (second (http-json "GET" "/v1/queries")) "queries"))))))))
