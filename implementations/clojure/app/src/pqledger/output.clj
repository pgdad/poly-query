(ns pqledger.output
  "Printing results in the table, csv and json formats
  (spec/apps/pqledger.md §7). A result is a map with :columns [{:name
  :type} …] (canonical engine type names) and :rows (vectors of the native
  values of polyquery.api)."
  (:require [clojure.string :as str]
            [pqledger.text :as text])
  (:import (java.math BigDecimal RoundingMode)
           (java.time LocalDate LocalDateTime)))

(set! *warn-on-reflection* true)

(defn- numeric-type? [^String typ]
  (or (= typ "INT64") (= typ "FLOAT64") (str/starts-with? typ "DECIMAL")))

(defn- pad2 [^long n] (if (< n 10) (str "0" n) (str n)))

(defn- timestamp-text
  "YYYY-MM-DD HH:MM:SS[.ffffff] (types.md §9)."
  ^String [^LocalDateTime t]
  (let [micros (quot (.getNano t) 1000)]
    (str (.toLocalDate t) " " (pad2 (.getHour t)) ":" (pad2 (.getMinute t)) ":" (pad2 (.getSecond t))
         (when (pos? micros) (str "." (subs (str (+ 1000000 micros)) 1))))))

(defn float-text
  "A FLOAT64 rounded to 6 fractional digits like C printf(\"%.6f\") (the
  exact binary value, ties to even), without a negative zero."
  ^String [^double d]
  (let [s (.toPlainString (.setScale (BigDecimal. d) 6 RoundingMode/HALF_EVEN))]
    (if (= s "-0.000000") "0.000000" s)))

(defn value-text
  "The value text of a native value of engine type typ (nil for NULL)."
  ^String [^String typ v]
  (cond
    (nil? v) nil
    (instance? BigDecimal v) (.toPlainString ^BigDecimal v)
    (instance? Double v) (float-text v)
    (instance? LocalDate v) (str v)
    (instance? LocalDateTime v) (timestamp-text v)
    (boolean? v) (if v "true" "false")
    :else (str v)))

(defn- row-texts [{:keys [columns rows]}]
  (let [types (mapv :type columns)]
    (mapv (fn [row] (mapv value-text types row)) rows)))

;; ---------------------------------------------------------------------------
;; table

(defn- pad ^String [^String s ^long width right?]
  (let [fill (apply str (repeat (- width (text/code-points s)) \space))]
    (if right? (str fill s) (str s fill))))

(defn- strip-trailing ^String [^String s]
  (str/replace s #" +$" ""))

(defn format-table
  ^String [{:keys [columns] :as result}]
  (let [texts (row-texts result)
        names (mapv :name columns)
        right (mapv (comp numeric-type? :type) columns)
        widths (reduce (fn [ws row]
                         (mapv (fn [w t] (max (long w) (text/code-points (or t "")))) ws row))
                       (mapv text/code-points names)
                       texts)
        line (fn [cells]
               (strip-trailing (str/join "  " (map (fn [c w r?] (pad (or c "") w r?)) cells widths right))))
        n (count texts)
        sb (StringBuilder.)]
    (.append sb (line names)) (.append sb "\n")
    (.append sb (line (map #(apply str (repeat % \-)) widths))) (.append sb "\n")
    (doseq [row texts]
      (.append sb (line row)) (.append sb "\n"))
    (.append sb (if (= 1 n) "(1 row)" (str "(" n " rows)"))) (.append sb "\n")
    (.toString sb)))

;; ---------------------------------------------------------------------------
;; csv

(defn csv-field
  "A CSV field (nil: NULL, an empty unquoted field)."
  ^String [^String s]
  (cond
    (nil? s) ""
    (or (= "" s)
        (re-find #"[,\"\r\n]" s)
        (str/starts-with? s " ")
        (str/ends-with? s " "))
    (str "\"" (str/replace s "\"" "\"\"") "\"")
    :else s))

(defn format-csv
  ^String [{:keys [columns] :as result}]
  (let [sb (StringBuilder.)
        record (fn [fields] (.append sb (str/join "," (map csv-field fields))) (.append sb "\n"))]
    (record (map :name columns))
    (doseq [row (row-texts result)] (record row))
    (.toString sb)))

;; ---------------------------------------------------------------------------
;; json

(defn json-string
  ^String [^String s]
  (let [sb (StringBuilder. (+ 2 (.length s)))]
    (.append sb \")
    (dotimes [i (.length s)]
      (let [c (.charAt s i)]
        (case c
          \" (.append sb "\\\"")
          \\ (.append sb "\\\\")
          \backspace (.append sb "\\b")
          \tab (.append sb "\\t")
          \newline (.append sb "\\n")
          \formfeed (.append sb "\\f")
          \return (.append sb "\\r")
          (if (< (int c) 0x20)
            (.append sb (format "\\u%04x" (int c)))
            (.append sb c)))))
    (.append sb \")
    (.toString sb)))

(defn- json-value ^String [^String typ v]
  (cond
    (nil? v) "null"
    (boolean? v) (if v "true" "false")
    (or (= typ "INT64") (= typ "FLOAT64")) (value-text typ v)
    :else (json-string (value-text typ v))))

(defn format-json
  ^String [{:keys [columns rows]}]
  (let [sb (StringBuilder.)
        keys (mapv #(json-string (:name %)) columns)
        types (mapv :type columns)]
    (doseq [row rows]
      (.append sb "{")
      (dotimes [i (count keys)]
        (when (pos? i) (.append sb ","))
        (.append sb ^String (nth keys i))
        (.append sb ":")
        (.append sb (json-value (nth types i) (nth row i))))
      (.append sb "}\n"))
    (.toString sb)))

(defn format-result
  "The text of a result in format fmt (\"table\", \"csv\" or \"json\")."
  ^String [result fmt]
  (case fmt
    "table" (format-table result)
    "csv" (format-csv result)
    "json" (format-json result)))
