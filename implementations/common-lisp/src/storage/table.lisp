;;;; table.lisp — immutable in-memory tables (column-oriented).
;;;;
;;;; A table is an immutable value: loading produces a fresh table object that
;;;; is published atomically in the catalog. Each column stores its values in
;;;; a SIMPLE-VECTOR (NULL is :NULL); later phases can add specialised
;;;; physical layouts behind the same accessors.

(in-package #:polyquery)

(defstruct (column-def (:constructor make-column-def (name type)))
  (name "" :type string)
  type)

(defstruct (table (:constructor %make-table))
  (name "" :type string)
  (columns #() :type simple-vector)      ; of COLUMN-DEF
  (data #() :type simple-vector)         ; per column: SIMPLE-VECTOR of values
  (row-count 0 :type fixnum))

(defun make-table (name column-defs column-data row-count)
  (%make-table :name name
               :columns (coerce column-defs 'simple-vector)
               :data (coerce column-data 'simple-vector)
               :row-count row-count))

(defun table-column-count (table)
  (length (table-columns table)))

(defun table-column-vector (table index)
  (svref (table-data table) index))

(defun find-column-index (table name)
  "Index of the column called NAME (ASCII case-insensitive) or NIL."
  (position name (table-columns table)
            :key #'column-def-name :test #'ascii-string-equal))

(defun columns-json (column-defs)
  "Protocol representation of column metadata."
  (loop for c across (coerce column-defs 'simple-vector)
        collect (jobj "name" (column-def-name c)
                      "type" (type-name-string (column-def-type c)))))
