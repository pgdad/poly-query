;;;; polyquery.asd — ASDF system definitions for the PolyQuery engine.

(defsystem "polyquery"
  :description "PolyQuery analytical database engine (Common Lisp implementation)"
  :version "0.1.0"
  :license "MIT"
  :depends-on ("sb-posix")
  :serial t
  :pathname "src/"
  :components
  ((:file "package")
   (:file "version")
   (:module "util" :serial t
    :components ((:file "errors")
                 (:file "numbers")
                 (:file "json")))
   (:module "types" :serial t
    :components ((:file "types")
                 (:file "temporal")
                 (:file "values")
                 (:file "compare")))
   (:file "exec/context")
   (:module "storage" :serial t
    :components ((:file "columns")
                 (:file "table")
                 (:file "stats")
                 (:file "index")
                 (:file "catalog")
                 (:file "binary")
                 (:file "files")
                 (:file "pqcf-write")
                 (:file "pqcf-read")))
   (:module "ingest" :serial t
    :components ((:file "common")
                 (:file "csv")
                 (:file "json")))
   (:module "sql" :serial t
    :components ((:file "lexer")
                 (:file "ast")
                 (:file "parser")))
   (:module "analyzer" :serial t
    :components ((:file "bound")
                 (:file "functions")
                 (:file "binder")
                 (:file "query")))
   (:module "plan" :serial t
    :components ((:file "logical")
                 (:file "optimizer")
                 (:file "access")
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
               (:file "test-engine")
               (:file "test-query")
               (:file "test-storage"))
  :perform (test-op (o c)
             (unless (uiop:symbol-call '#:polyquery-tests '#:run-all-tests)
               (error "unit tests failed"))))
