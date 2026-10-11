(ns polyquery.exec.vectorized-test
  "Unit tests of the Phase 5 execution components: batches and kernels,
  group tables and aggregate states, the primitive-column sort and the
  parallelization planner."
  (:require [clojure.test :refer [deftest is testing]]
            [polyquery.exec.batch :as b]
            [polyquery.exec.context :as ctx]
            [polyquery.exec.grouping :as g]
            [polyquery.exec.kernels :as k]
            [polyquery.exec.sort :as sort]
            [polyquery.plan.parallel :as par]
            [polyquery.types :as t])
  (:import (polyquery.exec.batch Batch LongVec)
           (polyquery.exec.grouping AggState GroupTable)))

(defn- long-vec [xs]
  (let [v (b/new-vec :int64)]
    (doseq [[i x] (map-indexed vector xs)] (.setObj v i x))
    v))

(defn- eval-on [e cols n]
  (let [bt (Batch. (object-array cols) b/identity-sel n)
        v (k/ev (k/compile-kernel {:ctx nil :cells (atom {})} e) bt b/identity-sel n)]
    (mapv #(.getObj v %) (range n))))

(def col0 {:node :column :index 0 :type :int64 :name "a"})
(def col1 {:node :column :index 1 :type :int64 :name "b"})
(defn- lit [v type] {:node :literal :value v :type type})

(deftest kernels-follow-sql-semantics
  (let [a (long-vec [1 nil 3 0 -5])
        c (long-vec [2 2 nil 0 5])]
    (testing "NULL-propagating arithmetic and comparison"
      (is (= [3 nil nil 0 0] (eval-on {:node :arith :op "+" :type :int64 :left col0 :right col1} [a c] 5)))
      (is (= [true nil nil false true]
             (eval-on {:node :compare :type :boolean :op "<" :cmp-type :int64 :left col0 :right col1} [a c] 5)))
      (is (= [false nil true false false]
             (eval-on {:node :compare :type :boolean :op ">" :cmp-type :int64 :left col0 :right (lit 2 :int64)} [a c] 5))))
    (testing "three-valued AND/OR"
      (let [p {:node :compare :type :boolean :op ">" :cmp-type :int64 :left col0 :right (lit 0 :int64)}
            q {:node :compare :type :boolean :op ">" :cmp-type :int64 :left col1 :right (lit 1 :int64)}]
        (is (= [true nil nil false false] (eval-on {:node :and :type :boolean :left p :right q} [a c] 5)))
        (is (= [true true true false true] (eval-on {:node :or :type :boolean :left p :right q} [a c] 5)))))
    (testing "the right operand of AND is not evaluated where the left one is FALSE"
      (let [guard {:node :compare :type :boolean :op "<>" :cmp-type :int64 :left col1 :right (lit 0 :int64)}
            div {:node :compare :type :boolean :op ">" :cmp-type :int64
                 :left {:node :arith :op "/" :type :int64 :left col0 :right col1}
                 :right (lit 0 :int64)}]
        (is (= [false nil nil false false] (eval-on {:node :and :type :boolean :left guard :right div} [a c] 5)))))
    (testing "division by zero and overflow are detected"
      (is (thrown? clojure.lang.ExceptionInfo
                   (eval-on {:node :arith :op "/" :type :int64 :left col0 :right col1} [a c] 5)))
      (is (thrown? clojure.lang.ExceptionInfo
                   (eval-on {:node :arith :op "*" :type :int64 :left col0 :right (lit Long/MAX_VALUE :int64)}
                            [a c] 5))))))

(deftest long-key-table-groups-in-first-appearance-order
  (let [^GroupTable tbl (g/group-table [:int64])
        n 5000
        keys (long-vec (map #(when-not (zero? (mod % 97)) (mod (* % 7919) 1300)) (range 1000)))
        gids (int-array b/capacity)]
    (dotimes [_ (quot n 1000)]
      (.assign tbl (object-array [keys]) b/identity-sel 1000 gids))
    (is (= (count (distinct (map #(.getObj ^LongVec keys %) (range 1000)))) (.size tbl)))
    (is (= (.getObj ^LongVec keys 1) (aget ^objects (.keyAt tbl (aget gids 1)) 0)))
    (testing "merging tables maps every group"
      (let [^GroupTable other (g/group-table [:int64])
            o-gids (int-array b/capacity)]
        (.assign other (object-array [(long-vec [5000 nil 1])]) b/identity-sel 3 o-gids)
        (let [m (g/merge-mapping tbl other)]
          (is (= 3 (alength m)))
          (is (= [5000] (vec (.keyAt tbl (aget m 0)))))
          (is (= [nil] (vec (.keyAt tbl (aget m 1))))))))))

(deftest aggregate-states-are-exact-and-mergeable
  (let [spec {:fn :sum :arg {:node :column :index 0 :type :int64} :type :int64}
        ^AggState s1 (g/agg-state spec)
        ^AggState s2 (g/agg-state spec)
        gids (int-array b/capacity)]
    (.grow s1 1)
    (.grow s2 1)
    (.update s1 gids (long-vec [Long/MAX_VALUE 10]) b/identity-sel 2)
    (.update s2 gids (long-vec [-20 nil]) b/identity-sel 2)
    (.mergeFrom s1 s2 0 0)
    ;; MAX + 10 - 20 fits again: intermediate overflow is exact
    (is (= (- Long/MAX_VALUE 10) (.result s1 0)))))

(deftest sort-is-stable-and-handles-nulls
  (let [rows (java.util.ArrayList. ^java.util.Collection
                                   (map-indexed (fn [i x] (object-array [x i])) [3 nil 1 3 -2 nil 1]))
        run-all (fn [thunks] (mapv #(%) thunks))
        sorted (fn [keys] (mapv #(vec %) (sort/sort-rows rows keys (ctx/make-context {}) run-all 1)))]
    (testing "radix sort of one integer key"
      (is (= [[-2 4] [1 2] [1 6] [3 0] [3 3] [nil 1] [nil 5]]
             (sorted [{:index 0 :type :int64 :desc? false :nulls-first? false}])))
      (is (= [[nil 1] [nil 5] [3 0] [3 3] [1 2] [1 6] [-2 4]]
             (sorted [{:index 0 :type :int64 :desc? true :nulls-first? true}]))))
    (testing "merge sort of several keys"
      (is (= [[-2 4] [1 6] [1 2] [3 3] [3 0] [nil 5] [nil 1]]
             (sorted [{:index 0 :type :int64 :desc? false :nulls-first? false}
                      {:index 1 :type :int64 :desc? true :nulls-first? false}]))))
    (testing "large inputs, parallel chunks"
      (let [rnd (java.util.Random. 7)
            big (java.util.ArrayList. ^java.util.Collection
                                      (for [i (range 100000)] (object-array [(str (.nextInt rnd 1000)) i])))
            out (sort/sort-rows big [{:index 0 :type :string :desc? false :nulls-first? false}] (ctx/make-context {})
                                (fn [thunks] (mapv deref (mapv #(future (%)) thunks))) 4)]
        (is (= (sort-by (fn [r] [(r 0) (r 1)]) (map vec big))
               (map vec out)))))))

(defn- random-string
  "Short strings over an alphabet with ASCII, 2- and 3-byte UTF-8 characters,
  surrogate pairs, a lone surrogate and U+0000, so that 8-byte prefixes tie
  often and every UTF-8 length is cut at the prefix boundary."
  [^java.util.Random rnd]
  (let [alphabet ["a" "b" "\u0000" "\u00e9" "\u07ff" "\u0800" "\uffee" "\ud83d\ude00" "\ud800" "\ue000"]]
    (apply str (repeatedly (.nextInt rnd 7) #(alphabet (.nextInt rnd (count alphabet)))))))

(deftest multi-key-sort-matches-reference-order
  ;; reference: compare key by key with the value comparators (NULLs per
  ;; nulls-first?, DESC reverses), ties by input position
  (let [rnd (java.util.Random. 11)
        rows (vec (for [i (range 20000)]
                    (object-array [(when (pos? (.nextInt rnd 8)) (random-string rnd))
                                   (when (pos? (.nextInt rnd 8)) ([-0.0 0.0 1.5 -2.25 1e300] (.nextInt rnd 5)))
                                   (when (pos? (.nextInt rnd 8)) (long (.nextInt rnd 5)))
                                   (when (pos? (.nextInt rnd 8)) (.nextBoolean rnd))
                                   i])))
        types [:string :float64 :int64 :boolean]
        reference (fn [keys]
                    (sort (fn [^objects x ^objects y]
                            (or (some (fn [{:keys [index type desc? nulls-first?]}]
                                        (let [a (aget x index) b (aget y index)
                                              c (cond (and (nil? a) (nil? b)) 0
                                                      (nil? a) (if nulls-first? -1 1)
                                                      (nil? b) (if nulls-first? 1 -1)
                                                      :else (* (if desc? -1 1)
                                                               (Integer/signum
                                                                (.compare (polyquery.values/value-comparator type) a b))))]
                                          (when-not (zero? c) c)))
                                      keys)
                                (compare (aget x 4) (aget y 4))))
                          rows))]
    (doseq [perm [[0 1 2 3] [1 0 3 2] [2 3 0 1] [3 2 1 0]]
            flags [[false false] [true false] [false true] [true true]]]
      (let [keys (vec (for [i perm]
                        {:index i :type (types i) :desc? (first flags) :nulls-first? (second flags)}))
            out (sort/sort-rows (java.util.ArrayList. ^java.util.Collection rows) keys (ctx/make-context {})
                                (fn [thunks] (mapv deref (mapv #(future (%)) thunks))) 3)]
        (is (= (map #(aget ^objects % 4) (reference keys))
               (map #(aget ^objects % 4) out))
            (str "keys " perm " flags " flags))))))

(deftest parallelizable-pipelines
  (let [scan {:op :table-scan :table {:row-count 10} :columns []}
        sub {:node :subquery :kind :scalar}]
    (is (par/partitionable? {:op :filter :input scan :predicate col0}))
    (is (not (par/partitionable? {:op :filter :input scan :predicate {:node :compare :left col0 :right sub}})))
    (is (= :gather (:op (par/parallelize {:op :project :input scan :exprs [col0]} 4))))
    (is (= {:op :project :input scan :exprs [col0]} (par/parallelize {:op :project :input scan :exprs [col0]} 1)))
    (testing "no read-ahead below LIMIT"
      (is (not= :gather (:op (:input (par/parallelize {:op :limit :input scan} 4))))))
    (testing "aggregation is partitioned"
      (is (= 4 (:partitions (par/parallelize {:op :hash-aggregate :input scan :group-keys [] :aggregates []} 4)))))))
