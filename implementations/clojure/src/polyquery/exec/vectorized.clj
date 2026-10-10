(ns polyquery.exec.vectorized
  "Vectorized (batch-at-a-time) execution, `mode: vectorized`
  (spec/phases/phase-5.md).

  Table scans produce batches of up to 1,024 rows as typed column vectors
  (polyquery.exec.batch); filters evaluate their predicate kernel
  (polyquery.exec.kernels) over a whole batch and only shrink its selection
  vector; projections evaluate one kernel per output column; hash
  aggregation assigns group ids per batch and updates column-wise aggregate
  states (polyquery.exec.grouping).

  Operators without a vectorized implementation (joins, sorting, DISTINCT,
  LIMIT, index scans, …) are the row operators: their input batches are
  converted to rows, and their output rows are wrapped into batches whose
  columns are converted to typed vectors only when a kernel reads them.

  `build-batches` compiles a plan node into a re-reducible of Batch values;
  `build-rows` is the vectorized implementation of a row-producing node."
  (:require [polyquery.exec.batch :as b]
            [polyquery.exec.context :as ctx]
            [polyquery.exec.grouping :as g]
            [polyquery.exec.kernels :as k]
            [polyquery.exec.operators :as ops]
            [polyquery.storage.table :as table])
  (:import (java.util ArrayList)
           (polyquery.exec.batch Batch)
           (polyquery.exec.grouping AggState GroupTable)
           (polyquery.exec.kernels Kernel)))

(set! *warn-on-reflection* true)

(defmulti build-batches
  "Compiles plan node `plan` into a re-reducible of Batches."
  (fn [plan _env] (:op plan)))

(defn- rows->batches
  "Batches over a re-reducible of rows."
  [rows]
  (ops/reducible
   (fn [f init]
     (let [buf (volatile! (object-array b/capacity))
           cnt (long-array 1)
           flush (fn [acc]
                   (let [n (aget cnt 0)
                         ^objects rows @buf]
                     (if (zero? n)
                       acc
                       (let [rows (if (= n b/capacity) rows (java.util.Arrays/copyOf rows (int n)))
                             width (alength ^objects (aget rows 0))]
                         (vreset! buf (object-array b/capacity))
                         (aset cnt 0 0)
                         (f acc (b/rows->batch rows n width))))))
           acc (reduce (fn [acc row]
                         (let [n (aget cnt 0)]
                           (aset ^objects @buf n row)
                           (aset cnt 0 (inc n))
                           (if (= (inc n) b/capacity) (flush acc) acc)))
                       init rows)]
       (if (reduced? acc) (unreduced acc) (unreduced (flush acc)))))))

(defmethod build-batches :default [plan env]
  (rows->batches (ops/build-input plan env)))

(defn batches->rows
  "Re-reducible of the selected rows of a re-reducible of batches."
  [batches]
  (ops/reducible
   (fn [f init]
     (unreduced (reduce (fn [acc bt] (b/batch-rows! bt f acc)) init batches)))))

;; ---------------------------------------------------------------------------
;; Scan, filter, project

(defmethod build-batches :table-scan [plan env]
  (let [tbl (:table plan)
        width (count (:columns tbl))
        types (mapv :type (:columns tbl))
        columns (vec (:columns plan))
        qctx (:ctx env)]
    (ops/reducible
     (fn [f init]
       (loop [segs (seq (ops/scan-segments plan)) acc init]
         (if (or (nil? segs) (reduced? acc))
           (unreduced acc)
           (let [[seg lo hi] (first segs)
                 vectors (mapv #(table/segment-vector seg %) columns)
                 hi (long hi)
                 acc (loop [start (long lo) acc acc]
                       (if (or (>= start hi) (reduced? acc))
                         acc
                         (let [n (min b/capacity (- hi start))
                               cols (object-array width)]
                           (ctx/check! qctx)
                           (dotimes [c (count columns)]
                             (let [ci (long (nth columns c))]
                               (aset cols ci (b/segment-vec (nth vectors c) (nth types ci) start n))))
                           (recur (+ start n) (f acc (Batch. cols b/identity-sel n))))))]
             (recur (next segs) acc))))))))

(defmethod build-batches :filter [plan env]
  (let [pred (k/compile-filter env (:predicate plan))
        input (build-batches (:input plan) env)]
    (ops/reducible
     (fn [f init]
       (reduce (fn [acc ^Batch bt]
                 (let [[sel n] (pred bt)
                       n (long n)]
                   (if (zero? n) acc (f acc (Batch. (.-cols bt) sel n)))))
               init input)))))

(defmethod build-batches :project [plan env]
  (let [^objects ks (into-array Kernel (map #(k/compile-kernel env %) (:exprs plan)))
        nk (alength ks)
        input (build-batches (:input plan) env)]
    (ops/reducible
     (fn [f init]
       (reduce (fn [acc ^Batch bt]
                 (let [cols (object-array nk)
                       sel (.-sel bt)
                       n (.-n bt)]
                   (dotimes [i nk] (aset cols i (k/ev (aget ks i) bt sel n)))
                   (f acc (Batch. cols sel n))))
               init input)))))

(defmethod build-batches :subquery-scan [plan env]
  (build-batches (:input plan) env))

;; ---------------------------------------------------------------------------
;; Hash aggregation

(defrecord Partial [^GroupTable table states])

(defn aggregate-partial
  "Aggregates the batches of `input` for aggregate node plan: a Partial
  holding the group table and one AggState per aggregate."
  [plan input env]
  (let [qctx (:ctx env)
        key-exprs (:group-keys plan)
        specs (:aggregates plan)
        ^objects key-ks (into-array Kernel (map #(k/compile-kernel env %) key-exprs))
        ^objects arg-ks (into-array Object (map #(when-let [a (:arg %)] (k/compile-kernel env a)) specs))
        nkeys (alength key-ks)
        naggs (alength arg-ks)
        table (g/group-table (map :type key-exprs))
        ^objects states (into-array AggState (map g/agg-state specs))
        gids (int-array b/capacity)
        reserved (long-array 1)
        width (+ nkeys naggs)]
    (dotimes [j naggs] (.grow ^AggState (aget states j) 1))
    (reduce (fn [_ ^Batch bt]
              (let [sel (.-sel bt)
                    n (.-n bt)
                    kvs (object-array nkeys)]
                (dotimes [i nkeys] (aset kvs i (k/ev (aget key-ks i) bt sel n)))
                (.assign table kvs sel n gids)
                (let [size (.size table)]
                  (when (> size (aget reserved 0))
                    (ctx/check! qctx)
                    (ctx/reserve! qctx (* (- size (aget reserved 0)) (ctx/row-bytes width)))
                    (aset reserved 0 size))
                  (dotimes [j naggs]
                    (let [^AggState st (aget states j)
                          ak (aget arg-ks j)]
                      (.grow st size)
                      (.update st gids (when ak (k/ev ak bt sel n)) sel n))))
                nil))
            nil input)
    (->Partial table (vec states))))

(defn aggregate-merge!
  "Merges Partial `other` into `into` (new groups appended in their order
  in `other`). Returns `into`."
  [^Partial into ^Partial other]
  (let [^GroupTable t (:table into)
        ^GroupTable o (:table other)
        states (:states into)
        ostates (:states other)
        n (.size o)]
    (dotimes [gid n]
      (let [to (.findOrAdd t (.keyAt o gid))]
        (doseq [[^AggState st ^AggState os] (map vector states ostates)]
          (.grow st (inc to))
          (.mergeFrom st os gid to))))
    into))

(defn aggregate-rows
  "Result rows (group keys, then aggregate values) of a Partial in order of
  first appearance."
  ^ArrayList [^Partial p]
  (let [^GroupTable t (:table p)
        states (:states p)
        naggs (count states)
        n (.size t)
        out (ArrayList. n)]
    (dotimes [gid n]
      (let [^objects kv (.keyAt t gid)
            nkeys (alength kv)
            row (object-array (+ nkeys naggs))]
        (System/arraycopy kv 0 row 0 nkeys)
        (dotimes [j naggs]
          (aset row (+ nkeys j) (.result ^AggState (nth states j) gid)))
        (.add out row)))
    out))

;; ---------------------------------------------------------------------------
;; Row-producing entry points

(defmulti build-rows
  "Vectorized implementation of a row-producing plan node."
  (fn [plan _env] (:op plan)))

(defmethod build-rows :default [plan env]
  (batches->rows (build-batches plan env)))

(defmethod build-rows :hash-aggregate [plan env]
  (let [input (build-batches (:input plan) env)]
    (ops/reducible
     (fn [f init]
       (ops/reduce-list (aggregate-rows (aggregate-partial plan input env)) f init)))))
