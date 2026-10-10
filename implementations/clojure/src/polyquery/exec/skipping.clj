(ns polyquery.exec.skipping
  "Row-group skipping (spec/storage/indexes-and-planning.md §3.1): decides
  from a segment's chunk statistics (PQCF min/max/null_count) whether any of
  its rows can satisfy a column predicate (see polyquery.plan.access). The
  statistics are only used to skip segments, never to produce results."
  (:require [polyquery.values :as v]))

(set! *warn-on-reflection* true)

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
