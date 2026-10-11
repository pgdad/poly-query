(ns polyquery.util.json
  "Strict RFC 8259 JSON reader and a single-line JSON writer.

  The reader is configurable so that the protocol layer gets plain Clojure
  values while ingestion can keep number literal texts and detect duplicate
  object keys."
  (:import (java.io OutputStream)
           (java.nio.charset StandardCharsets)))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Reader

(deftype JsonNumber [^String text integral?]
  Object
  (toString [_] text))

(defn json-number? [x] (instance? JsonNumber x))

(defn- syntax-error [^String msg pos]
  (throw (ex-info msg {::syntax-error true :pos pos})))

(defn syntax-error?
  [t]
  (boolean (::syntax-error (ex-data t))))

(defn- default-number
  [^String text integral?]
  (if integral?
    (let [bi (java.math.BigInteger. text)]
      (if (< (.bitLength bi) 64) (.longValue bi) bi))
    (Double/parseDouble text)))

(defn- default-object
  [pairs]
  (persistent!
   (reduce (fn [m [k v]] (assoc! m k v)) (transient {}) pairs)))

(declare read-value)

(defn- skip-ws ^long [^String s ^long i]
  (let [n (.length s)]
    (loop [i i]
      (if (< i n)
        (let [c (.charAt s i)]
          (if (or (= c \space) (= c \tab) (= c \newline) (= c \return))
            (recur (inc i))
            i))
        i))))

(defn- hex-val ^long [^String s ^long i]
  (let [d (Character/digit (.charAt s i) 16)]
    (when (neg? d) (syntax-error "invalid \\u escape" i))
    d))

(defn- read-string-lit
  "Reads a string starting at the opening quote at i. Returns [string next-pos]."
  [^String s ^long i]
  (let [n (.length s)
        sb (StringBuilder.)]
    (loop [j (inc i)]
      (when (>= j n) (syntax-error "unterminated string" i))
      (let [c (.charAt s j)]
        (cond
          (= c \") [(.toString sb) (inc j)]
          (= c \\)
          (do (when (>= (inc j) n) (syntax-error "unterminated string" i))
              (let [e (.charAt s (inc j))]
                (case e
                  \" (do (.append sb \") (recur (+ j 2)))
                  \\ (do (.append sb \\) (recur (+ j 2)))
                  \/ (do (.append sb \/) (recur (+ j 2)))
                  \b (do (.append sb \backspace) (recur (+ j 2)))
                  \f (do (.append sb \formfeed) (recur (+ j 2)))
                  \n (do (.append sb \newline) (recur (+ j 2)))
                  \r (do (.append sb \return) (recur (+ j 2)))
                  \t (do (.append sb \tab) (recur (+ j 2)))
                  \u (do (when (> (+ j 6) n) (syntax-error "invalid \\u escape" j))
                         (let [v (+ (bit-shift-left (hex-val s (+ j 2)) 12)
                                    (bit-shift-left (hex-val s (+ j 3)) 8)
                                    (bit-shift-left (hex-val s (+ j 4)) 4)
                                    (hex-val s (+ j 5)))]
                           (.append sb (char v))
                           (recur (+ j 6))))
                  (syntax-error "invalid escape" j))))
          (< (int c) 0x20) (syntax-error "control character in string" j)
          :else (do (.append sb c) (recur (inc j))))))))

(defn- digit? [c] (and c (<= (int \0) (int c) (int \9))))

(defn- read-number
  [^String s ^long i number-fn]
  (let [n (.length s)
        ch (fn [^long k] (when (< k n) (.charAt s k)))
        digits-end (fn ^long [^long k] (loop [k k] (if (digit? (ch k)) (recur (inc k)) k)))
        j (if (= (ch i) \-) (inc i) i)
        _ (when-not (digit? (ch j)) (syntax-error "invalid number" i))
        k (if (= (ch j) \0) (inc j) (digits-end j))
        _ (when (digit? (ch k)) (syntax-error "leading zeros are not allowed" i))
        [k frac?] (if (= (ch k) \.)
                    (let [k2 (digits-end (inc k))]
                      (when (= k2 (inc k)) (syntax-error "invalid number" i))
                      [k2 true])
                    [k false])
        [k exp?] (if (or (= (ch k) \e) (= (ch k) \E))
                   (let [k1 (if (or (= (ch (inc k)) \+) (= (ch (inc k)) \-)) (+ k 2) (inc k))
                         k2 (digits-end k1)]
                     (when (= k2 k1) (syntax-error "invalid number" i))
                     [k2 true])
                   [k false])]
    [(number-fn (.substring s i k) (not (or frac? exp?))) k]))

(defn- expect-literal [^String s ^long i ^String lit v]
  (if (.startsWith s lit i)
    [v (+ i (.length lit))]
    (syntax-error "invalid literal" i)))

(defn- read-value
  [^String s i0 number-fn object-fn depth]
  (when (> (long depth) 512) (syntax-error "nesting too deep" i0))
  (let [i (skip-ws s (long i0))
        n (.length s)]
    (when (>= i n) (syntax-error "unexpected end of input" i))
    (let [c (.charAt s i)]
      (case c
        \{ (let [i (skip-ws s (inc i))]
             (if (and (< i n) (= (.charAt s i) \}))
               [(object-fn []) (inc i)]
               (loop [i i pairs (transient [])]
                 (let [i (skip-ws s i)]
                   (when-not (and (< i n) (= (.charAt s i) \")) (syntax-error "expected object key" i))
                   (let [[k i] (read-string-lit s i)
                         i (skip-ws s i)
                         _ (when-not (and (< i n) (= (.charAt s i) \:)) (syntax-error "expected ':'" i))
                         [v i] (read-value s (inc i) number-fn object-fn (inc depth))
                         i (skip-ws s i)
                         pairs (conj! pairs [k v])]
                     (cond
                       (>= i n) (syntax-error "unterminated object" i)
                       (= (.charAt s i) \,) (recur (inc i) pairs)
                       (= (.charAt s i) \}) [(object-fn (persistent! pairs)) (inc i)]
                       :else (syntax-error "expected ',' or '}'" i)))))))
        \[ (let [i (skip-ws s (inc i))]
             (if (and (< i n) (= (.charAt s i) \]))
               [[] (inc i)]
               (loop [i i items (transient [])]
                 (let [[v i] (read-value s i number-fn object-fn (inc depth))
                       i (skip-ws s i)
                       items (conj! items v)]
                   (cond
                     (>= i n) (syntax-error "unterminated array" i)
                     (= (.charAt s i) \,) (recur (inc i) items)
                     (= (.charAt s i) \]) [(persistent! items) (inc i)]
                     :else (syntax-error "expected ',' or ']'" i))))))
        \" (read-string-lit s i)
        \t (expect-literal s i "true" true)
        \f (expect-literal s i "false" false)
        \n (expect-literal s i "null" nil)
        (if (or (= c \-) (digit? c))
          (read-number s i number-fn)
          (syntax-error (str "unexpected character '" c "'") i))))))

(defn read-str
  "Parses a complete JSON text. Options:
  :number-fn (fn [text integral?]) — default: Long/BigInteger/Double
  :object-fn (fn [pairs]) — pairs is a vector of [key value]; default: map
  Throws ex-info (see `syntax-error?`) on malformed input."
  ([s] (read-str s {}))
  ([^String s {:keys [number-fn object-fn]
               :or {number-fn default-number object-fn default-object}}]
   (let [[v i] (read-value s 0 number-fn object-fn 0)
         i (skip-ws s i)]
     (when (< i (.length s)) (syntax-error "trailing characters after JSON value" i))
     v)))

(defn ingest-number
  "number-fn for ingestion: keeps the literal text."
  [text integral?]
  (JsonNumber. text integral?))

;; ---------------------------------------------------------------------------
;; Writer

(deftype RawJson [^CharSequence text]
  Object
  (toString [_] (str text)))

(defn raw
  "A value written verbatim by the writer: text must be valid JSON."
  [^CharSequence text]
  (RawJson. text))

(defn- plain-string?
  "True when s needs no escaping: no quote, backslash, control character or
  surrogate."
  [^String s]
  (let [n (.length s)]
    (loop [i 0]
      (if (< i n)
        (let [c (int (.charAt s i))]
          (if (or (< c 0x20) (== c 0x22) (== c 0x5c) (and (>= c 0xd800) (<= c 0xdfff)))
            false
            (recur (inc i))))
        true))))

(declare write-escaped)

(defn write-string
  [^StringBuilder sb ^String s]
  (.append sb \")
  (if (plain-string? s)
    (.append sb s)
    (write-escaped sb s))
  (.append sb \"))

(defn- write-escaped
  [^StringBuilder sb ^String s]
  (let [n (.length s)]
    (loop [i 0]
      (when (< i n)
        (let [c (.charAt s i)
              ci (int c)]
          (cond
            (= c \") (.append sb "\\\"")
            (= c \\) (.append sb "\\\\")
            (= c \newline) (.append sb "\\n")
            (= c \return) (.append sb "\\r")
            (= c \tab) (.append sb "\\t")
            (< ci 0x20) (.append sb (format "\\u%04x" ci))
            ;; unpaired surrogates cannot be encoded as UTF-8: escape them
            (Character/isHighSurrogate c)
            (if (and (< (inc i) n) (Character/isLowSurrogate (.charAt s (inc i))))
              (.append sb c)
              (.append sb (format "\\u%04x" ci)))
            (Character/isLowSurrogate c)
            (if (and (pos? i) (Character/isHighSurrogate (.charAt s (dec i))))
              (.append sb c)
              (.append sb (format "\\u%04x" ci)))
            :else (.append sb c)))
        (recur (inc i))))))

(defn write-double
  [^StringBuilder sb ^double d]
  (cond
    (== d 0.0) (.append sb "0.0")
    (or (Double/isNaN d) (Double/isInfinite d)) (.append sb "null")
    :else (.append sb (Double/toString d))))

(defn write-value
  [^StringBuilder sb v]
  (cond
    (nil? v) (.append sb "null")
    (string? v) (write-string sb v)
    (instance? Boolean v) (.append sb (if v "true" "false"))
    (instance? Long v) (.append sb (long v))
    (instance? Double v) (write-double sb (double v))
    (instance? JsonNumber v) (.append sb (.-text ^JsonNumber v))
    (instance? RawJson v) (.append sb (.-text ^RawJson v))
    (integer? v) (.append sb (str v))
    (float? v) (write-double sb (double v))
    (decimal? v) (.append sb (.toPlainString ^java.math.BigDecimal v))
    (map? v) (do (.append sb \{)
                 (reduce-kv (fn [first? k val]
                              (when-not first? (.append sb \,))
                              (write-string sb (if (keyword? k) (name k) (str k)))
                              (.append sb \:)
                              (write-value sb val)
                              false)
                            true v)
                 (.append sb \}))
    (or (sequential? v) (.isArray (class v)))
    (do (.append sb \[)
        (reduce (fn [first? x]
                  (when-not first? (.append sb \,))
                  (write-value sb x)
                  false)
                true v)
        (.append sb \]))
    (keyword? v) (write-string sb (name v))
    :else (write-string sb (str v))))

(defn write-str
  "Serializes a value as single-line JSON."
  ^String [v]
  (let [sb (StringBuilder.)]
    (write-value sb v)
    (.toString sb)))

(defn write-line!
  "Writes v as one JSON line (UTF-8) and flushes."
  [^OutputStream out v]
  (let [sb (StringBuilder. 256)]
    (write-value sb v)
    (.append sb \newline)
    (.write out (.getBytes (.toString sb) StandardCharsets/UTF_8))
    (.flush out)))
