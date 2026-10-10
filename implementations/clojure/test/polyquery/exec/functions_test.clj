(ns polyquery.exec.functions-test
  (:require [clojure.test :refer [deftest is]]
            [polyquery.exec.functions :as f]))

(deftest like-matching
  (doseq [[s p expected] [["abc" "abc" true] ["abc" "ABC" false] ["abc" "a%" true] ["abc" "%c" true]
                          ["abc" "a_c" true] ["ac" "a_c" false] ["" "%" true] ["" "_" false]
                          ["mississippi" "%iss%ppi" true] ["aXbXc" "a%b%c" true] ["abc" "b" false]
                          ["éa" "_a" true] ["😀" "_" true] ["a.c" "a.c" true] ["abcabc" "%abc" true]]]
    (is (= expected ((f/like-matcher p) s)) (str s " LIKE " p))))

(deftest case-mapping
  (is (= "ABC ÜNÏ" (f/case-map "abc ÜNÏ" true)))
  (is (= "ABC Ünï" (f/case-map "abc Ünï" true)))
  (is (= "abc ÜNÏ" (f/case-map "ABC ÜNÏ" false)))
  (is (= "HéLLO" (f/case-map "héllo" true))))
