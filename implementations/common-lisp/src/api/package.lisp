;;;; package.lisp — the public embedding API of the PolyQuery engine
;;;; (spec/apps/embedding.md). Programs use the engine in-process through
;;;; the symbols exported here; everything in the POLYQUERY package is internal.

(defpackage #:polyquery.api
  (:use #:common-lisp)
  (:local-nicknames (#:pq #:polyquery))
  (:export
   ;; instances
   #:database #:make-database #:close-database #:with-database
   #:database-open-p #:database-data-dir
   ;; loading and storage
   #:load-csv #:create-table #:save-table #:open-table
   #:drop-table #:list-tables #:table-exists-p #:table-schema
   ;; queries and results
   #:query #:result #:result-columns #:result-column-names #:result-column-types
   #:result-row-count #:result-rows #:result-value #:do-result-rows
   #:column #:column-name #:column-type
   ;; values
   #:+null+ #:null-value-p
   #:make-date #:date-components #:date-string #:timestamp-string #:decimal-string
   #:decimal-type-scale #:value-text
   ;; errors
   #:engine-error #:engine-error-code #:engine-error-message))
