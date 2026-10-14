;;;; api.lisp — the embedding API (spec/apps/embedding.md): engine instances,
;;;; loading, queries with typed results, PQCF save/open, catalog operations.
;;;;
;;;; The API is a thin client of the engine facade (engine.lisp), which the
;;;; protocol front end (`bin/polyquery`) uses as well. It adds the
;;;; conversion between the engine's internal value representation and native
;;;; Lisp values, and turns every failure into an ENGINE-ERROR.

(in-package #:polyquery.api)

;;; ------------------------------------------------------------------
;;; Errors

(define-condition engine-error (error)
  ((code :initarg :code :reader engine-error-code
         :documentation "The error code of spec/errors/error-codes.json, e.g. \"PARSE_ERROR\".")
   (message :initarg :message :reader engine-error-message
            :documentation "Human-readable description."))
  (:report (lambda (c s)
             (format s "~A: ~A" (engine-error-code c) (engine-error-message c))))
  (:documentation "Signalled by every API operation that fails. The instance
stays usable afterwards."))

(defun api-error (code format-control &rest args)
  (error 'engine-error :code code :message (apply #'format nil format-control args)))

(defun call-with-engine-errors (thunk)
  "Call THUNK with the engine's floating-point environment (traps masked) and
translate every failure into an ENGINE-ERROR carrying the engine's code."
  (handler-case
      (sb-int:with-float-traps-masked (:overflow :invalid :divide-by-zero :inexact :underflow)
        (funcall thunk))
    (engine-error (e) (error e))
    (pq:pq-error (e)
      (error 'engine-error :code (pq:pq-error-code e) :message (pq:pq-error-message e)))
    (sb-kernel::control-stack-exhausted ()
      (api-error "RESOURCE_LIMIT" "statement too complex: stack exhausted"))
    (storage-condition ()
      (pq::note-memory-failure)
      (api-error "RESOURCE_LIMIT" "out of memory"))
    (error (e)
      (api-error "INTERNAL_ERROR" "internal error: ~A" e))))

;;; ------------------------------------------------------------------
;;; Instances

(defstruct (database (:constructor %make-database (session))
                     (:copier nil))
  "An engine instance: a configuration and a catalog of in-memory tables."
  (session nil)
  (open-p t))

(defmethod print-object ((db database) stream)
  (print-unreadable-object (db stream :type t :identity t)
    (format stream "~A~:[ (closed)~;~]" (database-data-dir db) (database-open-p db))))

(defun database-data-dir (database)
  "The native path of DATABASE's data directory (with a trailing slash)."
  (pq::engine-config-data-dir (pq::session-config (database-session database))))

(defun positive-integer-option (name value)
  (unless (or (null value) (and (integerp value) (plusp value)))
    (api-error "INVALID_REQUEST" "~A must be a positive integer, not ~S" name value))
  value)

(defun native-directory (dir)
  "DIR (a string or pathname, absolute or relative to the current working
directory) as an absolute native directory path with a trailing slash."
  (let ((text (etypecase dir
                (string dir)
                (pathname (sb-ext:native-namestring dir)))))
    (when (zerop (length text))
      (setf text "."))
    (unless (char= (char text 0) #\/)
      (setf text (concatenate 'string (pq::ensure-trailing-slash (pq::current-directory)) text)))
    (pq::ensure-trailing-slash text)))

(defun make-database (&key (data-dir ".") max-query-memory-mb threads
                           max-ingest-bytes max-table-rows max-join-rows)
  "Create an engine instance. DATA-DIR (default: the current directory) is
the directory that relative paths of LOAD-CSV, SAVE-TABLE and OPEN-TABLE are
resolved in; paths may not leave it. The other arguments are the limits and
defaults of the command line options of the same names (`--max-query-memory-mb`,
`--threads`, ...); NIL means the engine's default."
  (call-with-engine-errors
   (lambda ()
     (let ((config (pq:make-engine-config :data-dir (native-directory data-dir))))
       (macrolet ((opt (var accessor)
                    `(when (positive-integer-option ,(string-downcase (symbol-name var)) ,var)
                       (setf (,accessor config) ,var))))
         (opt max-query-memory-mb pq::engine-config-max-query-memory-mb)
         (opt threads pq::engine-config-threads)
         (opt max-ingest-bytes pq::engine-config-max-ingest-bytes)
         (opt max-table-rows pq::engine-config-max-table-rows)
         (opt max-join-rows pq::engine-config-max-join-rows))
       (%make-database (pq:make-session config))))))

(defun close-database (database)
  "Release DATABASE's tables. Closing twice is harmless; any other operation
on a closed instance signals an ENGINE-ERROR."
  (when (database-open-p database)
    (setf (database-open-p database) nil)
    (pq::catalog-reset (pq::session-catalog (database-session database))))
  nil)

(defmacro with-database ((var &rest options) &body body)
  "Bind VAR to (MAKE-DATABASE ,@OPTIONS) around BODY and close it afterwards,
also on a non-local exit."
  `(let ((,var (make-database ,@options)))
     (unwind-protect (progn ,@body)
       (close-database ,var))))

(defmacro with-open-instance ((session database) &body body)
  "Run BODY with SESSION bound to DATABASE's engine session, translating errors."
  (let ((db (gensym "DB")))
    `(let ((,db ,database))
       (check-type ,db database)
       (call-with-engine-errors
        (lambda ()
          (unless (database-open-p ,db)
            (api-error "INVALID_REQUEST" "the database is closed"))
          (let ((,session (database-session ,db)))
            ,@body))))))

(defun session-catalog* (session)
  (pq::session-catalog session))

;;; ------------------------------------------------------------------
;;; Columns and types

(defstruct (column (:constructor %make-column (name type internal-type))
                   (:copier nil) (:predicate nil))
  "A result or table column: its NAME and canonical TYPE name (a string such
as \"INT64\" or \"DECIMAL(18,2)\", spec/data-types/types.md)."
  (name "" :type string :read-only t)
  (type "" :type string :read-only t)
  (internal-type nil :read-only t))

(defmethod print-object ((c column) stream)
  (print-unreadable-object (c stream :type t)
    (format stream "~A ~A" (column-name c) (column-type c))))

(defun column-from-def (def)
  (let ((type (pq::output-type (pq::column-def-type def))))
    (%make-column (pq::column-def-name def) (pq:type-name-string type) type)))

(defun parse-type (type)
  "The internal type of the type name TYPE (a string; aliases such as
\"BIGINT\" are accepted)."
  (unless (stringp type)
    (api-error "INVALID_REQUEST" "a type must be a string such as \"INT64\", not ~S" type))
  (pq::parse-type-string type "INVALID_REQUEST"))

(defun column-defs-from-spec (columns)
  "COLUMN-DEFs from a list of (NAME TYPE) entries."
  (loop for entry in columns
        collect (destructuring-bind (name type) entry
                  (unless (and (stringp name) (plusp (length name)))
                    (api-error "INVALID_REQUEST" "invalid column name ~S" name))
                  (pq::make-column-def name (parse-type type)))))

;;; ------------------------------------------------------------------
;;; Values: internal <-> native
;;;
;;;   INT64 -> integer   DECIMAL(p,s) -> rational (exact)   FLOAT64 -> double-float
;;;   STRING -> string   BOOLEAN -> T / NIL   DATE -> integer days since 1970-01-01
;;;   TIMESTAMP -> integer microseconds since 1970-01-01 00:00:00   NULL -> :NULL

(defconstant +null+ :null
  "The value representing SQL NULL in results and in CREATE-TABLE rows.")

(declaim (inline null-value-p))
(defun null-value-p (value)
  "True if VALUE is SQL NULL."
  (eq value +null+))

(defun native-converter (type)
  "A function turning an internal value of TYPE into its native value."
  (if (pq::decimal-type-p type)
      (let ((divisor (expt 10 (pq::decimal-scale type))))
        (lambda (v) (if (eq v +null+) v (/ v divisor))))
      #'identity))

(defun internal-converter (type)
  "A function turning a native value for a column of TYPE into the engine's
internal value, signalling INVALID_REQUEST / NUMERIC_OVERFLOW on misfit values."
  (flet ((bad (v)
           (api-error "INVALID_REQUEST" "~S is not a valid ~A value" v (pq:type-name-string type))))
    (ecase (pq::type-kind type)
      (:int64 (lambda (v)
                (cond ((eq v +null+) v)
                      ((not (integerp v)) (bad v))
                      ((pq::int64-p v) v)
                      (t (api-error "NUMERIC_OVERFLOW" "~D is out of the INT64 range" v)))))
      (:decimal
       (let* ((scale (pq::decimal-scale type))
              (precision (pq::decimal-precision type))
              (factor (expt 10 scale)))
         (lambda (v)
           (cond ((eq v +null+) v)
                 ((not (rationalp v)) (bad v))
                 (t (let ((unscaled (* v factor)))
                      (unless (integerp unscaled)
                        (api-error "CONVERSION_ERROR" "~S has more than ~D fractional digits" v scale))
                      (unless (pq::fits-precision-p unscaled precision)
                        (api-error "NUMERIC_OVERFLOW" "~S does not fit ~A" v (pq:type-name-string type)))
                      unscaled))))))
      (:float64 (lambda (v)
                  (cond ((eq v +null+) v)
                        ((realp v) (coerce v 'double-float))
                        (t (bad v)))))
      (:string (lambda (v)
                 (cond ((eq v +null+) v)
                       ((stringp v) (coerce v 'simple-string))
                       (t (bad v)))))
      (:boolean (lambda (v)
                  (if (member v (list t nil +null+)) v (bad v))))
      ((:date :timestamp)
       (lambda (v)
         (cond ((eq v +null+) v)
               ((pq::int64-p v) v)
               (t (bad v))))))))

(defun make-date (year month day)
  "The DATE value (days since 1970-01-01) of a valid calendar date."
  (unless (and (integerp year) (integerp month) (integerp day)
               (<= 1 year 9999) (<= 1 month 12)
               (<= 1 day (pq::days-in-month year month)))
    (api-error "INVALID_REQUEST" "invalid date ~S-~S-~S" year month day))
  (pq:days-from-civil year month day))

(defun date-components (days)
  "The year, month and day of the DATE value DAYS, as three values."
  (pq:civil-from-days days))

(defun date-string (days)
  "The DATE value DAYS as YYYY-MM-DD."
  (pq:format-date days))

(defun timestamp-string (micros)
  "The TIMESTAMP value MICROS as YYYY-MM-DD HH:MM:SS[.ffffff]."
  (pq:format-timestamp micros))

(defun decimal-string (value scale)
  "The rational VALUE as canonical DECIMAL text with SCALE fractional digits
(rounded half away from zero if VALUE has more), e.g. -12.50."
  (let* ((scaled (* value (expt 10 scale)))
         (unscaled (if (integerp scaled)
                       scaled
                       (* (signum scaled) (floor (+ (abs scaled) 1/2))))))
    (pq:format-decimal unscaled scale)))

(defun decimal-type-scale (type)
  "The scale of the DECIMAL type named TYPE (a string or a COLUMN), or NIL
if TYPE is not a DECIMAL type."
  (let ((internal (internal-type type)))
    (and (pq::decimal-type-p internal) (pq::decimal-scale internal))))

(defun internal-type (type)
  (etypecase type
    (column (column-internal-type type))
    (string (call-with-engine-errors (lambda () (parse-type type))))))

(defun value-text (value type)
  "The canonical text of the native VALUE of TYPE (a type name or a COLUMN),
as in spec/data-types/types.md §9 without JSON quoting; NIL for NULL."
  (let ((internal (internal-type type)))
    (cond ((eq value +null+) nil)
          ((pq::decimal-type-p internal)
           (decimal-string value (pq::decimal-scale internal)))
          (t (pq::value-to-text value internal)))))

;;; ------------------------------------------------------------------
;;; Results

(defstruct (result (:constructor %make-result (columns rows))
                   (:copier nil))
  "The result of a query: its COLUMNS (a list of COLUMN) and ROWS (a vector
of row vectors holding native values)."
  (columns '() :type list :read-only t)
  (rows #() :type simple-vector :read-only t))

(defmethod print-object ((r result) stream)
  (print-unreadable-object (r stream :type t)
    (format stream "~{~A~^, ~} (~D rows)" (result-column-names r) (result-row-count r))))

(defun result-column-names (result)
  "The column names of RESULT, in order."
  (mapcar #'column-name (result-columns result)))

(defun result-column-types (result)
  "The canonical type names of RESULT's columns, in order."
  (mapcar #'column-type (result-columns result)))

(defun result-row-count (result)
  "The number of rows of RESULT."
  (length (result-rows result)))

(defun result-column-index (result column)
  (etypecase column
    (integer column)
    (string (or (position column (result-columns result)
                          :key #'column-name :test #'pq::ascii-string-equal)
                (api-error "NOT_FOUND" "no column ~A in the result" column)))))

(defun result-value (result row column)
  "The native value at ROW (0-based) and COLUMN (0-based index or name) of RESULT."
  (svref (svref (result-rows result) row) (result-column-index result column)))

(defmacro do-result-rows ((row result &optional value) &body body)
  "Evaluate BODY with ROW bound to each row vector of RESULT in order, then
return VALUE."
  `(loop for ,row across (result-rows ,result)
         do (progn ,@body)
         finally (return ,value)))

(defun native-result (query-result)
  (let* ((defs (pq::query-result-columns query-result))
         (columns (mapcar #'column-from-def defs))
         (converters (map 'simple-vector
                          (lambda (c) (native-converter (column-internal-type c)))
                          columns))
         (width (length converters))
         (rows (make-array (pq::query-result-row-count query-result))))
    (loop for i from 0
          for row in (pq::query-result-rows query-result)
          do (let ((out (make-array width)))
               (dotimes (k width)
                 (setf (svref out k) (funcall (the function (svref converters k)) (svref row k))))
               (setf (svref rows i) out)))
    (%make-result columns rows)))

;;; ------------------------------------------------------------------
;;; Operations

(defun query (database sql &key threads timeout-ms max-rows (mode :auto))
  "Execute the SQL statement SQL and return its RESULT. THREADS (default: the
instance's thread count), TIMEOUT-MS and MAX-ROWS are the query options of the
protocol; MODE is :AUTO, :ROW or :VECTORIZED."
  (with-open-instance (session database)
    (unless (stringp sql)
      (api-error "INVALID_REQUEST" "SQL must be a string"))
    (positive-integer-option "threads" threads)
    (unless (or (null timeout-ms) (and (integerp timeout-ms) (>= timeout-ms 0)))
      (api-error "INVALID_REQUEST" "timeout-ms must be a non-negative integer"))
    (unless (or (null max-rows) (and (integerp max-rows) (>= max-rows 0)))
      (api-error "INVALID_REQUEST" "max-rows must be a non-negative integer"))
    (unless (member mode '(:auto :row :vectorized))
      (api-error "INVALID_REQUEST" "mode must be :AUTO, :ROW or :VECTORIZED"))
    (let ((options (pq::make-exec-options
                    :mode mode
                    :threads (min (or threads (pq::engine-config-threads (pq::session-config session)))
                                  256))))
      (native-result (pq:execute-sql session sql :max-rows max-rows :timeout-ms timeout-ms
                                                 :options options)))))

(defun delimiter-char (delimiter)
  (pq::csv-delimiter-char (etypecase delimiter
                            (character (string delimiter))
                            (string delimiter))))

(defun load-csv (database table &key path text schema (header t) (delimiter #\,) replace)
  "Load CSV into the table TABLE from exactly one of PATH (a file relative to
the data directory) or TEXT (the CSV itself, a string). SCHEMA is an optional
list of (NAME TYPE) entries (TYPE a type name such as \"DECIMAL(18,2)\");
without it the schema is inferred. HEADER says whether the first record names
the columns; DELIMITER is a character or one-character string. Without
REPLACE an existing table is an ALREADY_EXISTS error. Returns the number of
rows loaded and, as a second value, the table's columns."
  (with-open-instance (session database)
    (let ((table (pq::load-input session table :csv
                                 :path (and path (if (pathnamep path)
                                                     (sb-ext:native-namestring path)
                                                     path))
                                 :data text
                                 :schema (and schema (column-defs-from-spec schema))
                                 :header header
                                 :delimiter (delimiter-char delimiter)
                                 :replace replace)))
      (values (pq::table-row-count table) (table-columns table)))))

(defun table-columns (table)
  (map 'list #'column-from-def (pq::table-columns table)))

(defun create-table (database table columns rows &key replace)
  "Create the table TABLE with COLUMNS, a list of (NAME TYPE) entries, holding
ROWS, a sequence of sequences of native values (one per column, +NULL+ for
NULL). Without REPLACE an existing table is an ALREADY_EXISTS error. Returns
the number of rows."
  (with-open-instance (session database)
    (unless (and (stringp table) (plusp (length table)))
      (api-error "INVALID_REQUEST" "invalid table name ~S" table))
    (let* ((defs (column-defs-from-spec columns))
           (converters (map 'simple-vector (lambda (d) (internal-converter (pq::column-def-type d)))
                            defs))
           (width (length defs))
           (count (length rows))
           (data (coerce (loop repeat width collect (make-array count)) 'simple-vector))
           (i 0))
      (pq::check-column-names (mapcar #'pq::column-def-name defs))
      (when (> count (pq::engine-config-max-table-rows (pq::session-config session)))
        (api-error "RESOURCE_LIMIT" "table exceeds the maximum of ~D rows"
                   (pq::engine-config-max-table-rows (pq::session-config session))))
      (map nil (lambda (row)
                 (unless (= (length row) width)
                   (api-error "INVALID_REQUEST" "row ~D has ~D values, expected ~D"
                              (1+ i) (length row) width))
                 (let ((k 0))
                   (map nil (lambda (v)
                              (setf (svref (svref data k) i)
                                    (funcall (the function (svref converters k)) v))
                              (incf k))
                        row))
                 (incf i))
           rows)
      (pq::catalog-add-table (session-catalog* session)
                             (pq::make-table table defs data count)
                             :replace replace)
      count)))

(defun save-table (database table path)
  "Write TABLE as a PQCF file at PATH (relative to the data directory),
replacing the file atomically. Returns the file size in bytes."
  (with-open-instance (session database)
    (let ((native (pq::resolve-data-path (pq::session-config session) (native-path path))))
      (unless (pq::catalog-table-exists-p (session-catalog* session) table)
        (api-error "NOT_FOUND" "table ~A not found" table))
      (pq::save-table session table native))))

(defun open-table (database table path &key replace)
  "Open the PQCF file at PATH (relative to the data directory) as the table
TABLE. Without REPLACE an existing table is an ALREADY_EXISTS error. Returns
the number of rows."
  (with-open-instance (session database)
    (when (zerop (length table))
      (api-error "INVALID_REQUEST" "table name must not be empty"))
    (let ((native (pq::resolve-data-path (pq::session-config session) (native-path path))))
      (pq::table-row-count (pq::open-table session table native :replace replace)))))

(defun native-path (path)
  (etypecase path
    (string path)
    (pathname (sb-ext:native-namestring path))))

(defun drop-table (database table)
  "Remove TABLE (and its indexes); NOT_FOUND if there is no such table."
  (with-open-instance (session database)
    (pq::catalog-drop-table (session-catalog* session) table)
    nil))

(defun list-tables (database)
  "The names of DATABASE's tables, sorted case-insensitively."
  (with-open-instance (session database)
    (mapcar #'pq::table-name (pq::catalog-list-tables (session-catalog* session)))))

(defun table-exists-p (database table)
  "True if DATABASE has a table called TABLE (ASCII case-insensitive)."
  (with-open-instance (session database)
    (pq::catalog-table-exists-p (session-catalog* session) table)))

(defun table-schema (database table)
  "The columns (a list of COLUMN) of TABLE and, as a second value, its row count."
  (with-open-instance (session database)
    (let ((tb (or (pq::catalog-find-table (session-catalog* session) table)
                  (api-error "NOT_FOUND" "table ~A not found" table))))
      (values (table-columns tb) (pq::table-row-count tb)))))
