(ns pqledger.reports-test
  (:require [clojure.test :refer [deftest is]]
            [pqledger.ledger :as ledger]
            [pqledger.reports :as reports]
            [polyquery.api :as pq])
  (:import (java.time LocalDate YearMonth)))

(deftest share-is-exact-and-rounds-half-away-from-zero
  (is (= 99.3M (reports/share 397.01M 400.01M)))
  (is (= 66.7M (reports/share 2.00M 3.00M)))
  (is (= 0.5M (reports/share 0.05M 10.00M)))
  (is (= 0.1M (reports/share 0.05M 50.00M)))
  (is (= 100.0M (reports/share 5.00M 5.00M))))

(deftest filter-conditions
  (is (= ["\"date\" >= DATE '2026-02-01'" "\"date\" <= DATE '2026-02-28'"]
         (reports/filter-conditions {:month (YearMonth/of 2026 2)})))
  (is (= ["\"date\" <= DATE '9999-12-31'" "account = 'a'"]
         (reports/filter-conditions {:to (YearMonth/of 9999 12) :account "a"}))))

(defn- tx [id account date merchant amount]
  [id account (LocalDate/parse date) merchant merchant (bigdec amount) 1])

(defn- with-db [rules f]
  (with-open [db (pq/create)]
    (pq/load-rows! db "transactions" (get ledger/tables "transactions")
                   [(tx 1 "a" "2026-01-01" "WHOLE FOODS" "-10.00")
                    (tx 2 "a" "2026-01-15" "PAYROLL" "100.00")
                    (tx 3 "b" "2026-02-01" "WHOLE FOODS #2" "-5.50")
                    (tx 4 "b" "2026-02-03" "CAFé X" "-1.25")])
    (pq/load-rows! db "overrides" (get ledger/tables "overrides") [[3 "gifts"]])
    (ledger/load-rules! db rules)
    (f db)))

(def rules [{:rule-no 1 :category "groceries" :pattern "WHOLE FOODS*"}
            {:rule-no 2 :category "coffee" :pattern "CAF? *"}
            {:rule-no 3 :category "shopping" :pattern "*"}])

(deftest reports
  (with-db rules
    (fn [db]
      (is (= [["2026-01" 100.00M 10.00M 90.00M 2] ["2026-02" 0.00M 6.75M -6.75M 2]]
             (:rows (reports/monthly db {} {}))))
      (is (= [["groceries" 10.00M 59.7M 1] ["gifts" 5.50M 32.8M 1] ["coffee" 1.25M 7.5M 1]]
             (:rows (reports/categories db {} {}))))
      (is (= [["WHOLE FOODS" 10.00M 1]] (:rows (reports/merchants db {} {} 1))))
      (is (= [[2 (LocalDate/of 2026 1 15) "a" "PAYROLL" 100.00M "shopping"]]
             (:rows (reports/list-transactions db {} {:account "a"} "shopping"))))
      (is (= [1 2 3 4] (map first (:rows (reports/export db {} {})))))
      (is (= [["a" 2 90.00M (LocalDate/of 2026 1 1) (LocalDate/of 2026 1 15)]
              ["b" 2 -6.75M (LocalDate/of 2026 2 1) (LocalDate/of 2026 2 3)]]
             (:rows (reports/accounts db {}))))
      (ledger/load-budgets! db [{:category "coffee" :amount 1.00M} {:category "gifts" :amount 10.00M}])
      (let [r (reports/budget db {} {:month (YearMonth/of 2026 2)})]
        (is (= [["coffee" 1.00M 1.25M -0.25M "over"] ["gifts" 10.00M 5.50M 4.50M "ok"]] (:rows r)))
        (is (reports/over-budget? r))))))

(deftest no-rules-means-uncategorized
  (with-db []
    (fn [db]
      (is (= #{"uncategorized" "gifts"} (set (map #(nth % 6) (:rows (reports/export db {} {})))))))))
