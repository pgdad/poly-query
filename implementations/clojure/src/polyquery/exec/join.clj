(ns polyquery.exec.join
  "Join operators (spec/sql/semantics.md §7): hash join (build side = right
  input) for joins with equality keys and nested-loop join otherwise. Both
  support INNER and LEFT joins; nested loops also CROSS joins. Joined rows are
  the left row's columns followed by the right row's; unmatched left rows of
  a LEFT join are padded with NULLs. The number of produced rows is checked
  against --max-join-rows."
  (:require [polyquery.errors :as err]
            [polyquery.exec.context :as ctx]
            [polyquery.exec.expr :as expr]
            [polyquery.exec.operators :as ops]
            [polyquery.values :as v])
  (:import (java.util ArrayList HashMap)))

(set! *warn-on-reflection* true)

(defn- joined ^objects [^objects l ^objects r ^long lw ^long rw]
  (let [out (object-array (+ lw rw))]
    (System/arraycopy l 0 out 0 lw)
    (when r (System/arraycopy r 0 out lw rw))
    out))

(defn- output-counter
  "Returns a function to call per produced row: enforces the join row limit
  and periodically checks for timeouts/cancellation."
  [env]
  (let [limit (long (or (:max-join-rows env) Long/MAX_VALUE))
        qctx (:ctx env)
        n (long-array 1)]
    (fn []
      (let [c (inc (aget n 0))]
        (aset n 0 c)
        (when (> c limit)
          (err/fail! "RESOURCE_LIMIT" (str "join produced more than " limit " rows (--max-join-rows)")))
        (when (zero? (rem c 4096)) (ctx/check! qctx))))))

(defn- reducible [produce]
  (reify clojure.lang.IReduceInit
    (reduce [_ f init] (produce f init))))

(defmethod ops/build :nested-loop-join [plan env]
  (let [left (ops/build (:left plan) env)
        right (ops/build (:right plan) env)
        lw (long (:left-width plan))
        rw (long (:right-width plan))
        left-join? (= :left (:join-type plan))
        pred (if-let [c (:condition plan)] (expr/compile-predicate env c) (constantly true))
        qctx (:ctx env)]
    (reducible
     (fn [f init]
       (let [^ArrayList rrows (ops/materialize right env)
             n (.size rrows)
             emit (output-counter env)]
         (reduce
          (fn [acc l]
            (loop [i 0 acc acc matched? false]
              (cond
                (reduced? acc) acc
                (< i n) (let [row (joined l (.get rrows i) lw rw)]
                          (when (zero? (rem i 4096)) (ctx/check! qctx))
                          (if (pred row)
                            (do (emit) (recur (inc i) (f acc row) true))
                            (recur (inc i) acc matched?)))
                (and left-join? (not matched?)) (do (emit) (f acc (joined l nil lw rw)))
                :else acc)))
          init left))))))

(defn- key-extractor
  "Compiles join keys into (fn [row]) → hashable key, or nil if any key
  value is NULL (NULL keys never match)."
  [env keys]
  (let [fs (mapv (fn [{e :expr ct :cmp-type}]
                   (let [f (expr/compile-expr env e)
                         k (v/key-fn (:type e) ct)]
                     (fn [row] (let [x (f row)] (when (some? x) (k x))))))
                 keys)]
    (if (= 1 (count fs))
      (first fs)
      (let [^objects fa (into-array Object fs)
            n (alength fa)]
        (fn [row]
          (let [out (object-array n)]
            (loop [i 0]
              (if (< i n)
                (when-let [x ((aget fa i) row)]
                  (aset out i x)
                  (recur (inc i)))
                (vec out)))))))))

(defmethod ops/build :hash-join [plan env]
  (let [left (ops/build (:left plan) env)
        right (ops/build (:right plan) env)
        lw (long (:left-width plan))
        rw (long (:right-width plan))
        left-join? (= :left (:join-type plan))
        lkey (key-extractor env (:left-keys plan))
        rkey (key-extractor env (:right-keys plan))
        residual (if-let [c (:residual plan)] (expr/compile-predicate env c) (constantly true))
        qctx (:ctx env)]
    (reducible
     (fn [f init]
       (let [table (HashMap.)
             emit (output-counter env)]
         (reduce (fn [^long n ^objects r]
                   (when (zero? (rem n 4096))
                     (ctx/check! qctx)
                     (ctx/reserve! qctx (* 4096 (ctx/row-bytes (alength r)))))
                   (when-let [k (rkey r)]
                     (let [^ArrayList bucket (or (.get table k)
                                                 (let [b (ArrayList. 2)] (.put table k b) b))]
                       (.add bucket r)))
                   (inc n))
                 0 right)
         (reduce
          (fn [acc l]
            (let [k (lkey l)
                  ^ArrayList bucket (when (some? k) (.get table k))
                  n (if bucket (.size bucket) 0)]
              (loop [i 0 acc acc matched? false]
                (cond
                  (reduced? acc) acc
                  (< i n) (let [row (joined l (.get bucket i) lw rw)]
                            (if (residual row)
                              (do (emit) (recur (inc i) (f acc row) true))
                              (recur (inc i) acc matched?)))
                  (and left-join? (not matched?)) (do (emit) (f acc (joined l nil lw rw)))
                  :else acc))))
          init left))))))
