(ns polyquery.server.metrics
  "Server metrics and their Prometheus text exposition, format 0.0.4
  (spec/protocol/protocol.md §7.3)."
  (:require [clojure.string :as str])
  (:import (java.util Locale)
           (java.util.concurrent.atomic AtomicLong)))

(set! *warn-on-reflection* true)

(defn make-metrics []
  {:started-ns (System/nanoTime)
   :ok (AtomicLong.)
   :error (AtomicLong.)
   :rejected (AtomicLong.)
   :cancelled (AtomicLong.)
   :timeout (AtomicLong.)
   :duration-count (AtomicLong.)
   :duration-sum-ns (AtomicLong.)})

(defn- inc! [m k] (.incrementAndGet ^AtomicLong (get m k)))

(defn record-query!
  "Counts a finished query. error-code is nil for success."
  [m error-code ^long duration-ns]
  (inc! m (if error-code :error :ok))
  (case error-code
    "OVERLOADED" (inc! m :rejected)
    "CANCELLED" (inc! m :cancelled)
    "TIMEOUT" (inc! m :timeout)
    nil)
  (when-not (= "OVERLOADED" error-code)
    (inc! m :duration-count)
    (.addAndGet ^AtomicLong (:duration-sum-ns m) duration-ns)))

(defn- fixed
  "Locale-independent fixed-point formatting."
  [^long digits ^double x]
  (String/format Locale/ROOT (str "%." digits "f") (object-array [x])))

(defn- value [m k] (.get ^AtomicLong (get m k)))

(defn render
  "Prometheus text for the metrics plus the gauges {:in-flight :queued
  :tables}."
  ^String [m {:keys [in-flight queued tables]}]
  (let [family (fn [name type help & samples]
                 (str "# HELP " name " " help "\n# TYPE " name " " type "\n"
                      (str/join (map (fn [[suffix v]] (str name suffix " " v "\n")) samples))))]
    (str
     (family "polyquery_queries_total" "counter" "Finished queries by status."
             ["{status=\"ok\"}" (value m :ok)] ["{status=\"error\"}" (value m :error)])
     (family "polyquery_queries_in_flight" "gauge" "Queries currently executing." ["" in-flight])
     (family "polyquery_queries_queued" "gauge" "Queries waiting for a worker." ["" queued])
     (family "polyquery_queries_rejected_total" "counter" "Queries rejected with OVERLOADED."
             ["" (value m :rejected)])
     (family "polyquery_queries_cancelled_total" "counter" "Cancelled queries." ["" (value m :cancelled)])
     (family "polyquery_queries_timeout_total" "counter" "Queries that timed out." ["" (value m :timeout)])
     (family "polyquery_query_duration_seconds" "summary" "Query duration (queueing included)."
             ["_sum" (fixed 6 (/ (value m :duration-sum-ns) 1e9))]
             ["_count" (value m :duration-count)])
     (family "polyquery_tables" "gauge" "Tables in the catalog." ["" tables])
     (family "polyquery_uptime_seconds" "gauge" "Seconds since the server started."
             ["" (fixed 3 (/ (- (System/nanoTime) (long (:started-ns m))) 1e9))]))))
