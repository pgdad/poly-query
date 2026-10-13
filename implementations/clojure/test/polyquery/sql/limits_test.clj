(ns polyquery.sql.limits-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [polyquery.sql.limits :as limits]
            [polyquery.sql.parser :as parser]
            [polyquery.test-util :refer [error-code]]))

(defn- where [p] (str "SELECT count(*) FROM n WHERE " p))

(defn- depth
  "Height of an AST expression tree."
  [e]
  (if (map? e)
    (inc (reduce max 0 (map depth (concat (vals (select-keys e [:left :right :arg])) (:items e)))))
    0))

(defn- message [f]
  (try (f) nil (catch clojure.lang.ExceptionInfo e (.getMessage e))))

(deftest nesting-depth
  (let [n limits/max-nesting-depth]
    (testing "parentheses up to the limit parse"
      (is (map? (parser/parse-statement (where (str (str/join (repeat (dec n) "(")) "x >= 0"
                                                    (str/join (repeat (dec n) ")"))))))))
    (testing "beyond the limit: RESOURCE_LIMIT naming the measure"
      (doseq [sql [(where (str (str/join (repeat 100000 "(")) "x" (str/join (repeat 100000 ")"))))
                   (where (str (str/join (repeat (inc n) "NOT ")) "x"))
                   (where (str (str/join (repeat (inc n) "- ")) "x"))
                   (where (str (str/join (repeat (inc n) "ABS(")) "x" (str/join (repeat (inc n) ")"))))]]
        (is (= "RESOURCE_LIMIT" (error-code (parser/parse-statement sql))))
        (is (= (str "expression nesting depth exceeds " n) (message #(parser/parse-statement sql))))))
    (testing "a chain of one operator is one level, whatever its length"
      (is (map? (parser/parse-statement
                 (where (str/join " OR " (repeat 100 (str (str/join (repeat 3000 "(")) "x = 1"
                                                          (str/join (repeat 3000 ")"))))))))))))

(deftest operand-count
  (let [n limits/max-operands]
    (is (map? (parser/parse-statement (str "SELECT x" (str/join (repeat (- n 2) " + 1")) " FROM n"))))
    (is (= "RESOURCE_LIMIT"
           (error-code (parser/parse-statement (str "SELECT x" (str/join (repeat n " + 1")) " FROM n")))))
    (is (= (str "operand count exceeds " n)
           (message #(parser/parse-statement (where (str "x IN (" (str/join ", " (range n)) ")"))))))))

(deftest text-length
  (is (map? (parser/parse-statement (where (str "'" (apply str (repeat 1048000 \a)) "' = ''")))))
  (is (= "RESOURCE_LIMIT"
         (error-code (parser/parse-statement
                       (where (str "'" (apply str (repeat (inc limits/max-text-bytes) \a)) "' = ''"))))))
  (testing "length is measured in UTF-8 bytes"
    (is (= 5 (limits/utf8-length "é€")))
    (is (= 4 (limits/utf8-length "😀")))))

(deftest balanced-boolean-chains
  (let [e (-> (parser/parse-statement (where (str/join " OR " (map #(str "x = " %) (range 10000)))))
              :query :select :where)]
    (testing "long AND/OR chains are balanced"
      (is (< (depth e) 20)))
    (testing "operands keep their order"
      (is (= (map str (range 10000))
             (->> (tree-seq map? (fn [x] (keep x [:left :right])) e)
                  (filter #(= :literal (:node %)))
                  (map :text))))))
  (testing "short chains stay left-deep"
    (let [e (-> (parser/parse-statement (where "a OR b OR c")) :query :select :where)]
      (is (= "c" (get-in e [:right :name])))
      (is (= "a" (get-in e [:left :left :name])))))
  (testing "arithmetic chains stay left-associative"
    (let [e (-> (parser/parse-statement (str "SELECT x" (str/join (repeat 100 " - 1")) " FROM n"))
                :query :select :items first :expr)]
      (is (= 101 (depth e))))))
