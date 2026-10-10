(ns polyquery.exec.join
  "Join operators (spec/sql/semantics.md §7, spec/phases/phase-5.md):
    * hash join — hash table on the input chosen by the planner (always the
      right input of LEFT joins), probed with the other input's rows; the
      table can be built once and shared by the partitions of a parallel
      probe (:prebuilt);
    * sort-merge join — both inputs sorted on their key values, equal-key
      runs joined pairwise;
    * nested-loop join — every pair of rows; for equi-joins the key
      equalities are tested first and the residual condition only on pairs
      with equal keys, exactly like the other algorithms.
  All support INNER and LEFT joins; nested loops also CROSS joins and
  arbitrary conditions. Joined rows are the left row's columns followed by
  the right row's; unmatched left rows of a LEFT join are padded with NULLs.
  NULL keys never match. The number of produced rows is checked against
  --max-join-rows."
  (:require [polyquery.errors :as err]
            [polyquery.exec.context :as ctx]
            [polyquery.exec.expr :as expr]
            [polyquery.exec.operators :as ops]
            [polyquery.util.text :as text]
            [polyquery.values :as v])
  (:import (java.math BigInteger)
           (java.util ArrayList Arrays Comparator HashMap List)))

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
  (let [left (ops/build-input (:left plan) env)
        right (ops/build-input (:right plan) env)
        lw (long (:left-width plan))
        rw (long (:right-width plan))
        left-join? (= :left (:join-type plan))
        keys-pred (when-let [k (:key-condition plan)] (expr/compile-predicate env k))
        cond-pred (if-let [c (:condition plan)] (expr/compile-predicate env c) (constantly true))
        pred (if keys-pred
               (fn [row] (and (keys-pred row) (cond-pred row)))
               cond-pred)
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

(defn key-extractor
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

(defn hash-table
  "Hash table key → ArrayList of rows over the rows of a build input."
  ^HashMap [rows key-of env]
  (let [table (HashMap.)
        qctx (:ctx env)]
    (reduce (fn [^long n ^objects r]
              (when (zero? (rem n 4096))
                (ctx/check! qctx)
                (ctx/reserve! qctx (* 4096 (ctx/row-bytes (alength r)))))
              (when-let [k (key-of r)]
                (let [^ArrayList bucket (or (.get table k)
                                            (let [b (ArrayList. 2)] (.put table k b) b))]
                  (.add bucket r)))
              (inc n))
            0 rows)
    table))

(defn build-hash-table
  "Builds the hash table of a hash-join node over its build input (key →
  ArrayList of rows). Used to share one table between the partitions of a
  parallel probe."
  ^HashMap [plan env]
  (if (= :left (:build plan))
    (hash-table (ops/build-input (:left plan) env) (key-extractor env (:left-keys plan)) env)
    (hash-table (ops/build-input (:right plan) env) (key-extractor env (:right-keys plan)) env)))

(defmethod ops/build :hash-join [plan env]
  (let [build-left? (= :left (:build plan))
        prebuilt (:prebuilt plan)
        ;; the build input is only compiled when the table is not shared
        left (when-not (and prebuilt build-left?) (ops/build-input (:left plan) env))
        right (when-not (and prebuilt (not build-left?)) (ops/build-input (:right plan) env))
        lw (long (:left-width plan))
        rw (long (:right-width plan))
        left-join? (= :left (:join-type plan))
        lkey (key-extractor env (:left-keys plan))
        rkey (key-extractor env (:right-keys plan))
        residual (if-let [c (:residual plan)] (expr/compile-predicate env c) (constantly true))
        table-of (fn [rows key-of] (or prebuilt (hash-table rows key-of env)))]
    (reducible
     (if build-left?
       ;; inner joins only: build on the left input, probe with the right rows
       (fn [f init]
         (let [^HashMap table (table-of left lkey)
               emit (output-counter env)]
           (reduce
            (fn [acc r]
              (let [k (rkey r)
                    ^ArrayList bucket (when (some? k) (.get table k))
                    n (if bucket (.size bucket) 0)]
                (loop [i 0 acc acc]
                  (cond
                    (reduced? acc) acc
                    (< i n) (let [row (joined (.get bucket i) r lw rw)]
                              (if (residual row)
                                (do (emit) (recur (inc i) (f acc row)))
                                (recur (inc i) acc)))
                    :else acc))))
            init right)))
       (fn [f init]
         (let [^HashMap table (table-of right rkey)
               emit (output-counter env)]
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
            init left)))))))

;; ---------------------------------------------------------------------------
;; Sort-merge join

(defn- compare-keys
  "Total order of join key values (as produced by key-extractor: Long,
  BigInteger, Double, String or Boolean values of one comparison type, or
  vectors of them for composite keys)."
  ^long [a b]
  (cond
    (and (instance? Long a) (instance? Long b)) (Long/compare (long a) (long b))
    (instance? String a) (text/compare-code-points a b)
    (instance? Double a) (Double/compare (double a) (double b))
    (instance? Boolean a) (Boolean/compare (boolean a) (boolean b))
    (instance? List a) (let [^List x a ^List y b n (.size x)]
                         (loop [i 0]
                           (if (< i n)
                             (let [c (compare-keys (.get x i) (.get y i))]
                               (if (zero? c) (recur (inc i)) c))
                             0)))
    :else (let [big (fn ^BigInteger [x] (if (instance? BigInteger x) x (BigInteger/valueOf (long x))))]
            (long (.compareTo ^BigInteger (big a) ^BigInteger (big b))))))

(def ^:private entry-comparator
  (reify Comparator
    (compare [_ a b] (int (compare-keys (aget ^objects a 0) (aget ^objects b 0))))))

(defn- keyed-rows
  "Materializes rows as [key row] pairs sorted by key (stable); rows with a
  NULL key are returned separately (they never match)."
  [rows key-of env]
  (let [qctx (:ctx env)
        keyed (ArrayList.)
        unkeyed (ArrayList.)]
    (reduce (fn [^long n ^objects r]
              (when (zero? (rem n 4096))
                (ctx/check! qctx)
                (ctx/reserve! qctx (* 4096 (ctx/row-bytes (+ 2 (alength r))))))
              (if-some [k (key-of r)]
                (.add keyed (object-array [k r]))
                (.add unkeyed r))
              (inc n))
            0 rows)
    (let [arr (.toArray keyed)]
      (Arrays/sort arr ^Comparator entry-comparator)
      [arr unkeyed])))

(defmethod ops/build :merge-join [plan env]
  (let [left (ops/build-input (:left plan) env)
        right (ops/build-input (:right plan) env)
        lw (long (:left-width plan))
        rw (long (:right-width plan))
        left-join? (= :left (:join-type plan))
        lkey (key-extractor env (:left-keys plan))
        rkey (key-extractor env (:right-keys plan))
        residual (if-let [c (:residual plan)] (expr/compile-predicate env c) (constantly true))]
    (reducible
     (fn [f init]
       (let [[^objects ls ^ArrayList lnull] (keyed-rows left lkey env)
             [^objects rs _] (keyed-rows right rkey env)
             nl (alength ls)
             nr (alength rs)
             emit (output-counter env)
             pad (fn [acc l] (if left-join? (do (emit) (f acc (joined l nil lw rw))) acc))
             ;; unmatched left rows with a NULL key
             acc (loop [i 0 acc init]
                   (if (or (= i (.size lnull)) (reduced? acc))
                     acc
                     (recur (inc i) (pad acc (.get lnull i)))))]
         (loop [i 0 j 0 acc acc]
           (cond
             (reduced? acc) (unreduced acc)
             (>= i nl) acc
             (>= j nr) (recur (inc i) j (pad acc (aget ^objects (aget ls i) 1)))
             :else
             (let [lk (aget ^objects (aget ls i) 0)
                   c (compare-keys lk (aget ^objects (aget rs j) 0))]
               (cond
                 (neg? c) (recur (inc i) j (pad acc (aget ^objects (aget ls i) 1)))
                 (pos? c) (recur i (inc j) acc)
                 :else
                 ;; equal-key runs [i, i2) × [j, j2)
                 (let [i2 (long (loop [k (inc i)]
                            (if (and (< k nl) (zero? (compare-keys lk (aget ^objects (aget ls k) 0)))) (recur (inc k)) k)))
                       j2 (long (loop [k (inc j)]
                                  (if (and (< k nr) (zero? (compare-keys lk (aget ^objects (aget rs k) 0)))) (recur (inc k)) k)))
                       acc (loop [a i acc acc]
                             (if (or (= a i2) (reduced? acc))
                               acc
                               (let [l (aget ^objects (aget ls a) 1)
                                     acc (loop [b j acc acc matched? false]
                                           (cond
                                             (reduced? acc) acc
                                             (< b j2) (let [row (joined l (aget ^objects (aget rs b) 1) lw rw)]
                                                        (if (residual row)
                                                          (do (emit) (recur (inc b) (f acc row) true))
                                                          (recur (inc b) acc matched?)))
                                             matched? acc
                                             :else (pad acc l)))]
                                 (recur (inc a) acc))))]
                   (recur i2 j2 acc)))))))))))
