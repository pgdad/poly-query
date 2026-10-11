(ns polyquery.exec.sort-test
  "Randomized check of the ORDER BY sort (MSD radix over key codes) against
  a reference stable comparison sort."
  (:require [clojure.test :refer [deftest is testing]]
            [polyquery.exec.context :as ctx]
            [polyquery.exec.sort :as sort]
            [polyquery.values :as v])
  (:import (java.util ArrayList Comparator Random)))

(def ^:private strings
  ["" "a" "ab" "abc" "abcd" "abcde" "abd" "b" "a\u0000" "a\u0000b" "\u0000" "zzzzzzzzzzzz"
   "" "😀" "😀x" "￿" "é" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab"
   "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"])

(defn- random-value [^Random rnd type]
  (when-not (zero? (.nextInt rnd 6))
    (case type
      :int64 (case (.nextInt rnd 4)
               0 (.nextLong rnd)
               1 (rand-nth [Long/MIN_VALUE Long/MAX_VALUE 0 -1])
               (long (- (.nextInt rnd 40) 20)))
      :float64 (case (.nextInt rnd 3)
                 0 (.nextDouble rnd)
                 1 (rand-nth [0.0 -0.0 -1.5 1.5 Double/MAX_VALUE (- Double/MAX_VALUE) Double/MIN_VALUE])
                 (double (- (.nextInt rnd 10) 5)))
      :boolean (.nextBoolean rnd)
      :string (if (zero? (.nextInt rnd 3))
                (rand-nth strings)
                (apply str (repeatedly (.nextInt rnd 8) #(char (+ 97 (.nextInt rnd 3)))))))))

(defn- reference-sort
  "Stable sort of the rows by keys (types.md §7) with a plain comparator."
  [rows keys]
  (let [cmps (mapv (fn [{:keys [index type desc? nulls-first?]}]
                     (let [^Comparator c (v/value-comparator type)]
                       (fn [a b]
                         (let [x (aget ^objects a index) y (aget ^objects b index)]
                           (cond (and (nil? x) (nil? y)) 0
                                 (nil? x) (if nulls-first? -1 1)
                                 (nil? y) (if nulls-first? 1 -1)
                                 :else (cond-> (.compare c x y) desc? -))))))
                   keys)]
    (sort (fn [a b] (or (some #(let [r (% a b)] (when-not (zero? r) r)) cmps) 0)) rows)))

(deftest sort-matches-reference
  (let [rnd (Random. 42)
        run-all (fn [thunks] (mapv deref (mapv #(future (%)) thunks)))]
    (doseq [trial (range 60)]
      (let [types (vec (repeatedly (inc (.nextInt rnd 3)) #(rand-nth [:int64 :float64 :boolean :string])))
            n (rand-nth [0 1 5 31 33 200 3000])
            rows (vec (for [i (range n)]
                        (object-array (conj (mapv #(random-value rnd %) types) i))))
            keys (vec (for [i (shuffle (range (count types)))]
                        (let [desc? (.nextBoolean rnd)]
                          {:index i :type (types i) :desc? desc?
                           :nulls-first? (if (.nextBoolean rnd) desc? (not desc?))})))
            id #(aget ^objects % (count types))]
        (testing (str "trial " trial " " types " " keys)
          (is (= (map id (reference-sort rows keys))
                 (map id (sort/sort-rows (ArrayList. ^java.util.Collection rows) keys
                                         (ctx/make-context {}) run-all (inc (.nextInt rnd 4)))))))))))
