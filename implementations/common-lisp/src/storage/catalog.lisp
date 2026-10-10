;;;; catalog.lisp — the named set of tables (and, later, indexes).
;;;;
;;;; Names are matched ASCII case-insensitively and reported in their declared
;;;; spelling. Mutations are serialized by a mutex and publish whole immutable
;;;; table objects, so readers always see a consistent snapshot.

(in-package #:polyquery)

(defstruct (catalog (:constructor make-catalog ()))
  (tables (make-hash-table :test 'equal) :type hash-table)
  (lock (sb-thread:make-mutex :name "catalog")))

(defun catalog-key (name) (ascii-downcase name))

(defun catalog-find-table (catalog name)
  (sb-thread:with-mutex ((catalog-lock catalog))
    (gethash (catalog-key name) (catalog-tables catalog))))

(defun catalog-add-table (catalog table &key replace)
  "Publish TABLE. Without REPLACE an existing table of that name is an error."
  (sb-thread:with-mutex ((catalog-lock catalog))
    (let ((key (catalog-key (table-name table))))
      (when (and (not replace) (gethash key (catalog-tables catalog)))
        (signal-pq-error "ALREADY_EXISTS" "table ~A already exists" (table-name table)))
      (setf (gethash key (catalog-tables catalog)) table))))

(defun catalog-table-exists-p (catalog name)
  (not (null (catalog-find-table catalog name))))

(defun catalog-drop-table (catalog name)
  (sb-thread:with-mutex ((catalog-lock catalog))
    (let ((key (catalog-key name)))
      (unless (gethash key (catalog-tables catalog))
        (signal-pq-error "NOT_FOUND" "table ~A not found" name))
      (remhash key (catalog-tables catalog)))))

(defun catalog-reset (catalog)
  (sb-thread:with-mutex ((catalog-lock catalog))
    (clrhash (catalog-tables catalog))))

(defun catalog-list-tables (catalog)
  "All tables sorted by name, case-insensitively."
  (let ((tables (sb-thread:with-mutex ((catalog-lock catalog))
                  (loop for tb being the hash-values of (catalog-tables catalog) collect tb))))
    (sort tables (lambda (a b)
                   (let ((ka (catalog-key (table-name a))) (kb (catalog-key (table-name b))))
                     (or (string< ka kb)
                         (and (string= ka kb) (string< (table-name a) (table-name b)))))))))
