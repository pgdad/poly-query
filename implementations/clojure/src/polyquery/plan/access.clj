(ns polyquery.plan.access
  "Access paths of base-table scans (spec/storage/indexes-and-planning.md
  §2-§3): recognition of simple column predicates in the conjuncts filtering
  a scan, row-group skipping by chunk min/max statistics, selectivity
  estimation and index selection.

  A *column predicate* describes a conjunct `col <op> constant`:
    {:column i :type T :op op :values [{:value v :type C :cmp-type K}] :sql s}
  where op is one of \"=\" \"<>\" \"<\" \"<=\" \">\" \">=\" :in :is-null
  :not-null, T is the column type, C the constant's type and K the
  comparison type. BETWEEN yields two predicates (>= low, <= high).
  Constants are folded at planning time; a constant whose evaluation fails is
  simply not used (the filter evaluates it at run time as usual)."
  (:require [polyquery.exec.context :as ctx]
            [polyquery.exec.expr :as expr]
            [polyquery.sql.bound :as b]
            [polyquery.storage.index :as index]
            [polyquery.storage.stats :as stats]
            [polyquery.types :as t]
            [polyquery.values :as v]))

(set! *warn-on-reflection* true)

(def max-index-selectivity
  "An index scan is chosen when at most this fraction of rows qualifies."
  0.1)

(def max-point-lookup-rows
  "An equality/IN index lookup is also chosen when it is estimated to return
  at most this many rows (on small tables a lookup returning a handful of
  rows is never more expensive than a scan)."
  16)

(def ^:private mirrored {"=" "=" "<>" "<>" "<" ">" "<=" ">=" ">" "<" ">=" "<="})

;; ---------------------------------------------------------------------------
;; Column predicates

(defn- constant-value
  "[value] of a foldable constant expression, or nil."
  [e]
  (when (and (b/constant? e) (not-any? #(= :call (:node %)) (b/nodes e)))
    (try [(expr/eval-constant {:cells (atom {}) :ctx (ctx/make-context {})} e)]
         (catch Exception _ nil))))

(defn- column? [e] (= :column (:node e)))

(defn- comparison
  [e]
  (let [{:keys [op left right cmp-type]} e
        [c x op] (cond (column? left) [left right op]
                       (column? right) [right left (mirrored op)])]
    (when-let [[value] (and c (constant-value x))]
      [{:column (:index c) :type (:type c) :op op
        :values [{:value value :type (:type x) :cmp-type cmp-type}] :sql (b/->sql e)}])))

(defn- between [e]
  (let [{:keys [arg low high low-type high-type]} e
        lv (constant-value low)
        hv (constant-value high)]
    (when (and (column? arg) (not (:not? e)) lv hv)
      (let [base {:column (:index arg) :type (:type arg) :sql (b/->sql e)}]
        [(assoc base :op ">=" :values [{:value (first lv) :type (:type low) :cmp-type low-type}])
         (assoc base :op "<=" :values [{:value (first hv) :type (:type high) :cmp-type high-type}])]))))

(defn- in-list [e]
  (let [{:keys [arg items cmp-types]} e
        vals (map constant-value items)]
    (when (and (column? arg) (not (:not? e)) (every? some? vals))
      [{:column (:index arg) :type (:type arg) :op :in :sql (b/->sql e)
        :values (mapv (fn [[x] item ct] {:value x :type (:type item) :cmp-type ct})
                      vals items cmp-types)}])))

(defn column-predicates
  "Column predicates recognized among the conjuncts of a predicate over a
  scan row."
  [conjuncts]
  (vec (mapcat (fn [e]
                 (case (:node e)
                   :compare (comparison e)
                   :between (between e)
                   :in-list (in-list e)
                   :is-null (when (column? (:arg e))
                              [{:column (:index (:arg e)) :type (:type (:arg e))
                                :op (if (:not? e) :not-null :is-null) :values [] :sql (b/->sql e)}])
                   nil))
               conjuncts)))

;; ---------------------------------------------------------------------------
;; Row-group skipping

(defn- compare-fn
  "(fn [column-value constant]) → int for a predicate value."
  [col-type {:keys [type cmp-type]}]
  (v/comparator-fn cmp-type col-type type))

(defn- value-may-match?
  [op cmp mn mx value]
  (let [lo (long (cmp mn value))
        hi (long (cmp mx value))]
    (case op
      ("=" :in) (and (<= lo 0) (>= hi 0))
      "<>" (not (and (zero? lo) (zero? hi)))
      "<" (neg? lo)
      "<=" (<= lo 0)
      ">" (pos? hi)
      ">=" (>= hi 0))))

(defn segment-may-match?
  "False when the chunk statistics {:min :max :null-count} of a segment with
  `rows` rows prove that no row satisfies column predicate p."
  [p chunk-stats ^long rows]
  (let [{:keys [min max null-count]} chunk-stats
        nulls (long (or null-count 0))
        op (:op p)]
    (case op
      :is-null (or (nil? null-count) (pos? nulls))
      :not-null (or (nil? null-count) (< nulls rows))
      (cond
        (and null-count (= nulls rows)) false
        (some #(nil? (:value %)) (:values p)) (boolean (seq (remove #(nil? (:value %)) (:values p))))
        (or (nil? min) (nil? max)) true
        :else (boolean (some (fn [pv]
                               (value-may-match? op (compare-fn (:type p) pv) min max (:value pv)))
                             (:values p)))))))

(defn skip-predicates
  "Column predicates usable for row-group skipping (all but <>, which is
  rarely selective)."
  [preds]
  (filterv #(not= "<>" (:op %)) preds))

;; ---------------------------------------------------------------------------
;; Selectivity (indexes-and-planning.md §3.3)

(defn- k-double
  "A value of type `type` as a double in the domain of comparison type k."
  [type k x]
  (let [y ((v/key-fn type k) x)]
    (.doubleValue ^Number y)))

(defn- interpolable? [t] (or (t/numeric? t) (t/temporal? t)))

(defn range-selectivity
  "Fraction of values in [min, max] satisfying the range predicates (linear
  interpolation for numeric/temporal types, 1/3 otherwise)."
  [col-type mn mx range-preds]
  (cond
    (or (nil? mn) (nil? mx)) 0.0
    (not (interpolable? col-type)) (/ 1.0 3.0)
    :else
    (let [k (:cmp-type (first (:values (first range-preds))))
          lo0 (k-double col-type k mn)
          hi0 (k-double col-type k mx)
          bound (fn [p] (let [pv (first (:values p))] (k-double (:type pv) (:cmp-type pv) (:value pv))))
          lo (reduce max lo0 (map bound (filter #(#{">" ">="} (:op %)) range-preds)))
          hi (reduce min hi0 (map bound (filter #(#{"<" "<="} (:op %)) range-preds)))]
      (cond
        (> lo hi) 0.0
        (== hi0 lo0) 1.0
        :else (/ (- hi lo) (- hi0 lo0))))))

(defn equality-selectivity
  [^long distinct ^long nvalues]
  (if (pos? distinct) (min 1.0 (/ (double nvalues) distinct)) 0.0))

(defn- range-pred? [p] (contains? #{"<" "<=" ">" ">="} (:op p)))

(defn- equality-pred? [p] (contains? #{"=" :in} (:op p)))

(defn- usable-value? [pv] (and (some? (:value pv)) (not= :null (:cmp-type pv))))

;; ---------------------------------------------------------------------------
;; Index selection

(defn- hash-compatible?
  "True when values compared in type k have the same hash keys as the
  column's own values (so a HASH index can be probed)."
  [col-type k]
  (and (= (t/kind col-type) (t/kind k)) (= (t/scale col-type) (t/scale k))))

(defn- bound [pv inclusive?]
  (assoc (select-keys pv [:value :type :cmp-type]) :inclusive? inclusive?))

(defn- equality-candidate
  [idx p]
  (let [pvs (:values p)
        col-type (:type p)]
    (when (every? usable-value? pvs)
      (let [n (count (distinct (map :value pvs)))
            sel (equality-selectivity (index/distinct-count idx) n)]
        (cond
          (= :btree (:kind idx))
          {:index idx :selectivity sel :predicates [p] :point? true
           :lookup {:kind :ranges :ranges (mapv (fn [pv] {:lowers [(bound pv true)] :uppers [(bound pv true)]})
                                                pvs)}}
          (every? #(hash-compatible? col-type (:cmp-type %)) pvs)
          {:index idx :selectivity sel :predicates [p] :point? true
           :lookup {:kind :keys :keys (mapv (fn [pv] ((v/key-fn (:type pv) (:cmp-type pv)) (:value pv)))
                                            pvs)}})))))

(defn- range-candidate
  [idx preds]
  (let [ranges (filter range-pred? preds)]
    (when (and (= :btree (:kind idx)) (seq ranges)
               (every? #(usable-value? (first (:values %))) ranges))
      (let [col-type (:type (first ranges))]
        {:index idx :predicates (vec ranges)
         :selectivity (range-selectivity col-type (index/smallest-key idx) (index/largest-key idx) ranges)
         :lookup {:kind :ranges
                  :ranges [{:lowers (vec (for [p ranges :when (#{">" ">="} (:op p))]
                                           (bound (first (:values p)) (= ">=" (:op p)))))
                            :uppers (vec (for [p ranges :when (#{"<" "<="} (:op p))]
                                           (bound (first (:values p)) (= "<=" (:op p)))))}]}}))))

(defn choose-index
  "The most selective index access for the column predicates over a scan of
  `table`, or nil when no index qualifies (see max-index-selectivity and
  max-point-lookup-rows)."
  [table preds]
  (let [by-column (group-by :column preds)
        candidates (for [idx (:indexes table)
                         :let [ps (get by-column (:column-index idx))]
                         :when (seq ps)
                         c (concat (keep #(equality-candidate idx %) (filter equality-pred? ps))
                                   [(range-candidate idx ps)])
                         :when c]
                     c)
        rows (double (:row-count table))
        qualifies? (fn [{:keys [selectivity point?]}]
                     (or (<= (double selectivity) max-index-selectivity)
                         (and point? (<= (* rows (double selectivity)) (double max-point-lookup-rows)))))]
    (first (sort-by :selectivity (filter qualifies? candidates)))))

;; ---------------------------------------------------------------------------
;; Selectivity of filters from table statistics (cardinality estimates)

(defn predicate-selectivity
  "Estimated fraction of a table's rows satisfying column predicate p."
  [table p]
  (let [{:keys [null-count distinct-count min max]} (stats/column-stats table (:column p))
        rows (long (:row-count table))]
    (if (zero? rows)
      0.0
      (case (:op p)
        :is-null (/ (double null-count) rows)
        :not-null (- 1.0 (/ (double null-count) rows))
        ("=" :in) (equality-selectivity distinct-count (count (:values p)))
        "<>" (- 1.0 (equality-selectivity distinct-count 1))
        (if (every? #(usable-value? (first (:values %))) [p])
          (range-selectivity (:type p) min max [p])
          (/ 1.0 3.0))))))
