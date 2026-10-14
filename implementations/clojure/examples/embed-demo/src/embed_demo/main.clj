(ns embed-demo.main
  "pq-embed-demo DATA_DIR CSV_FILE SQL — loads CSV_FILE (relative to
  DATA_DIR, header row, inferred schema) as table t, runs SQL and prints
  the result as CSV. Uses only the public API, polyquery.api."
  (:require [clojure.string :as str]
            [polyquery.api :as pq])
  (:import (java.math BigDecimal RoundingMode)
           (java.time LocalDateTime))
  (:gen-class))

(defn- value-text
  "The text of a native result value (pqledger.md §7); nil for NULL."
  [v]
  (cond
    (nil? v) nil
    (instance? BigDecimal v) (.toPlainString ^BigDecimal v)
    (instance? Double v) (let [s (.toPlainString (.setScale (BigDecimal. (double v)) 6 RoundingMode/HALF_EVEN))]
                           (if (= s "-0.000000") "0.000000" s))
    (instance? LocalDateTime v) (let [^LocalDateTime t v
                                      micros (quot (.getNano t) 1000)]
                                  (str (.toLocalDate t) " " (format "%02d:%02d:%02d" (.getHour t) (.getMinute t)
                                                                   (.getSecond t))
                                       (when (pos? micros) (format ".%06d" micros))))
    :else (str v)))

(defn- csv-field [s]
  (cond
    (nil? s) ""
    (or (= "" s) (re-find #"[,\"\r\n]" s) (str/starts-with? s " ") (str/ends-with? s " "))
    (str "\"" (str/replace s "\"" "\"\"") "\"")
    :else s))

(defn- csv-line [values]
  (str (str/join "," (map csv-field values)) "\n"))

(defn -main [& args]
  (when-not (= 3 (count args))
    (binding [*out* *err*] (println "usage: pq-embed-demo DATA_DIR CSV_FILE SQL"))
    (System/exit 2))
  (let [[data-dir csv-file sql] args
        out (java.io.PrintStream. System/out false "UTF-8")
        status (try
                 (with-open [db (pq/create {:data-dir data-dir})]
                   (pq/load! db "t" {:path csv-file :header true})
                   (let [result (pq/query db sql)]
                     (.print out (csv-line (pq/column-names result)))
                     (doseq [row (pq/rows result)]
                       (.print out (csv-line (map value-text row))))
                     (.flush out)
                     0))
                 (catch clojure.lang.ExceptionInfo e
                   (if-let [code (pq/error-code e)]
                     (do (binding [*out* *err*] (println (str "error: " code ": " (ex-message e))))
                         1)
                     (throw e))))]
    (System/exit status)))
