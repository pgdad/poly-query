(ns polyquery.server.http
  "Minimal HTTP/1.1 wire protocol over blocking sockets
  (spec/protocol/protocol.md §7): request parsing (Content-Length and chunked
  bodies, body size limit, `Expect: 100-continue`, keep-alive), fixed-length
  and chunked responses, and detection of client disconnects while a request
  is being processed."
  (:require [clojure.string :as str])
  (:import (java.io BufferedInputStream BufferedOutputStream ByteArrayOutputStream IOException
                    InputStream OutputStream PushbackInputStream)
           (java.net Socket SocketTimeoutException URLDecoder)
           (java.nio.charset StandardCharsets)))

(set! *warn-on-reflection* true)

(def ^:private ^:const max-line-bytes 16384)
(def ^:private ^:const max-header-count 128)

(def ^:private ^:const max-discard-bytes
  "An oversized body up to this size is read and discarded so that the
  connection can be kept; larger ones close the connection."
  (* 64 1024 1024))

;; ---------------------------------------------------------------------------
;; Connections

(defrecord Conn [^Socket socket ^PushbackInputStream in ^OutputStream out peeked])

(defn make-conn
  "Wraps an accepted socket."
  [^Socket socket]
  (.setTcpNoDelay socket true)
  (->Conn socket
          (PushbackInputStream. (BufferedInputStream. (.getInputStream socket) 65536) 1)
          (BufferedOutputStream. (.getOutputStream socket) 65536)
          (volatile! false)))

(defn close! [^Conn conn]
  (try (.close ^Socket (:socket conn)) (catch IOException _ nil)))

(defn client-gone?
  "True if the client closed (or reset) its side of the connection. Peeks at
  most one byte with a 1 ms timeout; once the client has sent further data
  (a pipelined request) disconnects can no longer be observed this way."
  [^Conn conn]
  (if @(:peeked conn)
    false
    (let [^Socket socket (:socket conn)
          ^PushbackInputStream in (:in conn)]
      (try
        (.setSoTimeout socket 1)
        (let [b (.read in)]
          (if (neg? b)
            true
            (do (.unread in b)
                (vreset! (:peeked conn) true)
                false)))
        (catch SocketTimeoutException _ false)
        (catch IOException _ true)
        (finally
          (try (.setSoTimeout socket 0) (catch IOException _ nil)))))))

;; ---------------------------------------------------------------------------
;; Request parsing

(defn- bad-request [msg]
  (throw (ex-info msg {::bad-request true})))

(defn- read-line-bytes
  "Reads one CRLF/LF-terminated line (ISO-8859-1) without its terminator;
  nil at EOF before any byte."
  [^InputStream in]
  (let [buf (ByteArrayOutputStream. 128)]
    (loop [n 0]
      (let [b (.read in)]
        (cond
          (neg? b) (if (zero? n) nil (bad-request "unexpected end of request"))
          (= b 10) (let [s (.toString buf StandardCharsets/ISO_8859_1)]
                     (if (str/ends-with? s "\r") (subs s 0 (dec (count s))) s))
          (>= n max-line-bytes) (bad-request "request line or header too long")
          :else (do (.write buf b) (recur (inc n))))))))

(defn- read-headers [^InputStream in]
  (loop [headers {} n 0]
    (let [line (or (read-line-bytes in) (bad-request "unexpected end of headers"))]
      (cond
        (= "" line) headers
        (>= n max-header-count) (bad-request "too many headers")
        :else
        (let [i (str/index-of line ":")]
          (when (or (nil? i) (zero? (long i))) (bad-request "malformed header line"))
          (let [k (str/lower-case (str/trim (subs line 0 i)))
                v (str/trim (subs line (inc (long i))))]
            (recur (update headers k #(if % (str % ", " v) v)) (inc n))))))))

(defn- decode-component [^String s plus-is-space?]
  (try
    (URLDecoder/decode (if plus-is-space? s (str/replace s "+" "%2B")) StandardCharsets/UTF_8)
    (catch IllegalArgumentException _ (bad-request "malformed percent-encoding in URL"))))

(defn- parse-target
  "Splits a request target into decoded path segments and query parameters."
  [^String target]
  (let [target (if-let [[_ rest] (re-matches #"(?i)https?://[^/]*(/.*)?" target)]
                 (or rest "/")
                 target)
        [path query] (str/split target #"\?" 2)
        segments (into [] (comp (remove str/blank?) (map #(decode-component % false)))
                       (str/split path #"/"))
        params (into {} (for [kv (str/split (or query "") #"&")
                              :when (not (str/blank? kv))
                              :let [[k v] (str/split kv #"=" 2)]]
                          [(decode-component k true) (decode-component (or v "") true)]))]
    {:path path :segments segments :params params}))

(defn- send-continue! [^Conn conn]
  (let [^OutputStream out (:out conn)]
    (.write out (.getBytes "HTTP/1.1 100 Continue\r\n\r\n" StandardCharsets/ISO_8859_1))
    (.flush out)))

(defn- too-large [close?]
  {:error {:status 413 :code "RESOURCE_LIMIT" :message "request body exceeds --max-request-bytes"}
   :close? close?})

(defn- read-chunked-body
  [conn ^InputStream in ^long max-bytes]
  (let [buf (ByteArrayOutputStream.)]
    (loop [total 0]
      (let [line (or (read-line-bytes in) (bad-request "unexpected end of chunked body"))
            size (long (try (Long/parseLong (str/trim (first (str/split line #";" 2))) 16)
                            (catch NumberFormatException _ (bad-request "malformed chunk size"))))
            total (+ total size)]
        (when (neg? size) (bad-request "malformed chunk size"))
        (if (zero? size)
          (do (loop [] (when (seq (or (read-line-bytes in) "")) (recur)))   ; trailers
              (if (> total max-bytes) (too-large false) {:body (.toByteArray buf)}))
          (do (when (> total (+ max-bytes max-discard-bytes))
                (throw (ex-info "oversized chunked body" {::oversized true})))
              (if (<= total max-bytes)
                (let [chunk (.readNBytes in (int size))]
                  (when (< (alength chunk) size) (bad-request "unexpected end of chunked body"))
                  (.write buf chunk))
                (.skipNBytes in size))
              (read-line-bytes in)
              (recur total)))))))

(defn- read-body
  "Reads the request body: {:body bytes} or {:error … :close? bool}."
  [conn headers ^long max-bytes]
  (let [^InputStream in (:in conn)
        te (get headers "transfer-encoding")
        cl (get headers "content-length")
        continue? (= "100-continue" (some-> (get headers "expect") str/lower-case))]
    (cond
      (and te (str/includes? (str/lower-case te) "chunked"))
      (do (when continue? (send-continue! conn))
          (try (read-chunked-body conn in max-bytes)
               (catch clojure.lang.ExceptionInfo e
                 (if (::oversized (ex-data e)) (too-large true) (throw e)))))

      cl
      (let [n (long (or (parse-long cl) -1))]
        (cond
          (neg? n) (bad-request "malformed Content-Length")
          (> n max-bytes) (cond
                            continue? (too-large true)
                            (<= n max-discard-bytes) (do (.skipNBytes in n) (too-large false))
                            :else (too-large true))
          :else (do (when continue? (send-continue! conn))
                    (let [body (.readNBytes in (int n))]
                      (when (< (alength body) n) (bad-request "unexpected end of request body"))
                      {:body body}))))

      :else {:body (byte-array 0)})))

(defn read-request
  "Reads the next request from the connection; nil when the client closed
  the connection between requests. Returns {:method :path :segments :params
  :headers :body :keep-alive?}, or {:error {:status :code :message} :close?
  :keep-alive?} for malformed or oversized requests. max-body-bytes limits
  the body size."
  [conn ^long max-body-bytes]
  (vreset! (:peeked conn) false)
  (let [^InputStream in (:in conn)]
    (try
      (when-let [line (loop [] (let [l (read-line-bytes in)] (if (= "" l) (recur) l)))]
        (let [[method target version :as parts] (str/split line #" ")
              _ (when-not (and (= 3 (count parts)) (re-matches #"[A-Z]+" method)
                               (re-matches #"HTTP/1\.[0-9]" version))
                  (bad-request "malformed request line"))
              headers (read-headers in)
              connection (str/lower-case (get headers "connection" ""))
              keep-alive? (if (= version "HTTP/1.0")
                            (str/includes? connection "keep-alive")
                            (not (str/includes? connection "close")))
              body (read-body conn headers (min max-body-bytes (- Integer/MAX_VALUE 16)))]
          (merge {:method method :headers headers :keep-alive? (and keep-alive? (not (:close? body)))}
                 (parse-target target)
                 body)))
      (catch clojure.lang.ExceptionInfo e
        (if (::bad-request (ex-data e))
          {:error {:status 400 :code "INVALID_REQUEST" :message (.getMessage e)}
           :close? true :keep-alive? false}
          (throw e))))))

;; ---------------------------------------------------------------------------
;; Responses

(def ^:private reasons
  {100 "Continue" 200 "OK" 201 "Created" 400 "Bad Request" 403 "Forbidden" 404 "Not Found"
   405 "Method Not Allowed" 409 "Conflict" 413 "Payload Too Large" 500 "Internal Server Error"
   503 "Service Unavailable" 504 "Gateway Timeout"})

(defn- write-head! [^Conn conn ^long status headers]
  (let [sb (StringBuilder.)]
    (.append sb "HTTP/1.1 ")
    (.append sb status)
    (.append sb " ")
    (.append sb (str (get reasons status "Status")))
    (.append sb "\r\n")
    (doseq [[k v] headers]
      (.append sb (str k))
      (.append sb ": ")
      (.append sb (str v))
      (.append sb "\r\n"))
    (.append sb "\r\n")
    (.write ^OutputStream (:out conn) (.getBytes (.toString sb) StandardCharsets/UTF_8))))

(defn write-response!
  "Writes a complete response with a Content-Length body and flushes."
  [conn status headers ^bytes body]
  (write-head! conn status (assoc headers "Content-Length" (alength body)))
  (let [^OutputStream out (:out conn)]
    (.write out body)
    (.flush out)))

(defn start-chunked!
  "Writes the head of a chunked (streamed) response."
  [conn status headers]
  (write-head! conn status (assoc headers "Transfer-Encoding" "chunked")))

(defn write-chunk!
  "Writes one chunk and flushes it to the client."
  [conn ^bytes data]
  (when (pos? (alength data))
    (let [^OutputStream out (:out conn)]
      (.write out (.getBytes (str (Integer/toHexString (alength data)) "\r\n") StandardCharsets/ISO_8859_1))
      (.write out data)
      (.write out (.getBytes "\r\n" StandardCharsets/ISO_8859_1))
      (.flush out))))

(defn end-chunked!
  "Writes the terminating chunk of a chunked response."
  [conn]
  (let [^OutputStream out (:out conn)]
    (.write out (.getBytes "0\r\n\r\n" StandardCharsets/ISO_8859_1))
    (.flush out)))
