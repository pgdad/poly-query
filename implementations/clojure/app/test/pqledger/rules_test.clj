(ns pqledger.rules-test
  (:require [clojure.test :refer [deftest is]]
            [pqledger.rules :as rules]
            [pqledger.test-util :refer [error-kind]]))

(deftest rules
  (is (= [{:rule-no 1 :category "groceries" :pattern "WHOLE FOODS*"}
          {:rule-no 2 :category "groceries" :pattern "SAFEWAY"}
          {:rule-no 3 :category "coffee" :pattern "CAFé?"}
          {:rule-no 4 :category "groceries" :pattern "LIDL"}]
         (rules/parse-rules "# c\ngroceries = Whole Foods* ,  SAFEWAY\n\ncoffee = Café?\ngroceries = lidl\n" "r")))
  (is (= [] (rules/parse-rules "" "r")))
  (doseq [bad ["groceries = SAFE_WAY\n" "groceries = 10%\n" "groceries = A,,B\n" "groceries =\n"
               "Groceries = A\n" "uncategorized = A\n" "[section]\n" "just text\n"]]
    (is (= :config (error-kind (rules/parse-rules bad "r"))) bad)))

(deftest budgets
  (is (= [{:category "groceries" :amount 600.00M} {:category "coffee" :amount 30.50M}]
         (rules/parse-budgets "groceries = 600\ncoffee = 30.5\n" "b")))
  (is (= 2 (.scale ^BigDecimal (:amount (first (rules/parse-budgets "a = 1\n" "b"))))))
  (doseq [bad ["a = 12.345\n" "a = -5\n" "a = 1e3\n" "a = 1\na = 2\n" "a = 12345678901234567\n" "a = .5\n"]]
    (is (= :config (error-kind (rules/parse-budgets bad "b"))) bad)))
