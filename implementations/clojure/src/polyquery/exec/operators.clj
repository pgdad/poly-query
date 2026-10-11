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
            [polyquery.exec.skipping :as skipping]
            [polyquery.storage.index :as index]
            [polyquery.storage.table :as table]
            [polyquery.types :as t]
            [polyquery.values :as v])
  (:import (java.util ArrayList Comparator HashMap HashSet PriorityQueue)
           (polyquery.exec.aggregate Accumulator)
           (polyquery.storage.column ColumnVector)))

(set! *warn-on-reflection* true)

(def ^:private ^:const check-interval 4096)

(defmulti build
  "Compiles physical plan node `plan` into a re-reducible of rows."
  (fn [plan _env] (:op plan)))

(defn build-input
  "Builds a child node through the environment's builder (:build), which
  selects the execution model (polyquery.exec.dispatch)."
  [node env]
  ((:build env) node env))

(defn reducible
  "A re-reducible whose rows are produced by calling (produce f init), which
  must honour `reduced`."
  [produce]
  (reify clojure.lang.IReduceInit
    (reduce [_ f init] (produce f init))))

(defn reduce-list
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

(defn segment-selected?
  "False when the segment's chunk statistics exclude a skip predicate."
  [seg skip]
  (let [stats (:chunk-stats seg)]
    (or (nil? stats)
        (every? #(skipping/segment-may-match? % (nth stats (:column %)) (:row-count seg)) skip))))

(defn- fill-row!
  "Copies row r of the vectors into the given positions of row."
  [^objects row ^objects vectors ^longs positions ^long r]
  (dotimes [c (alength vectors)]
    (aset row (aget positions c) (.valueAt ^ColumnVector (aget vectors c) r))))

(defn scan-segments
  "The segments of a table scan with the row range [lo, hi) of each segment
  to read: all rows, or those inside the scan's :range [from to) of table
  row ids (a partition of a parallel scan). Segments excluded by the chunk
  statistics (:skip) are left out."
  [plan]
  (let [[from to] (or (:range plan) [0 Long/MAX_VALUE])
        from (long from) to (long to)
        skip (:skip plan)]
    (for [seg (:segments (:table plan))
          :let [start (long (:start seg))
                lo (max 0 (- from start))
                hi (min (long (:row-count seg)) (- to start))]
          :when (and (< lo hi) (segment-selected? seg skip))]
      [seg lo hi])))

(defmethod build :table-scan [plan env]
  ;; Rows have the table's full width; only the scanned columns are filled.
  (let [table (:table plan)
        width (count (:columns table))
        columns (:columns plan)
        positions (long-array columns)
        qctx (:ctx env)]
    (reducible
     (fn [f init]
       (loop [segs (seq (scan-segments plan)) acc init]
         (if (or (nil? segs) (reduced? acc))
           (unreduced acc)
           (let [[seg lo hi] (first segs)
                 vectors (scan-vectors seg columns)
                 hi (long hi)
                 acc (loop [r (long lo) acc acc]
                       (if (or (= r hi) (reduced? acc))
                         acc
                         (do
                           (when (zero? (rem r check-interval)) (ctx/check! qctx))
                           (let [row (object-array width)]
                             (fill-row! row vectors positions r)
                             (recur (inc r) (f acc row))))))]
             (recur (next segs) acc))))))))

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
  (build-input (:input plan) env))

;; ---------------------------------------------------------------------------
;; Row-wise operators

(defmethod build :filter [plan env]
  (let [pred (expr/compile-predicate env (:predicate plan))]
    (eduction (filter pred) (build-input (:input plan) env))))

(defmethod build :project [plan env]
  (let [^objects fs (into-array Object (map #(expr/compile-expr env %) (:exprs plan)))
        n (alength fs)]
    (eduction (map (fn [row]
                     (let [out (object-array n)]
                       (dotimes [i n]
                         (aset out i ((aget fs i) row)))
                       out)))
              (build-input (:input plan) env))))

(defn eval-count-clause
  "Evaluates a constant LIMIT/OFFSET expression to a non-negative long or nil."
  [env e what]
  (when e
    (let [x (expr/eval-constant env e)]
      (when (and (some? x) (neg? (long x)))
        (err/fail! "INVALID_ARGUMENT" (str what " must not be negative")))
      x)))

(defmethod build :union-all [plan env]
  ;; UNION ALL: input after input (`cat` stops early on reduced)
  (eduction cat (mapv #(build-input % env) (:inputs plan))))

(defmethod build :limit [plan env]
  (let [limit (eval-count-clause env (:limit plan) "LIMIT")
        offset (eval-count-clause env (:offset plan) "OFFSET")
        xf (cond-> (drop (long (or offset 0)))
             limit (comp (take (long limit))))]
    (eduction xf (build-input (:input plan) env))))

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

(defn- compile-aggregation
  "Compiled group key and aggregate argument functions of an aggregate node."
  [plan env]
  (let [specs (:aggregates plan)]
    {:factories (into-array Object (map agg/accumulator-factory specs))
     :arg-fns (into-array Object (map #(if-let [a (:arg %)] (expr/compile-expr env a) (constantly nil))
                                      specs))
     :key-fns (into-array Object (map #(expr/compile-expr env %) (:group-keys plan)))}))

(defn aggregate-partial
  "Aggregates the rows of `input` (a re-reducible) for aggregate node plan:
  {:groups HashMap key → entry, :order ArrayList of entries in order of
  first appearance}; an entry is [key-values accumulators] (Object arrays)."
  [plan input env]
  (let [qctx (:ctx env)
        {:keys [^objects factories ^objects arg-fns ^objects key-fns]} (compile-aggregation plan env)
        nkeys (alength key-fns)
        naggs (alength factories)
        groups (HashMap.)
        order (ArrayList.)]
    (when (zero? nkeys)
      (let [e (object-array [(object-array 0) (new-accumulators factories)])]
        (.put groups [] e)
        (.add order e)))
    (reduce (fn [_ row]
              (let [vals (object-array nkeys)
                    _ (dotimes [i nkeys] (aset vals i ((aget key-fns i) row)))
                    k (if (zero? nkeys) [] (row-key vals))
                    ^objects entry (or (.get groups k)
                                       (let [e (object-array [vals (new-accumulators factories)])]
                                         (when (zero? (rem (.size order) 1024))
                                           (ctx/check! qctx)
                                           (ctx/reserve! qctx (* 1024 (ctx/row-bytes (+ nkeys naggs)))))
                                         (.put groups k e)
                                         (.add order e)
                                         e))
                    ^objects accs (aget entry 1)]
                (dotimes [i naggs]
                  (.add ^Accumulator (aget accs i) ((aget arg-fns i) row)))
                nil))
            nil input)
    {:groups groups :order order}))

(defn aggregate-merge!
  "Merges partial aggregation `other` into `into` (groups new to `into` are
  appended in their order in `other`). Returns `into`."
  [into other]
  (let [^HashMap groups (:groups into)
        ^ArrayList order (:order into)]
    (doseq [^objects e (:order other)]
      (let [k (let [^objects vals (aget e 0)]
                (if (zero? (alength vals)) [] (row-key vals)))
            ^objects mine (.get groups k)]
        (if mine
          (let [^objects a (aget mine 1) ^objects b (aget e 1)]
            (dotimes [i (alength a)]
              (.merge ^Accumulator (aget a i) (aget b i))))
          (do (.put groups k e)
              (.add order e)))))
    into))

(defn aggregate-rows
  "Result rows (group keys followed by aggregate values) of a partial
  aggregation, in order of first appearance."
  ^ArrayList [{:keys [^ArrayList order]}]
  (let [out (ArrayList. (.size order))]
    (doseq [^objects e order]
      (let [^objects key-vals (aget e 0)
            ^objects accs (aget e 1)
            nkeys (alength key-vals)
            naggs (alength accs)
            row (object-array (+ nkeys naggs))]
        (System/arraycopy key-vals 0 row 0 nkeys)
        (dotimes [i naggs] (aset row (+ nkeys i) (.result ^Accumulator (aget accs i))))
        (.add out row)))
    out))

(defmethod build :hash-aggregate [plan env]
  (let [input (build-input (:input plan) env)]
    (reducible
     (fn [f init]
       (reduce-list (aggregate-rows (aggregate-partial plan input env)) f init)))))

(defmethod build :distinct [plan env]
  (let [input (build-input (:input plan) env)
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

(defn- key-comparator
  "Comparator of rows by one sort key (NULLs placed as requested)."
  ^Comparator [{:keys [index type desc? nulls-first?]}]
  (let [i (int index)
        sign (if desc? -1 1)
        null-x (if nulls-first? -1 1)
        long-kind? (t/long-repr? type)
        ^Comparator c (v/value-comparator type)]
    (if long-kind?
      (reify Comparator
        (compare [_ a b]
          (let [x (aget ^objects a i) y (aget ^objects b i)]
            (cond
              (nil? x) (if (nil? y) 0 null-x)
              (nil? y) (- null-x)
              :else (* sign (Long/compare (long x) (long y)))))))
      (reify Comparator
        (compare [_ a b]
          (let [x (aget ^objects a i) y (aget ^objects b i)]
            (cond
              (nil? x) (if (nil? y) 0 null-x)
              (nil? y) (- null-x)
              :else (* sign (Integer/signum (.compare c x y))))))))))

(defn row-comparator
  "Comparator of rows by sort keys (ORDER BY semantics)."
  ^Comparator [keys]
  (let [^objects cmps (into-array Comparator (map key-comparator keys))
        n (alength cmps)]
    (if (= 1 n)
      (aget cmps 0)
      (reify Comparator
        (compare [_ a b]
          (loop [i 0]
            (if (< i n)
              (let [r (.compare ^Comparator (aget cmps i) a b)]
                (if (zero? r) (recur (inc i)) r))
              0)))))))

(defn checking-comparator
  "Wraps cmp so that a long sort observes timeout/cancellation (checked
  every 65,536 comparisons)."
  ^Comparator [^Comparator cmp qctx]
  (let [n (long-array 1)]
    (reify Comparator
      (compare [_ a b]
        (let [k (aget n 0)]
          (aset n 0 (inc k))
          (when (zero? (bit-and k 0xFFFF)) (ctx/check! qctx)))
        (.compare cmp a b)))))

(defmethod build :sort [plan env]
  (let [input (build-input (:input plan) env)
        cmp (row-comparator (:keys plan))]
    (reducible
     (fn [f init]
       (let [rows (materialize input env)]
         (.sort rows (checking-comparator cmp (:ctx env)))
         (reduce-list rows f init))))))

;; ---------------------------------------------------------------------------
;; Top-N (ORDER BY … LIMIT)

(deftype Candidate [row ^long ord])

(defn candidate-comparator
  "Orders candidates by cmp on their rows, ties by ordinal (input order)."
  ^Comparator [^Comparator cmp]
  (reify Comparator
    (compare [_ a b]
      (let [r (.compare cmp (.-row ^Candidate a) (.-row ^Candidate b))]
        (if (zero? r)
          (Long/compare (.-ord ^Candidate a) (.-ord ^Candidate b))
          r)))))

(defn top-candidates
  "The k first rows of re-reducible `input` in the order of cmp (ties in
  input order) as Candidates, ascending; a candidate's ordinal is `base`
  plus its input position. A bounded heap keeps memory at O(k)."
  ^ArrayList [input ^Comparator cmp k base env]
  (let [k (long k)
        base (long base)
        ccmp (candidate-comparator cmp)
        heap (PriorityQueue. (int (max 1 (min k 4096))) (.reversed ccmp))
        qctx (:ctx env)
        n (long-array 1)]
    ;; the input is consumed completely even for LIMIT 0: its expressions
    ;; are evaluated (and may fail) exactly as for a full sort
    (reduce (fn [_ row]
              (let [i (aget n 0)]
                (aset n 0 (inc i))
                (when (zero? (rem i check-interval)) (ctx/check! qctx))
                (cond
                  (zero? k) nil
                  (< (.size heap) k)
                  (do (when (zero? (rem (.size heap) check-interval))
                        (ctx/reserve! qctx (* check-interval (ctx/row-bytes (alength ^objects row)))))
                      (.add heap (Candidate. row (+ base i))))
                  ;; a later row only replaces the current maximum when strictly smaller
                  (neg? (.compare cmp row (.-row ^Candidate (.peek heap))))
                  (do (.poll heap)
                      (.add heap (Candidate. row (+ base i))))))
              nil)
            nil input)
    (let [out (ArrayList. heap)]
      (.sort out ccmp)
      out)))

(defn top-n-bounds
  "[k offset] of a top-n node: k = LIMIT + OFFSET rows to keep (nil = no
  LIMIT)."
  [plan env]
  (let [limit (eval-count-clause env (:limit plan) "LIMIT")
        offset (long (or (eval-count-clause env (:offset plan) "OFFSET") 0))]
    [(when (some? limit)
       (let [limit (long limit)]
         (if (> limit (- Long/MAX_VALUE offset)) Long/MAX_VALUE (+ limit offset))))
     offset]))

(defn emit-candidates
  "Reduces f over the rows of the sorted candidates, skipping `offset`."
  [^ArrayList cands ^long offset f init]
  (let [n (.size cands)]
    (loop [i offset acc init]
      (if (or (>= i n) (reduced? acc))
        (unreduced acc)
        (recur (inc i) (f acc (.-row ^Candidate (.get cands i))))))))

(defmethod build :top-n [plan env]
  (let [input (build-input (:input plan) env)
        cmp (row-comparator (:keys plan))]
    (reducible
     (fn [f init]
       (let [[k offset] (top-n-bounds plan env)
             offset (long offset)]
         (if (nil? k)
           (let [rows (materialize input env)]
             (.sort rows (checking-comparator cmp (:ctx env)))
             (reduce-list (.subList rows (int (min offset (.size rows))) (.size rows)) f init))
           (emit-candidates (top-candidates input cmp k 0 env) offset f init)))))))
