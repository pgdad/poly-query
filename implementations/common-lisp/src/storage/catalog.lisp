;;;; catalog.lisp — the named sets of tables and indexes.
;;;;
;;;; Names are matched ASCII case-insensitively and reported in their declared
;;;; spelling. Index names are global. Mutations are serialized by a mutex and
;;;; publish whole immutable objects, so readers always see a consistent
;;;; snapshot; an index always belongs to the table object it was built on
;;;; and disappears when that table is dropped or replaced.

(in-package #:polyquery)

(defstruct (catalog (:constructor make-catalog ()))
  (tables (make-hash-table :test 'equal) :type hash-table)
  (indexes (make-hash-table :test 'equal) :type hash-table) ; key -> (sequence . TABLE-INDEX)
  (index-sequence 0 :type fixnum)
  (lock (sb-thread:make-mutex :name "catalog")))

(defun catalog-key (name) (ascii-downcase name))

(defmacro with-catalog-lock ((catalog) &body body)
  `(sb-thread:with-recursive-lock ((catalog-lock ,catalog)) ,@body))

(defun catalog-find-table (catalog name)
  (with-catalog-lock (catalog)
    (gethash (catalog-key name) (catalog-tables catalog))))

(defun %drop-table-indexes (catalog table)
  "Remove every index built on TABLE. Caller holds the lock."
  (let ((indexes (catalog-indexes catalog)))
    (loop for key being the hash-keys of indexes using (hash-value entry)
          when (eq (table-index-table (cdr entry)) table)
            collect key into doomed
          finally (dolist (k doomed) (remhash k indexes)))))

(defun %index-name-conflicts (catalog names ignored-table)
  "The first of NAMES already used by an index not built on IGNORED-TABLE."
  (find-if (lambda (n)
             (let ((entry (gethash (catalog-key n) (catalog-indexes catalog))))
               (and entry (not (eq (table-index-table (cdr entry)) ignored-table)))))
           names))

(defun catalog-add-table (catalog table &key replace indexes)
  "Publish TABLE together with its (already built) INDEXES. Without REPLACE an
existing table of that name is an error; with REPLACE the old table and its
indexes are dropped first. Nothing changes if any step fails."
  (with-catalog-lock (catalog)
    (let* ((key (catalog-key (table-name table)))
           (old (gethash key (catalog-tables catalog))))
      (when (and old (not replace))
        (signal-pq-error "ALREADY_EXISTS" "table ~A already exists" (table-name table)))
      (let ((conflict (%index-name-conflicts catalog (mapcar #'table-index-name indexes) old)))
        (when conflict
          (signal-pq-error "ALREADY_EXISTS" "index ~A already exists" conflict)))
      (when old (%drop-table-indexes catalog old))
      (setf (gethash key (catalog-tables catalog)) table)
      (dolist (index indexes)
        (%catalog-put-index catalog index))
      table)))

(defun catalog-table-exists-p (catalog name)
  (not (null (catalog-find-table catalog name))))

(defun catalog-drop-table (catalog name)
  (with-catalog-lock (catalog)
    (let* ((key (catalog-key name))
           (table (gethash key (catalog-tables catalog))))
      (unless table
        (signal-pq-error "NOT_FOUND" "table ~A not found" name))
      (%drop-table-indexes catalog table)
      (remhash key (catalog-tables catalog)))))

(defun catalog-reset (catalog)
  (with-catalog-lock (catalog)
    (clrhash (catalog-tables catalog))
    (clrhash (catalog-indexes catalog))))

(defun catalog-list-tables (catalog)
  "All tables sorted by name, case-insensitively."
  (let ((tables (with-catalog-lock (catalog)
                  (loop for tb being the hash-values of (catalog-tables catalog) collect tb))))
    (sort tables (lambda (a b)
                   (let ((ka (catalog-key (table-name a))) (kb (catalog-key (table-name b))))
                     (or (string< ka kb)
                         (and (string= ka kb) (string< (table-name a) (table-name b)))))))))

;;; ------------------------------------------------------------------
;;; Indexes

(defun %catalog-put-index (catalog index)
  (setf (gethash (catalog-key (table-index-name index)) (catalog-indexes catalog))
        (cons (incf (catalog-index-sequence catalog)) index)))

(defun catalog-find-index (catalog name)
  (with-catalog-lock (catalog)
    (cdr (gethash (catalog-key name) (catalog-indexes catalog)))))

(defun catalog-add-index (catalog index)
  "Publish INDEX unless its name is taken or its table is no longer current."
  (with-catalog-lock (catalog)
    (when (gethash (catalog-key (table-index-name index)) (catalog-indexes catalog))
      (signal-pq-error "ALREADY_EXISTS" "index ~A already exists" (table-index-name index)))
    (let ((table (table-index-table index)))
      (unless (eq (gethash (catalog-key (table-name table)) (catalog-tables catalog)) table)
        (signal-pq-error "NOT_FOUND" "table ~A was dropped or replaced" (table-name table))))
    (%catalog-put-index catalog index)))

(defun catalog-drop-index (catalog name)
  (with-catalog-lock (catalog)
    (let ((key (catalog-key name)))
      (unless (gethash key (catalog-indexes catalog))
        (signal-pq-error "NOT_FOUND" "index ~A not found" name))
      (remhash key (catalog-indexes catalog)))))

(defun catalog-table-indexes (catalog table)
  "Indexes built on TABLE, in creation order."
  (let ((entries (with-catalog-lock (catalog)
                   (loop for entry being the hash-values of (catalog-indexes catalog)
                         when (eq (table-index-table (cdr entry)) table)
                           collect entry))))
    (mapcar #'cdr (sort entries #'< :key #'car))))
