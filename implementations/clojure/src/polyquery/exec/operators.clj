(ns polyquery.exec.operators
  "Row-at-a-time (Volcano-style, push-based via reduce) execution of
  physical plans (polyquery.plan.physical). `build` compiles a plan node once
  into a *re-reducible*: an IReduceInit of rows (Object arrays) that
  recomputes its result every time it is reduced. Correlated subqueries rely
  on this: their plan is built once and reduced once per outer row.

  Execution environment `env` (see also polyquery.exec.expr):
    :ctx            QueryContext
    :cells          correlation cells
    :build          this namespace's build function
    :max-join-rows  join output row limit"
  (:require [polyquery.errors :as err]
            [polyquery.exec.aggregate :as agg]
            [polyquery.exec.context :as ctx]
            [polyquery.exec.expr :as expr]
            [polyquery.plan.access :as access]
            [polyquery.storage.index :as index]
            [polyquery.storage.table :as table]
            [polyquery.values :as v])
  (:import (java.util ArrayList Comparator HashMap HashSet)
           (polyquery.exec.aggregate Accumulator)
           (polyquery.storage.column ColumnVector)))

(set! *warn-on-reflection* true)

(def ^:private check-interval 4096)

(defmulti build
  "Compiles physical plan node `plan` into a re-reducible of rows."
  (fn [plan _env] (:op plan)))

(defn- reducible
  "A re-reducible whose rows are produced by calling (produce f init), which
  must honour `reduced`."
  [produce]
  (reify clojure.lang.IReduceInit
    (reduce [_ f init] (produce f init))))

(defn- reduce-list
  "Reduces f over a java.util.List of rows, honouring reduced."
  [^java.util.List rows f init]
  (let [n (.size rows)]
    (loop [i 0 acc init]
      (if (or (= i n) (reduced? acc))
        (unreduced acc)
        (recur (inc i) (f acc (.get rows i)))))))

(defn materialize
  "Collects the rows of a re-reducible into an ArrayList, checking for
  timeouts and accounting memory."
  ^ArrayList [rows env]
  (let [qctx (:ctx env)
        out (ArrayList.)]
    (reduce (fn [_ ^objects row]
              (when (zero? (rem (.size out) check-interval))
                (ctx/check! qctx)
                (ctx/reserve! qctx (* check-interval (ctx/row-bytes (alength row)))))
              (.add out row)
              nil)
            nil rows)
    out))

;; ---------------------------------------------------------------------------
;; Leaves

(defmethod build :values [plan _env]
  (let [rows (mapv object-array (:rows plan))]
    (reducible (fn [f init] (reduce-list rows f init)))))

(defn- scan-vectors
  "The ColumnVectors of the given columns in a segment."
  ^objects [seg columns]
  (into-array ColumnVector (map #(table/segment-vector seg %) columns)))

(defn- segment-selected?
  "False when the segment's chunk statistics exclude a skip predicate."
  [seg skip]
  (let [stats (:chunk-stats seg)]
    (or (nil? stats)
        (every? #(access/segment-may-match? % (nth stats (:column %)) (:row-count seg)) skip))))

(defn- fill-row!
  "Copies row r of the vectors into the given positions of row."
  [^objects row ^objects vectors ^longs positions ^long r]
  (dotimes [c (alength vectors)]
    (aset row (aget positions c) (.valueAt ^ColumnVector (aget vectors c) r))))

(defmethod build :table-scan [plan env]
  ;; Rows have the table's full width; only the scanned columns are filled.
  (let [table (:table plan)
        width (count (:columns table))
        columns (:columns plan)
        positions (long-array columns)
        skip (:skip plan)
        qctx (:ctx env)]
    (reducible
     (fn [f init]
       (loop [segs (seq (:segments table)) acc init]
         (if (or (nil? segs) (reduced? acc))
           (unreduced acc)
           (let [seg (first segs)]
             (if-not (segment-selected? seg skip)
               (recur (next segs) acc)
               (let [vectors (scan-vectors seg columns)
                     n (long (:row-count seg))
                     acc (loop [r 0 acc acc]
                           (if (or (= r n) (reduced? acc))
                             acc
                             (do
                               (when (zero? (rem r check-interval)) (ctx/check! qctx))
                               (let [row (object-array width)]
                                 (fill-row! row vectors positions r)
                                 (recur (inc r) (f acc row))))))]
                 (recur (next segs) acc))))))))))

(defn- fetch-rows
  "Reduces f over the rows with the given (ascending) row ids."
  [table columns ^ints row-ids qctx f init]
  (let [width (count (:columns table))
        positions (long-array columns)
        segs (:segments table)
        n (alength row-ids)]
    (loop [k 0 seg-idx -1 ^objects vectors nil acc init]
      (if (or (= k n) (reduced? acc))
        (unreduced acc)
        (let [r (aget row-ids k)
              si (table/segment-index table r)
              seg (nth segs si)
              vectors (if (= si seg-idx) vectors (scan-vectors seg columns))
              row (object-array width)]
          (when (zero? (rem k check-interval)) (ctx/check! qctx))
          (fill-row! row vectors positions (- r (long (:start seg))))
          (recur (inc k) si vectors (f acc row)))))))

(defn- index-row-ids
  "Row ids found by an index lookup (see polyquery.plan.access)."
  ^ints [table idx lookup]
  (case (:kind lookup)
    :keys (index/lookup-equal idx (:keys lookup))
    :ranges (let [col-type (:type (nth (:columns table) (:column-index idx)))
                  ->bound (fn [b] {:cmp (v/comparator-fn (:cmp-type b) col-type (:type b))
                                   :value (:value b) :inclusive? (:inclusive? b)})]
              (index/lookup-ranges idx (mapv (fn [r] {:lowers (mapv ->bound (:lowers r))
                                                      :uppers (mapv ->bound (:uppers r))})
                                             (:ranges lookup))))))

(defmethod build :index-scan [plan env]
  (let [table (:table plan)]
    (reducible
     (fn [f init]
       (fetch-rows table (:columns plan) (index-row-ids table (:index plan) (:lookup plan))
                   (:ctx env) f init)))))

(defn- scan-rows
  "Materializes the selected columns of a table as (full-width) rows."
  ^ArrayList [table columns env]
  (materialize (build {:op :table-scan :table table :columns columns} env) env))

(defmethod build :lookup-scan [plan env]
  ;; The probe expressions only read enclosing queries' rows (correlation
  ;; cells), so the hash table over the scanned rows is built once and
  ;; probed on every reduce.
  (let [keys (:keys plan)
        key-of (fn [fs]
                 (let [fs (vec fs)]
                   (fn [row]
                     (loop [i 0 acc (transient [])]
                       (if (< i (count fs))
                         (when-some [x ((nth fs i) row)]
                           (recur (inc i) (conj! acc x)))
                         (persistent! acc))))))
        inner-key (key-of (map (fn [{e :expr ct :cmp-type}]
                                 (let [f (expr/compile-expr env e) k (v/key-fn (:type e) ct)]
                                   #(some-> (f %) k)))
                               keys))
        probe-key (key-of (map (fn [{e :probe ct :cmp-type}]
                                 (let [f (expr/compile-expr env e) k (v/key-fn (:type e) ct)]
                                   #(some-> (f %) k)))
                               keys))
        residual (if-let [r (:residual plan)] (expr/compile-predicate env r) (constantly true))
        table (delay
                (let [m (HashMap.)
                      rows (scan-rows (:table plan) (:columns plan) env)]
                  (doseq [row rows]
                    (when-let [k (inner-key row)]
                      (let [^ArrayList b (or (.get m k) (let [b (ArrayList.)] (.put m k b) b))]
                        (.add b row))))
                  m))
        empty-row (object-array 0)]
    (reducible
     (fn [f init]
       (let [k (probe-key empty-row)
             bucket (when k (.get ^HashMap @table k))]
         (if bucket
           (reduce-list bucket (fn [acc row] (if (residual row) (f acc row) acc)) init)
           init))))))

(defmethod build :subquery-scan [plan env]
  (build (:input plan) env))

;; ---------------------------------------------------------------------------
;; Row-wise operators

(defmethod build :filter [plan env]
  (let [pred (expr/compile-predicate env (:predicate plan))]
    (eduction (filter pred) (build (:input plan) env))))

(defmethod build :project [plan env]
  (let [^objects fs (into-array Object (map #(expr/compile-expr env %) (:exprs plan)))
        n (alength fs)]
    (eduction (map (fn [row]
                     (let [out (object-array n)]
                       (dotimes [i n]
                         (aset out i ((aget fs i) row)))
                       out)))
              (build (:input plan) env))))

(defn- eval-count-clause
  "Evaluates a constant LIMIT/OFFSET expression to a non-negative long or nil."
  [env e what]
  (when e
    (let [x (expr/eval-constant env e)]
      (when (and (some? x) (neg? (long x)))
        (err/fail! "INVALID_ARGUMENT" (str what " must not be negative")))
      x)))

(defmethod build :limit [plan env]
  (let [limit (eval-count-clause env (:limit plan) "LIMIT")
        offset (eval-count-clause env (:offset plan) "OFFSET")
        xf (cond-> (drop (long (or offset 0)))
             limit (comp (take (long limit))))]
    (eduction xf (build (:input plan) env))))

;; ---------------------------------------------------------------------------
;; Aggregation, DISTINCT, sorting

(defn- new-accumulators ^objects [^objects factories]
  (let [accs (object-array (alength factories))]
    (dotimes [i (alength factories)] (aset accs i ((aget factories i))))
    accs))

(defn- row-key
  "Hashable key of a row's values (NULLs equal, -0.0 = 0.0)."
  [^objects vals]
  (let [n (alength vals)]
    (if (= n 1)
      [(v/normalize-key (aget vals 0))]
      (let [out (object-array n)]
        (dotimes [i n] (aset out i (v/normalize-key (aget vals i))))
        (vec out)))))

(defmethod build :hash-aggregate [plan env]
  (let [qctx (:ctx env)
        specs (:aggregates plan)
        factories (into-array Object (map agg/accumulator-factory specs))
        ^objects arg-fns (into-array Object (map #(if-let [a (:arg %)] (expr/compile-expr env a) (constantly nil))
                                                 specs))
        ^objects key-fns (into-array Object (map #(expr/compile-expr env %) (:group-keys plan)))
        nkeys (alength key-fns)
        naggs (count specs)
        input (build (:input plan) env)
        feed (fn [^objects accs row]
               (dotimes [i naggs]
                 (.add ^Accumulator (aget accs i) ((aget arg-fns i) row))))
        finish (fn [^objects key-vals ^objects accs]
                 (let [out (object-array (+ nkeys naggs))]
                   (dotimes [i nkeys] (aset out i (aget key-vals i)))
                   (dotimes [i naggs] (aset out (+ nkeys i) (.result ^Accumulator (aget accs i))))
                   out))]
    (reducible
     (fn [f init]
       (if (zero? nkeys)
         (let [accs (new-accumulators factories)]
           (reduce (fn [_ row] (feed accs row) nil) nil input)
           (reduce-list [(finish (object-array 0) accs)] f init))
         (let [groups (HashMap.)
               order (ArrayList.)]
           (reduce (fn [_ row]
                     (let [vals (object-array nkeys)
                           _ (dotimes [i nkeys] (aset vals i ((aget key-fns i) row)))
                           k (row-key vals)
                           ^objects entry (or (.get groups k)
                                              (let [e (object-array [vals (new-accumulators factories)])]
                                                (when (zero? (rem (.size order) 1024))
                                                  (ctx/check! qctx)
                                                  (ctx/reserve! qctx (* 1024 (ctx/row-bytes (+ nkeys naggs)))))
                                                (.put groups k e)
                                                (.add order e)
                                                e))]
                       (feed (aget entry 1) row)
                       nil))
                   nil input)
           (reduce-list (ArrayList. ^java.util.Collection
                                    (map (fn [^objects e] (finish (aget e 0) (aget e 1))) order))
                        f init)))))))

(defmethod build :distinct [plan env]
  (let [input (build (:input plan) env)
        qctx (:ctx env)]
    (reducible
     (fn [f init]
       (let [seen (HashSet.)]
         (reduce (fn [acc ^objects row]
                   (if (.add seen (row-key row))
                     (do (when (zero? (rem (.size seen) check-interval))
                           (ctx/reserve! qctx (* check-interval (ctx/row-bytes (alength row)))))
                         (f acc row))
                     acc))
                 init input))))))

(defn- row-comparator
  ^Comparator [keys]
  (let [cmps (mapv (fn [{:keys [index type desc? nulls-first?]}]
                     (let [c (v/value-comparator type)
                           i (int index)]
                       (fn ^long [^objects a ^objects b]
                         (let [x (aget a i) y (aget b i)]
                           (cond
                             (and (nil? x) (nil? y)) 0
                             (nil? x) (if nulls-first? -1 1)
                             (nil? y) (if nulls-first? 1 -1)
                             :else (let [r (.compare c x y)] (if desc? (- r) r)))))))
                   keys)]
    (reify Comparator
      (compare [_ a b]
        (loop [cs cmps]
          (if-let [cf (first cs)]
            (let [r (long (cf a b))]
              (if (zero? r) (recur (next cs)) (int r)))
            0))))))

(defmethod build :sort [plan env]
  (let [input (build (:input plan) env)
        cmp (row-comparator (:keys plan))]
    (reducible
     (fn [f init]
       (let [rows (materialize input env)]
         (.sort rows cmp)
         (reduce-list rows f init))))))
