(ns polyquery.sql.planner
  "Logical planning: turns a bound query into an operator tree.

  Plan nodes ({:op …}):
    {:op :values  :rows [[…]]}                         ; constant rows (SELECT without FROM)
    {:op :scan    :table T :columns [i …]}             ; row = selected table columns
    {:op :filter  :input P :predicate e}
    {:op :aggregate :input P :group-keys [e] :aggregates [spec]}
    {:op :project :input P :exprs [e]}
    {:op :sort    :input P :keys [{:index i :type T :desc? b :nulls-first? b}]}
    {:op :limit   :input P :limit n|nil :offset n}
  Each plan carries :columns [{:name :type}] describing its output row.")

(defn- scan-node [{:keys [table]}]
  {:op :scan
   :table table
   :columns (vec (range (count (:columns table))))})

(defn plan-query
  "Builds the plan for a bound query. `limit`/`offset` are already evaluated
  numbers (or nil)."
  [bq limit offset]
  (let [{:keys [source where aggregated? group-keys aggregates having outputs order-by]} bq
        base (if source (scan-node source) {:op :values :rows [[]]})
        filtered (if where {:op :filter :input base :predicate where} base)
        aggregated (if aggregated?
                     {:op :aggregate :input filtered :group-keys group-keys :aggregates aggregates}
                     filtered)
        having-node (if having {:op :filter :input aggregated :predicate having} aggregated)
        out-exprs (mapv :expr outputs)
        hidden (vec (keep :expr order-by))
        n-out (count out-exprs)
        project {:op :project :input having-node :exprs (into out-exprs hidden)}
        sort-keys (loop [items order-by hidden-idx n-out acc []]
                    (if-let [item (first items)]
                      (let [[idx next-hidden] (if (contains? item :output)
                                                [(:output item) hidden-idx]
                                                [hidden-idx (inc hidden-idx)])
                            t (if (< idx n-out) (:type (nth outputs idx)) (:type (:expr item)))]
                        (recur (rest items) (long next-hidden)
                               (conj acc {:index idx :type t :desc? (:desc? item)
                                          :nulls-first? (:nulls-first? item)})))
                      acc))
        sorted (if (seq sort-keys) {:op :sort :input project :keys sort-keys} project)
        limited (if (or limit (and offset (pos? (long offset))))
                  {:op :limit :input sorted :limit limit :offset (or offset 0)}
                  sorted)
        result (if (seq hidden)
                 {:op :project :input limited
                  :exprs (vec (map-indexed (fn [i o] {:node :column :type (:type o) :index i :name (:name o)})
                                           outputs))}
                 limited)]
    (assoc result :columns (mapv #(select-keys % [:name :type]) outputs))))
