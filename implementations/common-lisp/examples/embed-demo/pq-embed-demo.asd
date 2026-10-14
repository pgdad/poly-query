;;;; pq-embed-demo.asd — a minimal program embedding the PolyQuery engine
;;;; (spec/apps/embedding.md §5). It depends on the "polyquery" system only
;;;; and uses nothing but its public API (package POLYQUERY.API).

(defsystem "pq-embed-demo"
  :description "Load a CSV file, run one SQL statement, print the result as CSV"
  :version "1.0.0"
  :license "MIT"
  :depends-on ("polyquery")
  :components ((:file "main")))
