(ns pqledger.test-runner
  "Runs the application's unit tests (`make test`); exits non-zero on failure."
  (:require [clojure.test :as t]))

(def test-namespaces
  '[pqledger.config-test
    pqledger.rules-test
    pqledger.statement-test
    pqledger.importer-test
    pqledger.output-test
    pqledger.cli-test
    pqledger.reports-test
    pqledger.main-test])

(defn -main [& _]
  (apply require test-namespaces)
  (let [{:keys [fail error]} (apply t/run-tests test-namespaces)]
    (shutdown-agents)
    (System/exit (if (zero? (+ fail error)) 0 1))))
