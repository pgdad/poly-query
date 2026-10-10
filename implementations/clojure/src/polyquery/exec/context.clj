(ns polyquery.exec.context
  "Per-query execution context: deadline (timeout), cancellation flag and an
  approximate memory budget (spec/concurrency/concurrency.md §3-4,
  spec/sql/semantics.md §15)."
  (:require [polyquery.errors :as err])
  (:import (java.util.concurrent.atomic AtomicBoolean AtomicLong)))

(set! *warn-on-reflection* true)

(defrecord QueryContext [^long deadline-ns ^AtomicBoolean cancelled ^long memory-budget
                         ^AtomicLong memory-used])

(defn make-context
  "timeout-ms: 0 = none; memory-budget-bytes: per-query budget."
  [{:keys [timeout-ms memory-budget-bytes]}]
  (->QueryContext (if (and timeout-ms (pos? (long timeout-ms)))
                    (+ (System/nanoTime) (* 1000000 (long timeout-ms)))
                    0)
                  (AtomicBoolean. false)
                  (long (or memory-budget-bytes Long/MAX_VALUE))
                  (AtomicLong. 0)))

(defn cancel! [^QueryContext ctx] (.set ^AtomicBoolean (.-cancelled ctx) true))

(defn check!
  "Throws TIMEOUT / CANCELLED when the query must stop."
  [^QueryContext ctx]
  (when (.get ^AtomicBoolean (.-cancelled ctx))
    (err/fail! "CANCELLED" "query was cancelled"))
  (let [dl (.-deadline-ns ctx)]
    (when (and (pos? dl) (> (- (System/nanoTime) dl) 0))
      (err/fail! "TIMEOUT" "query exceeded its timeout"))))

(defn reserve!
  "Accounts `bytes` against the memory budget; RESOURCE_LIMIT when exceeded."
  [^QueryContext ctx ^long bytes]
  (let [used (.addAndGet ^AtomicLong (.-memory-used ctx) bytes)]
    (when (> used (.-memory-budget ctx))
      (err/fail! "RESOURCE_LIMIT" "query exceeded its memory budget"))))

(defn sleep!
  "Sleeps ms milliseconds in small slices, observing timeout/cancellation."
  [ctx ^long ms]
  (let [end (+ (System/nanoTime) (* ms 1000000))]
    (loop []
      (check! ctx)
      (let [left (- end (System/nanoTime))]
        (when (pos? left)
          (Thread/sleep (max 1 (min 5 (quot left 1000000))))
          (recur))))))

(defn row-bytes
  "Rough estimate of the heap size of a materialized row."
  ^long [^long ncols]
  (+ 32 (* 24 ncols)))
