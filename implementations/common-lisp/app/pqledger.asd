;;;; pqledger.asd — the pqledger personal-finance application (spec/apps/pqledger.md),
;;;; built on the PolyQuery embedding API.

(defsystem "pqledger"
  :description "Personal-finance ledger on the embedded PolyQuery engine"
  :version "1.0.0"
  :license "MIT"
  :depends-on ("polyquery")
  :serial t
  :pathname "src/"
  :components ((:file "package")
               (:file "conditions")
               (:file "text")
               (:file "config")
               (:file "rules")
               (:file "statement")
               (:file "ledger")
               (:file "output")
               (:file "reports")
               (:file "cli")
               (:file "main"))
  :in-order-to ((test-op (test-op "pqledger/tests"))))

(defsystem "pqledger/tests"
  :description "Unit tests for pqledger (sb-rt based)"
  :depends-on ("pqledger" "sb-rt")
  :serial t
  :pathname "tests/"
  :components ((:file "package")
               (:file "test-text")
               (:file "test-config")
               (:file "test-statement")
               (:file "test-output")
               (:file "test-ledger"))
  :perform (test-op (o c)
             (unless (uiop:symbol-call '#:pqledger-tests '#:run-all-tests)
               (error "pqledger unit tests failed"))))
