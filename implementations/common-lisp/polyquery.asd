;;;; polyquery.asd — ASDF system definitions for the PolyQuery engine.

(defsystem "polyquery"
  :description "PolyQuery analytical database engine (Common Lisp implementation)"
  :version "0.1.0"
  :license "MIT"
  :serial t
  :pathname "src/"
  :components
  ((:file "package")
   (:module "util" :serial t
    :components ((:file "errors")
                 (:file "numbers")
                 (:file "json")))
   (:module "types" :serial t
    :components ((:file "types")
                 (:file "temporal")
                 (:file "values")
                 (:file "compare")))
   (:module "storage" :serial t
    :components ((:file "table")
                 (:file "catalog")))
   (:module "ingest" :serial t
    :components ((:file "common")
                 (:file "csv")
                 (:file "json")))
   (:module "sql" :serial t
    :components ((:file "lexer")
                 (:file "ast")
                 (:file "parser")))
   (:file "exec/context")
   (:module "analyzer" :serial t
    :components ((:file "bound")
                 (:file "functions")
                 (:file "binder")
                 (:file "query")))
   (:module "plan" :serial t
    :components ((:file "logical")
                 (:file "optimizer")
                 (:file "physical")))
   (:module "exec" :serial t
    :components ((:file "expressions")
                 (:file "aggregates")
                 (:file "operators")))
   (:file "engine")
   (:module "protocol" :serial t
    :components ((:file "requests")
                 (:file "cli"))))
  :in-order-to ((test-op (test-op "polyquery/tests"))))

(defsystem "polyquery/tests"
  :description "Unit tests for the PolyQuery engine (sb-rt based)"
  :depends-on ("polyquery" "sb-rt")
  :serial t
  :pathname "tests/"
  :components ((:file "package")
               (:file "test-numbers")
               (:file "test-json")
               (:file "test-sql")
               (:file "test-ingest")
               (:file "test-engine"))
  :perform (test-op (o c)
             (unless (uiop:symbol-call '#:polyquery-tests '#:run-all-tests)
               (error "unit tests failed"))))
