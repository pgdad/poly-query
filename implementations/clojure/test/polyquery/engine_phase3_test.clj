(ns polyquery.engine-phase3-test
  "End-to-end tests of Phase 3 planning: column pruning, index selection and
  index statements, hash join build sides."
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [polyquery.engine :as engine]
            [polyquery.test-util :refer [csv-catalog error-code]]))

(def big-csv
  (str "id,grp,val,name\n"
       (str/join (for [i (range 1 201)] (str i "," (mod i 7) "," (* i 10) ",n" i "\n")))))

(defn- new-catalog []
  (atom (csv-catalog {"big" big-csv "small" "id,label\n1,one\n2,two\n3,three\n"})))

(defn- exec [cat sql & [opts]] (engine/execute! cat sql (or opts {})))
(defn- rows [cat sql & [opts]] (mapv vec (:rows (exec cat sql opts))))
(defn- plan [cat sql & [opts]] (engine/explain-plan @cat sql (or opts {})))

(defn- plan-nodes [p] (tree-seq map? #(get % "children") p))

(defn- scans [p]
  (into {} (for [n (plan-nodes p) :when (#{"TableScan" "IndexScan"} (get n "op"))]
             [(get n "table") (set (get n "columns"))])))

(defn- index-scans [p]
  (set (keep #(when (= "IndexScan" (get % "op")) (get % "index")) (plan-nodes p))))

(deftest column-pruning
  (let [cat (new-catalog)]
    (is (= {"big" #{"id" "val"}} (scans (plan cat "SELECT id FROM big WHERE val > 5"))))
    (is (= {"big" #{}} (scans (plan cat "SELECT COUNT(*) FROM big"))))
    (is (= {"big" #{"grp" "val"}} (scans (plan cat "SELECT grp, SUM(val) FROM big GROUP BY grp ORDER BY grp"))))
    (testing "through joins, derived tables, CTEs and subqueries"
      (is (= {"big" #{"id"} "small" #{"id" "label"}}
             (scans (plan cat "SELECT s.label FROM big b JOIN small s ON s.id = b.id"))))
      (is (= {"big" #{"name"}} (scans (plan cat "WITH c AS (SELECT * FROM big) SELECT name FROM c"))))
      (is (= {"big" #{"id" "grp"} "small" #{"id"}}
             (scans (plan cat "SELECT id FROM small s WHERE EXISTS (SELECT * FROM big b WHERE b.id = s.id AND b.grp = 1)")))))))

(deftest index-statements
  (let [cat (new-catalog)]
    (is (= {:columns [] :rows [] :row-count 0} (exec cat "CREATE INDEX big_id ON big (id) USING HASH")))
    (exec cat "CREATE INDEX big_val ON big (val)")
    (is (= "ALREADY_EXISTS" (error-code (exec cat "CREATE INDEX BIG_ID ON small (id)"))))
    (exec cat "CREATE INDEX IF NOT EXISTS big_id ON small (id)")
    (is (= "SEMANTIC_ERROR" (error-code (exec cat "CREATE INDEX x ON nope (id)"))))
    (is (= "SEMANTIC_ERROR" (error-code (exec cat "CREATE INDEX x ON big (nope)"))))
    (testing "selective predicates use indexes, others scan"
      (is (= #{"big_id"} (index-scans (plan cat "SELECT name FROM big WHERE id = 42"))))
      (is (= #{"big_id"} (index-scans (plan cat "SELECT name FROM big WHERE id IN (1, 2, 3)"))))
      (is (= #{"big_val"} (index-scans (plan cat "SELECT name FROM big WHERE val BETWEEN 100 AND 200"))))
      (is (= #{} (index-scans (plan cat "SELECT name FROM big WHERE val > 100"))))
      (is (= #{} (index-scans (plan cat "SELECT name FROM big WHERE id = 42" {:use-indexes false})))))
    (testing "index scans return the same rows"
      (doseq [sql ["SELECT name FROM big WHERE id = 42"
                   "SELECT id FROM big WHERE id IN (5, 1, 5, 999) ORDER BY id"
                   "SELECT id FROM big WHERE val BETWEEN 95 AND 205 ORDER BY id"
                   "SELECT id FROM big WHERE val >= 1990 AND val < 2000.5 ORDER BY id"
                   "SELECT id FROM big WHERE val > 1995 AND val <= 1990"]]
        (is (= (rows cat sql {:use-indexes false}) (rows cat sql)) sql)))
    (exec cat "DROP INDEX big_id")
    (is (= "NOT_FOUND" (error-code (exec cat "DROP INDEX big_id"))))
    (exec cat "DROP INDEX IF EXISTS big_id")
    (is (= #{} (index-scans (plan cat "SELECT name FROM big WHERE id = 42"))))))

(deftest hash-join-build-side
  (let [cat (new-catalog)
        join (fn [p] (first (filter #(= "HashJoin" (get % "op")) (plan-nodes p))))]
    (is (= "left" (get (join (plan cat "SELECT * FROM small s JOIN big b ON b.id = s.id")) "build")))
    (is (= "right" (get (join (plan cat "SELECT * FROM big b JOIN small s ON b.id = s.id")) "build")))
    (is (= "right" (get (join (plan cat "SELECT * FROM small s LEFT JOIN big b ON b.id = s.id")) "build")))
    (is (= (rows cat "SELECT s.label, b.name FROM big b JOIN small s ON b.id = s.id ORDER BY 1")
           (rows cat "SELECT s.label, b.name FROM small s JOIN big b ON b.id = s.id ORDER BY 1")))))
