(ns polyquery.exec.operators
  "Row-at-a-time execution of plan trees (polyquery.sql.planner). Every
  operator evaluates to a reducible (clojure.lang.IReduceInit) of rows, each
  row an Object array; pipelines are built from transducers so rows stream
  through filter/project/limit without intermediate collections."
  (:require [polyquery.exec.aggregate :as agg]
            [polyquery.exec.context :as ctx]
            [polyquery.exec.expr :as expr]
            [polyquery.values :as v])
  (:import (java.util ArrayList Comparator HashMap)
           (polyquery.exec.aggregate Accumulator)))

(set! *warn-on-reflection* true)

(def ^:private check-interval 4096)

(defmulti execute
  "Returns a reducible of rows for plan node `plan` in environment `env`
  ({:ctx QueryContext})."
  (fn [plan _env] (:op plan)))

(defmethod execute :values [plan _env]
  (mapv object-array (:rows plan)))

(defmethod execute :scan [plan env]
  (let [table (:table plan)
        ^objects cols (into-array Object (map #(nth (:data table) %) (:columns plan)))
        ncols (alength cols)
        n (long (:row-count table))
        qctx (:ctx env)]
    (reify clojure.lang.IReduceInit
      (reduce [_ f init]
        (loop [r 0 acc init]
          (if (or (= r n) (reduced? acc))
            (unreduced acc)
            (do
              (when (zero? (rem r check-interval)) (ctx/check! qctx))
              (let [row (object-array ncols)]
                (dotimes [c ncols]
                  (aset row c (aget ^objects (aget cols c) r)))
                (recur (inc r) (f acc row))))))))))

(defmethod execute :filter [plan env]
  (let [pred (expr/compile-predicate env (:predicate plan))]
    (eduction (filter pred) (execute (:input plan) env))))

(defmethod execute :project [plan env]
  (let [^objects fs (into-array Object (map #(expr/compile-expr env %) (:exprs plan)))
        n (alength fs)]
    (eduction (map (fn [row]
                     (let [out (object-array n)]
                       (dotimes [i n]
                         (aset out i ((aget fs i) row)))
                       out)))
              (execute (:input plan) env))))

(defn- new-accumulators ^objects [factories]
  (let [^objects fs factories
        accs (object-array (alength fs))]
    (dotimes [i (alength fs)] (aset accs i ((aget fs i))))
    accs))

(defmethod execute :aggregate [plan env]
  (let [qctx (:ctx env)
        specs (:aggregates plan)
        factories (into-array Object (map agg/accumulator-factory specs))
        arg-fns (into-array Object (map #(if-let [a (:arg %)] (expr/compile-expr env a) (constantly nil))
                                        specs))
        key-fns (mapv #(expr/compile-expr env %) (:group-keys plan))
        nkeys (count key-fns)
        naggs (count specs)
        feed (fn [^objects accs row]
               (dotimes [i naggs]
                 (.add ^Accumulator (aget accs i) ((aget ^objects arg-fns i) row))))
        finish (fn [key-vals ^objects accs]
                 (let [out (object-array (+ nkeys naggs))]
                   (dotimes [i nkeys] (aset out i (nth key-vals i)))
                   (dotimes [i naggs] (aset out (+ nkeys i) (.result ^Accumulator (aget accs i))))
                   out))
        input (execute (:input plan) env)]
    (if (zero? nkeys)
      (let [accs (new-accumulators factories)]
        (reduce (fn [_ row] (feed accs row) nil) nil input)
        [(finish [] accs)])
      (let [groups (HashMap.)
            order (ArrayList.)]
        (reduce (fn [_ row]
                  (let [k (mapv #(v/normalize-key (% row)) key-fns)
                        accs (or (.get groups k)
                                 (let [a (new-accumulators factories)]
                                   (ctx/reserve! qctx (ctx/row-bytes (+ nkeys naggs)))
                                   (.put groups k a)
                                   (.add order k)
                                   a))]
                    (feed accs row)
                    nil))
                nil input)
        (mapv #(finish % (.get groups %)) order)))))

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

(defmethod execute :sort [plan env]
  (let [qctx (:ctx env)
        rows (ArrayList.)]
    (reduce (fn [_ ^objects row]
              (when (zero? (rem (.size rows) check-interval))
                (ctx/check! qctx)
                (ctx/reserve! qctx (* check-interval (ctx/row-bytes (alength row)))))
              (.add rows row)
              nil)
            nil (execute (:input plan) env))
    (.sort rows (row-comparator (:keys plan)))
    rows))

(defmethod execute :limit [plan env]
  (let [{:keys [limit offset]} plan
        xf (cond-> (drop (long offset))
             limit (comp (take (long limit))))]
    (eduction xf (execute (:input plan) env))))
