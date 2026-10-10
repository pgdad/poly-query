(ns polyquery.test-runner
  "Runs all unit tests (`make test`); exits non-zero on failure."
  (:require [clojure.test :as t]))

(def test-namespaces
  '[polyquery.util.json-test
    polyquery.values-test
    polyquery.sql.lexer-test
    polyquery.sql.parser-test
    polyquery.sql.analyzer-test
    polyquery.ingest.csv-test
    polyquery.ingest.json-test
    polyquery.engine-test
    polyquery.protocol-test])

(defn -main [& _]
  (apply require test-namespaces)
  (let [{:keys [fail error]} (apply t/run-tests test-namespaces)]
    (shutdown-agents)
    (System/exit (if (zero? (+ fail error)) 0 1))))
