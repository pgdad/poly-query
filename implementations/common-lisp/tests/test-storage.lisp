;;;; test-storage.lisp — column stores, layouts, statistics, indexes, the PQCF
;;;; codec (round trips, encodings, corruption) and index-aware planning.

(in-package #:polyquery-tests)

(defun octets (&rest bytes)
  (make-array (length bytes) :element-type '(unsigned-byte 8) :initial-contents bytes))

(defun temp-dir ()
  "A fresh empty directory (native namestring with trailing slash)."
  (let ((dir (format nil "/tmp/pq-unit-~D-~D/" (sb-posix:getpid) (random 1000000000))))
    (ensure-directories-exist dir)
    dir))

;;; ------------------------------------------------------------------
;;; Binary helpers

(deftest storage.crc32-check-value
    (polyquery::crc32 (sb-ext:string-to-octets "123456789" :external-format :ascii))
  #xCBF43926)

(deftest storage.utf8-valid
    (polyquery::decode-utf8 (sb-ext:string-to-octets "aÜ€😀" :external-format :utf-8) 0 10)
  "aÜ€😀")

(deftest storage.utf8-invalid
    (list (code-of (polyquery::decode-utf8 (octets #xC0 #x80) 0 2))
          (code-of (polyquery::decode-utf8 (octets #xED #xA0 #x80) 0 3))
          (code-of (polyquery::decode-utf8 (octets #xE2 #x82) 0 2))
          (code-of (polyquery::decode-utf8 (octets #xF4 #x90 #x80 #x80) 0 4)))
  ("STORAGE_CORRUPT" "STORAGE_CORRUPT" "STORAGE_CORRUPT" "STORAGE_CORRUPT"))

;;; ------------------------------------------------------------------
;;; Column stores and layouts

(defparameter *sample-columns*
  (list (cons :int64 (vector 1 :null -9223372036854775808 9223372036854775807))
        (cons :float64 (vector 1.5d0 -0d0 :null 1d300))
        (cons :boolean (vector t nil :null t))
        (cons :string (vector "a" "" :null "ü"))
        (cons :date (vector 0 -719162 2932896 :null))
        (cons (list :decimal 4 2) (vector 9999 -9999 :null 0))))

(deftest storage.column-store-roundtrip
    (loop for (type . values) in *sample-columns*
          always (loop for dict in '(nil t)
                       always (equalp (polyquery::column-store-values
                                       (polyquery::build-column-store values type :dictionary dict))
                                      values)))
  t)

(defun sample-table (layout)
  (polyquery::make-table "t"
                         (loop for (type) in *sample-columns*
                               for i from 0
                               collect (polyquery::make-column-def (format nil "c~D" i) type))
                         (mapcar #'cdr *sample-columns*) 4 :layout layout))

(deftest storage.layouts-agree
    (let ((row (sample-table :row)) (col (sample-table :column)))
      (loop for k below (length *sample-columns*)
            always (equalp (polyquery::table-column-values row k)
                           (polyquery::table-column-values col k))))
  t)

(deftest storage.statistics
    (let ((s (polyquery::table-column-statistics (sample-table :column) 0)))
      (list (polyquery::column-statistics-null-count s)
            (polyquery::column-statistics-distinct-count s)
            (polyquery::column-statistics-min s)
            (polyquery::column-statistics-max s)))
  (1 3 -9223372036854775808 9223372036854775807))

;;; ------------------------------------------------------------------
;;; Indexes

(defun int-table (values)
  (polyquery::make-table "n" (list (polyquery::make-column-def "x" :int64))
                         (list (coerce values 'simple-vector)) (length values)))

(deftest storage.hash-index
    (let* ((table (int-table '(5 3 :null 5 7)))
           (index (polyquery::build-table-index "h" table 0 :hash)))
      (list (coerce (polyquery::hash-index-lookup index 5) 'list)
            (coerce (polyquery::hash-index-lookup index 4) 'list)
            (polyquery::table-index-distinct-count index)))
  ((0 3) nil 3))

(deftest storage.btree-range
    (let* ((table (int-table '(5 3 :null 5 7 1)))
           (index (polyquery::build-table-index "b" table 0 :btree))
           (cmp (lambda (c) (lambda (k) (cond ((< k c) -1) ((> k c) 1) (t 0))))))
      (list (sort (coerce (polyquery::btree-index-range index (list (funcall cmp 3) t)
                                                        (list (funcall cmp 5) t))
                          'list)
                  #'<)
            (coerce (polyquery::btree-index-range index (list (funcall cmp 5) nil) nil) 'list)
            (coerce (polyquery::btree-index-range index nil (list (funcall cmp 1) nil)) 'list)))
  ((0 1 3) (4) nil))

;;; ------------------------------------------------------------------
;;; PQCF round trips and corruption

(defun save-and-reopen (table &rest options)
  (let* ((dir (temp-dir))
         (path (concatenate 'string dir "t.pqcf")))
    (unwind-protect
         (progn
           (polyquery::write-file-atomically
            path (lambda (stream) (apply #'polyquery::write-pqcf stream table '() options)))
           (loop for mmap in '(nil t)
                 collect (polyquery::load-pqcf-table path "r" :mmap mmap)))
      (uiop:delete-directory-tree (pathname dir) :validate t))))

(deftest storage.pqcf-roundtrip-all-encodings
    (let ((table (sample-table :column)))
      (loop for encoding in '(:auto :plain :dict :rle)
            always (loop for size in '(1 3 65536)
                         always (loop for reopened in (save-and-reopen table :encoding encoding
                                                                             :row-group-size size)
                                      always (loop for k below (length *sample-columns*)
                                                   always (equalp (polyquery::table-column-values table k)
                                                                  (polyquery::table-column-values reopened k)))))))
  t)

(deftest storage.pqcf-empty-table
    (let ((reopened (first (save-and-reopen (int-table '())))))
      (list (polyquery::table-row-count reopened)
            (length (polyquery::table-segments reopened))))
  (0 0))

(defun corrupted-open-code (mutate)
  "Save the sample table, apply MUTATE to the file octets, reopen and fully read."
  (let* ((dir (temp-dir))
         (path (concatenate 'string dir "t.pqcf")))
    (unwind-protect
         (progn
           (polyquery::write-file-atomically
            path (lambda (stream) (polyquery::write-pqcf stream (sample-table :column) '())))
           (let ((bytes (with-open-file (in path :element-type '(unsigned-byte 8))
                          (let ((b (make-array (file-length in) :element-type '(unsigned-byte 8))))
                            (read-sequence b in)
                            b))))
             (with-open-file (out path :direction :output :element-type '(unsigned-byte 8)
                                       :if-exists :supersede)
               (write-sequence (funcall mutate bytes) out)))
           (code-of (let ((table (polyquery::load-pqcf-table path "r" :mmap t)))
                      (dotimes (k (polyquery::table-column-count table))
                        (polyquery::table-column-values table k)))))
      (uiop:delete-directory-tree (pathname dir) :validate t))))

(deftest storage.pqcf-corruption
    (list (corrupted-open-code (lambda (b) (setf (aref b 9) (logxor (aref b 9) 1)) b))
          (corrupted-open-code (lambda (b) (subseq b 0 (- (length b) 5))))
          (corrupted-open-code (lambda (b) (setf (aref b 0) 0) b))
          (corrupted-open-code (lambda (b) (setf (aref b 4) 2) b))
          (corrupted-open-code (lambda (b) (setf (aref b 6) 1) b))
          (corrupted-open-code (lambda (b) (subseq b 0 0))))
  ("STORAGE_CORRUPT" "STORAGE_CORRUPT" "STORAGE_CORRUPT" "STORAGE_VERSION_UNSUPPORTED"
   "STORAGE_VERSION_UNSUPPORTED" "STORAGE_CORRUPT"))

;;; ------------------------------------------------------------------
;;; Protocol and planning

(defun storage-session ()
  (let ((dir (temp-dir)))
    (values (make-session (make-engine-config :data-dir dir)) dir)))

(defun request (session &rest keys-and-values)
  (handle-request session (apply #'jobj keys-and-values)))

(defun response-get (response key)
  (polyquery::json-get response key))

(defun explain-ops (session sql)
  "All op names in the EXPLAIN plan of SQL, depth first."
  (let ((ops '()))
    (labels ((walk (node)
               (push (response-get node "op") ops)
               (mapc #'walk (response-get node "children"))))
      (walk (polyquery::explain-sql session sql)))
    (nreverse ops)))

(defparameter *numbers-csv*
  (format nil "id,grp~%~{~A~%~}" (loop for i from 1 to 1000 collect (format nil "~D,~D" i (mod i 3)))))

(deftest storage.index-selection
    (let ((session (storage-session)))
      (request session "op" "load" "table" "n" "format" "csv" "data" *numbers-csv*)
      (execute-sql session "CREATE INDEX n_id ON n (id) USING HASH")
      (execute-sql session "CREATE INDEX n_grp ON n (grp)")
      (list (and (member "IndexScan" (explain-ops session "SELECT * FROM n WHERE id = 5") :test #'equal) t)
            (and (member "IndexScan" (explain-ops session "SELECT * FROM n WHERE grp = 1") :test #'equal) t)
            (polyquery::query-result-rows (execute-sql session "SELECT grp FROM n WHERE id IN (4, 2000)"))
            (polyquery::query-result-row-count
             (execute-sql session "SELECT * FROM n WHERE id BETWEEN 10 AND 20 AND id < 15.5"))))
  (t nil (#(1)) 6))

(deftest storage.save-open-protocol
    (multiple-value-bind (session dir) (storage-session)
      (unwind-protect
           (list (response-get (request session "op" "load" "table" "n" "format" "csv"
                                        "data" *numbers-csv*)
                               "ok")
                 (response-get (request session "op" "save" "table" "n" "path" "n.pqcf") "ok")
                 (response-get (response-get (request session "op" "save" "table" "n"
                                                      "path" "/abs.pqcf")
                                             "error")
                               "code")
                 (response-get (response-get (request session "op" "save" "table" "n"
                                                      "path" "nodir/x.pqcf")
                                             "error")
                               "code")
                 (response-get (request session "op" "open" "table" "m" "path" "n.pqcf"
                                        "options" (jobj "mmap" :true))
                               "row_count")
                 (polyquery::query-result-rows
                  (execute-sql session "SELECT SUM(id), COUNT(*) FROM m WHERE grp = 2")))
        (uiop:delete-directory-tree (pathname dir) :validate t)))
  (:true :true "ACCESS_DENIED" "IO_ERROR" 1000 (#(166500 333))))
