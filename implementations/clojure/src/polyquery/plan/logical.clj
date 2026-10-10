(ns polyquery.plan.logical
  "Logical planning: turns a bound query (polyquery.sql.analyzer) into a tree
  of relational operators. Expressions stay bound expressions; nested queries
  in expressions are planned later (polyquery.plan.physical).

  Logical nodes ({:op …}); every node carries :width (columns per row):
    {:op :values  :rows [[…]]}                      ; constant rows (no FROM)
    {:op :scan    :table T :alias a :columns [i …]}  ; table columns read
    {:op :derived :alias a :input P}                ; derived table / CTE
    {:op :join    :kind :inner|:left|:cross :left P :right P :condition e}
    {:op :filter  :input P :predicate e}
    {:op :aggregate :input P :group-keys [e] :aggregates [spec]}
    {:op :project :input P :exprs [e] :names [n]}
    {:op :distinct :input P}
    {:op :sort    :input P :keys [{:index i :type T :desc? b :nulls-first? b}]}
    {:op :limit   :input P :limit e|nil :offset e|nil}
  The root of a query plan also carries :columns [{:name :type}].")

(set! *warn-on-reflection* true)

(declare plan-query)

(defn plan-relation
  [rel]
  (case (:rel rel)
    :scan (let [n (count (:columns (:table rel)))]
            {:op :scan :table (:table rel) :alias (:name rel) :columns (vec (range n)) :width n})
    :query {:op :derived :alias (:name rel) :input (plan-query (:query rel))
            :width (count (:columns rel))}
    :join (let [l (plan-relation (:left rel))
                r (plan-relation (:right rel))]
            {:op :join :kind (:kind rel) :left l :right r :condition (:on rel)
             :width (+ (long (:width l)) (long (:width r)))})))

(defn- sort-keys
  "Sort keys over the projected row (outputs followed by hidden ORDER BY
  expressions)."
  [outputs order-by]
  (let [n-out (count outputs)]
    (loop [items order-by hidden-idx n-out acc []]
      (if-let [item (first items)]
        (let [[idx next-hidden] (if (contains? item :output)
                                  [(:output item) hidden-idx]
                                  [hidden-idx (inc hidden-idx)])
              t (if (< idx n-out) (:type (nth outputs idx)) (:type (:expr item)))]
          (recur (rest items) (long next-hidden)
                 (conj acc {:index idx :type t :desc? (:desc? item)
                            :nulls-first? (:nulls-first? item)})))
        acc))))

(defn plan-query
  "Builds the logical plan of a bound query."
  [bq]
  (let [{:keys [from where aggregated? group-keys aggregates having outputs distinct?
                order-by limit offset]} bq
        n-out (count outputs)
        base (if from (plan-relation from) {:op :values :rows [[]] :width 0})
        filtered (if where {:op :filter :input base :predicate where :width (:width base)} base)
        agg (if aggregated?
              {:op :aggregate :input filtered :group-keys group-keys :aggregates aggregates
               :width (+ (count group-keys) (count aggregates))}
              filtered)
        having-node (if having {:op :filter :input agg :predicate having :width (:width agg)} agg)
        hidden (vec (keep :expr order-by))
        project {:op :project :input having-node :exprs (into (mapv :expr outputs) hidden)
                 :names (into (mapv :name outputs) (map #(str "_sort" %) (range (count hidden))))
                 :width (+ n-out (count hidden))}
        distinct-node (if distinct? {:op :distinct :input project :width (:width project)} project)
        ks (sort-keys outputs order-by)
        sorted (if (seq ks) {:op :sort :input distinct-node :keys ks :width (:width distinct-node)}
                   distinct-node)
        limited (if (or limit offset)
                  {:op :limit :input sorted :limit limit :offset offset :width (:width sorted)}
                  sorted)
        result (if (seq hidden)
                 {:op :project :input limited
                  :exprs (vec (map-indexed (fn [i o] {:node :column :type (:type o) :index i :name (:name o)})
                                           outputs))
                  :names (mapv :name outputs)
                  :width n-out}
                 limited)]
    (assoc result :columns (:columns bq))))
