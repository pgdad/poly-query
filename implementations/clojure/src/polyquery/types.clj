(ns polyquery.types
  "SQL data types (spec/data-types/types.md §1-§2).

  A type is a keyword for the simple types (:boolean :int64 :float64 :string
  :date :timestamp, plus :null for the type of a bare NULL literal) or a vector
  [:decimal p s].

  Runtime value representation (nil is NULL for every type):
    :boolean   java.lang.Boolean
    :int64     Long
    :float64   Double (always finite)
    :decimal   Long holding the unscaled value (scale is static, from the type)
    :string    String
    :date      Long, days since 1970-01-01
    :timestamp Long, microseconds since 1970-01-01 00:00:00"
  (:require [polyquery.errors :as err]
            [polyquery.util.text :as text]))

(set! *warn-on-reflection* true)

(def max-decimal-precision 18)

(defn decimal [p s] [:decimal p s])

(defn kind
  "The type constructor: :decimal for decimal types, else the type itself."
  [t]
  (if (vector? t) :decimal t))

(defn decimal-type? [t] (vector? t))
(defn precision ^long [t] (long (nth t 1)))
(defn scale ^long [t] (if (vector? t) (long (nth t 2)) 0))

(defn numeric? [t] (contains? #{:int64 :float64 :decimal} (kind t)))
(defn temporal? [t] (contains? #{:date :timestamp} (kind t)))
(defn null-type? [t] (= t :null))

(defn type-name
  "Canonical type name. The null type is reported as STRING."
  ^String [t]
  (case (kind t)
    :boolean "BOOLEAN"
    :int64 "INT64"
    :float64 "FLOAT64"
    :decimal (str "DECIMAL(" (precision t) "," (scale t) ")")
    :string "STRING"
    :date "DATE"
    :timestamp "TIMESTAMP"
    :null "STRING"))

(def ^:private simple-aliases
  {"BOOLEAN" :boolean "BOOL" :boolean
   "INT64" :int64 "INT" :int64 "INTEGER" :int64 "BIGINT" :int64
   "FLOAT64" :float64 "DOUBLE" :float64 "FLOAT" :float64 "REAL" :float64
   "STRING" :string "VARCHAR" :string "TEXT" :string
   "DATE" :date "TIMESTAMP" :timestamp})

(defn resolve-type
  "Resolves a type name with optional numeric parameters (a vector of 0-2
  longs) to a type, or throws `error-code` for unknown names / invalid
  parameters."
  [^String tname params error-code]
  (let [u (text/ascii-upper tname)]
    (cond
      (contains? #{"DECIMAL" "NUMERIC"} u)
      (let [[p s] (case (count params)
                    0 [18 0]
                    1 [(first params) 0]
                    2 params
                    (err/fail! error-code (str "invalid parameters for " u)))]
        (when-not (and (<= 1 p max-decimal-precision) (<= 0 s p))
          (err/fail! error-code (str "invalid DECIMAL parameters (" p "," s ")")))
        (decimal p s))

      (contains? simple-aliases u)
      (if (seq params)
        (err/fail! error-code (str "type " u " takes no parameters"))
        (simple-aliases u))

      :else (err/fail! error-code (str "unknown type '" tname "'")))))

(defn parse-type-string
  "Parses a type string as used in explicit schemas, e.g. \"DECIMAL(10, 2)\"."
  [^String s error-code]
  (let [m (re-matches #"(?s)\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:\(\s*([0-9]+)\s*(?:,\s*([0-9]+)\s*)?\))?\s*" s)]
    (when-not m (err/fail! error-code (str "invalid type '" s "'")))
    (let [[_ nm p sc] m
          parse (fn [x] (try (Long/parseLong x)
                             (catch NumberFormatException _
                               (err/fail! error-code (str "invalid type '" s "'")))))
          params (cond-> [] p (conj (parse p)) sc (conj (parse sc)))]
      (resolve-type nm params error-code))))

(defn common-numeric-type
  "Common type of two numeric types for comparison/CASE (types.md §2)."
  [a b]
  (let [ka (kind a) kb (kind b)]
    (cond
      (or (= ka :float64) (= kb :float64)) :float64
      (and (= ka :int64) (= kb :int64)) :int64
      :else (decimal max-decimal-precision (max (scale a) (scale b))))))

(defn common-type
  "Common supertype of two types for CASE/COALESCE-like constructs, or nil if
  the types are incompatible. :null is compatible with everything."
  [a b]
  (cond
    (= a :null) b
    (= b :null) a
    ;; numeric promotion (§2); two DECIMALs always give DECIMAL(18,max(s1,s2))
    ;; (semantics.md §13)
    (and (numeric? a) (numeric? b)) (common-numeric-type a b)
    (= a b) a
    :else nil))

(defn comparable?
  [a b]
  (or (= a :null) (= b :null)
      (and (numeric? a) (numeric? b))
      (and (temporal? a) (temporal? b))
      (= (kind a) (kind b))))

(defn comparison-type
  "Type in which two comparable operands are compared."
  [lt rt]
  (cond
    (= lt :null) rt
    (= rt :null) lt
    (and (numeric? lt) (numeric? rt)) (if (= lt rt) lt (common-numeric-type lt rt))
    (and (temporal? lt) (temporal? rt)) (if (= lt rt) lt :timestamp)
    :else lt))

(defn describe [t] (if (= t :null) "NULL" (type-name t)))
