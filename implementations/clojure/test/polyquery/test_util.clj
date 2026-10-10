(ns polyquery.test-util
  (:require [polyquery.catalog :as catalog]
            [polyquery.errors :as err]
            [polyquery.ingest.csv :as csv])
  (:import (java.io StringReader)))

(defmacro error-code
  "Evaluates body and returns the engine error code it throws (or :no-error)."
  [& body]
  `(try ~@body :no-error
        (catch clojure.lang.ExceptionInfo e# (or (err/error-code e#) (throw e#)))))

(defn csv-catalog
  "Builds a catalog from {table-name csv-text} (types inferred)."
  [tables]
  (reduce (fn [cat [tname text]]
            (catalog/add-table cat
                               (csv/load-csv (StringReader. text)
                                             {:name tname :header? true :delimiter \,
                                              :limits {:max-table-rows 1000}})
                               false))
          catalog/empty-catalog
          tables))
