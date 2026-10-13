(ns polyquery.exec.parallel
  "Parallel execution (`threads: N`, spec/phases/phase-5.md).

  The planner (polyquery.plan.parallel) marks plan nodes whose input is a
  *partitionable pipeline* — a table scan below filters, projections,
  derived tables and the probe side of hash joins, free of subqueries and
  correlated references. Such a pipeline is executed once per contiguous
  range of the scanned table's rows, each range on a worker thread with its
  own compiled operators (no shared mutable state). Hash tables of joins in
  the pipeline are built once by the coordinating thread and shared
  read-only by all partitions.

    hash-aggregate  partial aggregation per partition, merged in partition
                    order (so groups keep their serial order of first
                    appearance; INT64/DECIMAL sums stay exact)
    sort            partitions materialized in parallel, concatenated in
                    order, then sorted (polyquery.exec.sort: radix sort or
                    parallel merge sort; stable)
    top-n           a bounded heap per partition, merged (ties by input
                    position, as in a stable sort)
    gather          streaming: morsels of rows are processed by up to N
                    workers ahead of the consumer and emitted in table
                    order (bounded look-ahead, stops early under LIMIT)

  Results are therefore identical to serial execution (FLOAT64 sums up to
  rounding). A failing partition's error is rethrown after all partitions
  finished; errors of earlier partitions take precedence."
  (:require [polyquery.exec.context :as ctx]
            [polyquery.exec.join :as join]
            [polyquery.exec.operators :as ops]
            [polyquery.exec.sort :as sort]
            [polyquery.exec.vectorized :as vec]
            [polyquery.exec.vjoin :as vjoin]
            [polyquery.util.threads :as threads])
  (:import (java.util ArrayDeque ArrayList Arrays Comparator)
           (java.util.concurrent Callable ExecutionException ExecutorService Executors Future)
           (polyquery.exec.operators Candidate)))

(set! *warn-on-reflection* true)

(def ^:const min-partition-rows
  "Smallest number of rows worth a partition of its own."
  1024)

(defonce ^:private ^ExecutorService pool
  (Executors/newCachedThreadPool (threads/factory "pq-worker")))

(defn- unwrap ^Throwable [^Throwable t]
  (if (and (instance? ExecutionException t) (.getCause t)) (.getCause t) t))

(defn- await-result [^Future f]
  (try (.get f)
       (catch ExecutionException e (throw (unwrap e)))))

(defn run-all
  "Runs the thunks on worker threads (the first on the calling thread) and
  returns their results in order. Waits for every thunk; then rethrows the
  first failure in order."
  [thunks]
  (let [[t0 & more] thunks
        futs (mapv #(.submit pool ^Callable %) more)
        r0 (try {:ok (t0)} (catch Throwable e {:err e}))
        rs (into [r0] (map (fn [^Future f]
                             (try {:ok (.get f)}
                                  (catch ExecutionException e {:err (unwrap e)})
                                  (catch Throwable e {:err e}))))
                 futs)]
    (if-let [^Throwable e (some :err rs)]
      (throw e)
      (mapv :ok rs))))

;; ---------------------------------------------------------------------------
;; Partitionable pipelines

(defn- probe-side [node] (if (= :left (:build node)) :right :left))

(defn chain-leaf
  "The table scan at the bottom of a partitionable pipeline."
  [node]
  (case (:op node)
    :table-scan node
    (:filter :project :subquery-scan) (chain-leaf (:input node))
    :hash-join (chain-leaf ((probe-side node) node))))

(defn- with-range
  "The pipeline restricted to table rows [from, to) of its scan."
  [node r]
  (case (:op node)
    :table-scan (assoc node :range r)
    (:filter :project :subquery-scan) (update node :input with-range r)
    :hash-join (update node (probe-side node) with-range r)))

(defn- share-builds
  "Builds the hash tables of the pipeline's joins once (on this thread);
  the partitions probe them read-only."
  [node env]
  (case (:op node)
    :table-scan node
    (:filter :project :subquery-scan) (update node :input share-builds env)
    :hash-join (-> node
                   (assoc :prebuilt (if (and (= :vectorized (:mode env)) (vjoin/vectorizable? node))
                                      (vjoin/build-table node env)
                                      (join/build-hash-table node env)))
                   (update (probe-side node) share-builds env))))

(defn- split-ranges
  "`parts` contiguous row ranges covering [0, rows) (at least one)."
  [^long rows ^long parts]
  (let [parts (max 1 parts)]
    (vec (for [i (range parts)]
           [(quot (* i rows) parts) (quot (* (inc i) rows) parts)]))))

(defn- table-rows ^long [input] (long (:row-count (:table (chain-leaf input)))))

(defn- partitions
  "Row ranges of the partitions of a pipeline for up to `threads` workers."
  [input threads]
  (let [rows (table-rows input)]
    (split-ranges rows (min (long threads) (quot (+ rows (dec min-partition-rows)) min-partition-rows)))))

(defn- rows-of
  "Re-reducible of the rows of a (partition of a) pipeline."
  [input env]
  ((:build env) input env))

(defn- collect-rows ^ArrayList [rows]
  (let [out (ArrayList.)]
    (reduce (fn [_ row] (.add out row) nil) nil rows)
    out))

;; ---------------------------------------------------------------------------
;; Operators

(defn- aggregate [plan env]
  (let [vectorized? (= :vectorized (:mode env))]
    (ops/reducible
     (fn [f init]
       (let [input (share-builds (:input plan) env)
             partial (fn [r]
                       (let [in (with-range input r)]
                         (if vectorized?
                           (vec/aggregate-partial plan (vec/build-batches in env) env)
                           (ops/aggregate-partial plan (rows-of in env) env))))
             parts (run-all (mapv (fn [r] #(partial r)) (partitions input (:partitions plan))))
             merged (reduce (if vectorized? vec/aggregate-merge! ops/aggregate-merge!) parts)]
         (ops/reduce-list (if vectorized? (vec/aggregate-rows merged) (ops/aggregate-rows merged))
                          f init))))))

(defn- concat-lists
  "The java.util.Lists `parts` concatenated into one ArrayList."
  ^ArrayList [parts]
  (let [out (ArrayList. (int (reduce + (map #(.size ^java.util.List %) parts))))]
    (doseq [^java.util.Collection p parts] (.addAll out p))
    out))

(defn- sort-rows [plan env]
  (ops/reducible
   (fn [f init]
     (let [input (share-builds (:input plan) env)
           ranges (partitions input (:partitions plan))
           parts (run-all (mapv (fn [r] #(ops/materialize (rows-of (with-range input r) env) env))
                                ranges))
           all (concat-lists parts)]
       (ops/reduce-list (sort/sort-rows all (:keys plan) (:ctx env) run-all (:partitions plan))
                        f init)))))

(defn- top-n [plan env]
  (let [cmp (ops/row-comparator (:keys plan))]
    (ops/reducible
     (fn [f init]
       (let [[k offset] (ops/top-n-bounds plan env)]
         (if (nil? k)
           (reduce f init (sort-rows plan env))
           (let [input (share-builds (:input plan) env)
                 ranges (partitions input (:partitions plan))
                 parts (run-all (map-indexed
                                 (fn [i r]
                                   #(ops/top-candidates (rows-of (with-range input r) env) cmp k
                                                        (bit-shift-left (long i) 40) env))
                                 ranges))
                 all (concat-lists parts)]
             (.sort all (ops/candidate-comparator cmp))
             (ops/emit-candidates (if (> (.size all) (long k))
                                    (ArrayList. (.subList all 0 (int k)))
                                    all)
                                  offset f init))))))))

(defn- morsels
  "Row ranges processed by gather workers: about two per worker, at least
  `min-partition-rows` and at most 131,072 rows each."
  [input threads]
  (let [rows (table-rows input)
        size (-> (quot rows (* 2 (long threads))) (max min-partition-rows) (min 131072))]
    (split-ranges rows (max 1 (quot (+ rows (dec size)) size)))))

(defn- gather [plan env]
  (let [window (long (:partitions plan))]
    (ops/reducible
     (fn [f init]
       (let [input (share-builds (:input plan) env)
             ranges (morsels input window)]
         (if (= 1 (count ranges))
           (reduce f init (rows-of input env))
           (let [pending (ArrayDeque.)
                 todo (volatile! (seq ranges))
                 submit! (fn []
                           (when-let [r (first @todo)]
                             (vswap! todo next)
                             (.add pending (.submit pool ^Callable
                                                    #(collect-rows (rows-of (with-range input r) env))))))
                 ;; keeps `reduced` visible to the loop below
                 step (fn [acc row] (let [r (f acc row)] (if (reduced? r) (reduced r) r)))]
             (dotimes [_ window] (submit!))
             (try
               (loop [acc init]
                 (if-let [fut (.poll pending)]
                   (let [rows (await-result fut)
                         _ (submit!)
                         acc (reduce step acc rows)]
                     (if (reduced? acc) (unreduced acc) (recur acc)))
                   acc))
               (finally
                 (doseq [^Future p pending] (.cancel p false)))))))))))

(defn build
  "Builds a node marked with :partitions (see the namespace doc)."
  [plan env]
  (case (:op plan)
    :hash-aggregate (aggregate plan env)
    :sort (sort-rows plan env)
    :top-n (top-n plan env)
    :gather (gather plan env)))
