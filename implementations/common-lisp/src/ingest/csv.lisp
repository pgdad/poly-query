;;;; csv.lisp — RFC 4180 CSV ingestion (ingestion.md §1).
;;;;
;;;; The input is read as raw UTF-8 octets in blocks (an OCTET-SOURCE), so a
;;;; file is never held in memory as a whole: all structural characters are
;;;; ASCII, so records can be split without decoding. Each record is scanned
;;;; into a CSV-RECORD of field spans within the current block; a record cut
;;;; by the end of a block is scanned again after the block is refilled.
;;;; Fields are converted straight from their octets into typed COLUMN-
;;;; BUILDERs (builders.lisp): integers, narrow decimals, floats and booleans
;;;; in plain ASCII are parsed without creating a string, strings of
;;;; dictionary columns are interned without allocating when they repeat;
;;;; everything else goes through the text conversions of values.lisp.
;;;;
;;;; Error precedence is that of a parse of the whole input followed by a
;;;; conversion of each column in turn: structural errors (field counts,
;;;; quoting, invalid UTF-8, field length, row limit) are reported in input
;;;; order; header problems and conversion errors are remembered and reported
;;;; after the whole input was scanned, conversion errors for the leftmost
;;;; failing column. Without an explicit schema the input is scanned twice:
;;;; once to infer the column types, once to convert.

(in-package #:polyquery)

(deftype octets () '(simple-array (unsigned-byte 8) (*)))

(defparameter *csv-block-size* (* 8 1024 1024)
  "Octets read from a file at a time.")

;;; ------------------------------------------------------------------
;;; Octet sources

(defstruct (octet-source (:constructor %make-octet-source))
  (buffer (make-array 0 :element-type '(unsigned-byte 8)) :type octets)
  (end 0 :type fixnum)                   ; valid octets in BUFFER
  (stream nil)                           ; open file stream, or NIL
  (eof t))                               ; nothing follows BUFFER[0,END)

(defun make-memory-source (octets)
  (let ((octets (coerce octets 'octets)))
    (%make-octet-source :buffer octets :end (length octets) :eof t)))

(defun source-refill (source keep)
  "Discard the octets before KEEP, then read more input after the rest
(growing the buffer when the rest fills it). Returns the new position of
the octet at KEEP."
  (let* ((buffer (octet-source-buffer source))
         (rest (- (octet-source-end source) keep)))
    (when (>= rest (floor (length buffer) 2))
      (let ((bigger (progn (ensure-heap-room (* 2 (length buffer)))
                           (make-array (* 2 (length buffer)) :element-type '(unsigned-byte 8)))))
        (replace bigger buffer :start2 keep :end2 (octet-source-end source))
        (setf buffer bigger
              (octet-source-buffer source) bigger
              keep 0)))
    (unless (zerop keep)
      (replace buffer buffer :start2 keep :end2 (octet-source-end source)))
    (let ((end (handler-case (read-sequence buffer (octet-source-stream source) :start rest)
                 (stream-error () (signal-pq-error "IO_ERROR" "cannot read input file")))))
      (setf (octet-source-end source) end
            (octet-source-eof source) (< end (length buffer))))
    0))

(defun call-with-octet-source (input fn)
  "Call FN with an OCTET-SOURCE over INPUT: an octet vector, or the native
path of a file (read in blocks)."
  (if (stringp input)
      (call-with-input-file-checked
       input
       (lambda (stream)
         (let ((source (%make-octet-source
                        :buffer (make-array *csv-block-size* :element-type '(unsigned-byte 8))
                        :end 0 :stream stream :eof nil)))
           (source-refill source 0)
           (funcall fn source))))
      (funcall fn (make-memory-source input))))

;;; ------------------------------------------------------------------
;;; Records

(defconstant +field-quoted+ 1)
(defconstant +field-escaped+ 2)            ; quoted and contains ""
(defconstant +field-non-ascii+ 4)

(defstruct (csv-record (:constructor make-csv-record ()))
  (bytes (make-array 0 :element-type '(unsigned-byte 8)) :type octets)
  (count 0 :type fixnum)
  (number 0 :type fixnum)                ; 1-based record number
  (starts (make-array 16 :element-type 'fixnum) :type (simple-array fixnum (*)))
  (ends (make-array 16 :element-type 'fixnum) :type (simple-array fixnum (*)))
  (flags (make-array 16 :element-type '(unsigned-byte 8)) :type (simple-array (unsigned-byte 8) (*)))
  (texts (make-array 16 :initial-element nil) :type simple-vector) ; decoded non-ASCII fields
  (scratch (make-array 256 :element-type '(unsigned-byte 8)) :type octets))

(defun record-grow (record)
  (flet ((grow (v &rest args)
           (let ((new (apply #'make-array (* 2 (length v)) args)))
             (replace new v)
             new)))
    (setf (csv-record-starts record) (grow (csv-record-starts record) :element-type 'fixnum)
          (csv-record-ends record) (grow (csv-record-ends record) :element-type 'fixnum)
          (csv-record-flags record) (grow (csv-record-flags record) :element-type '(unsigned-byte 8))
          (csv-record-texts record) (grow (csv-record-texts record) :initial-element nil))))

(defun unescape-field (record k)
  "The octets of the quoted field K with \"\" collapsed, as (values octets end)
in the record's scratch buffer."
  (let* ((bytes (csv-record-bytes record))
         (start (aref (csv-record-starts record) k))
         (end (aref (csv-record-ends record) k))
         (scratch (csv-record-scratch record)))
    (when (> (- end start) (length scratch))
      (setf scratch (make-array (- end start) :element-type '(unsigned-byte 8))
            (csv-record-scratch record) scratch))
    (let ((j 0) (i start))
      (declare (type fixnum i j))
      (loop while (< i end)
            do (setf (aref scratch j) (aref bytes i))
               (incf j)
               (incf i (if (= (aref bytes i) 34) 2 1)))
      (values scratch j))))

(defun record-field-octets (record k)
  "The octets of field K (unescaped): (values octets start end)."
  (if (logtest (aref (csv-record-flags record) k) +field-escaped+)
      (multiple-value-bind (scratch end) (unescape-field record k)
        (values scratch 0 end))
      (values (csv-record-bytes record)
              (aref (csv-record-starts record) k)
              (aref (csv-record-ends record) k))))

(defun decode-field (bytes start end)
  "Decode BYTES[START,END) as UTF-8 text."
  (declare (type octets bytes) (type fixnum start end))
  (if (loop for i of-type fixnum from start below end always (< (aref bytes i) 128))
      (let ((s (make-string (- end start))))
        (loop for i of-type fixnum from start below end
              for j of-type fixnum from 0
              do (setf (schar s j) (code-char (aref bytes i))))
        s)
      (handler-case (sb-ext:octets-to-string bytes :start start :end end :external-format :utf-8)
        (error () (ingest-error "invalid UTF-8 in input")))))

(defun complete-field (record k)
  "Checks made as soon as field K is scanned: its length, and the UTF-8
validity of non-ASCII text (which is decoded once here)."
  (multiple-value-bind (bytes start end) (record-field-octets record k)
    (when (> (- end start) +max-field-bytes+)
      (ingest-error "field longer than 16 MiB"))
    (setf (svref (csv-record-texts record) k)
          (when (logtest (aref (csv-record-flags record) k) +field-non-ascii+)
            (decode-field bytes start end)))))

(defun record-field-string (record k)
  "The text of field K as a fresh string (NIL for an unquoted empty field)."
  (let ((flags (aref (csv-record-flags record) k)))
    (cond ((logtest flags +field-non-ascii+) (svref (csv-record-texts record) k))
          ((and (zerop (logand flags +field-quoted+))
                (= (aref (csv-record-starts record) k) (aref (csv-record-ends record) k)))
           nil)
          (t (multiple-value-bind (bytes start end) (record-field-octets record k)
               (decode-field bytes start end))))))

;;; ------------------------------------------------------------------
;;; Scanning

(defun scan-record (source pos delimiter record)
  "Scan the record starting at POS. Returns the position after it, :EMPTY-LINE
(with the position after the line as second value), :INCOMPLETE when the
block ends inside the record, or NIL at the end of the input."
  (declare (type fixnum pos) (optimize speed))
  (let* ((bytes (octet-source-buffer source))
         (n (octet-source-end source))
         (eof (octet-source-eof source))
         (delim (char-code delimiter))
         (i pos)
         (k 0))
    (declare (type octets bytes) (type fixnum n i k delim))
    (macrolet ((at (j)
                 ;; the octet at J, or -1 at the end of the input
                 `(let ((j ,j))
                    (declare (type fixnum j))
                    (cond ((< j n) (aref bytes j))
                          (eof -1)
                          (t (return-from scan-record :incomplete))))))
      (let ((c (at i)))
        (cond ((= c -1) (return-from scan-record nil))
              ((= c 10) (return-from scan-record (values :empty-line (1+ i))))
              ((and (= c 13) (= (at (1+ i)) 10))
               (return-from scan-record (values :empty-line (+ i 2))))))
      (setf (csv-record-bytes record) bytes)
      (let ((number (1+ (csv-record-number record))))
        (loop
          (when (= k (length (csv-record-starts record)))
            (record-grow record))
          (let ((starts (csv-record-starts record))
                (ends (csv-record-ends record))
                (flags (csv-record-flags record)))
            (if (= (at i) 34)
                ;; quoted field
                (let ((escaped 0) (high 0))
                  (declare (type fixnum escaped high))
                  (incf i)
                  (setf (aref starts k) i)
                  (loop
                    (let ((c (at i)))
                      (declare (type fixnum c))
                      (cond ((= c -1)
                             (ingest-error "unterminated quoted field in record ~D" number))
                            ((/= c 34) (setf high (logior high c)) (incf i))
                            ((= (at (1+ i)) 34) (setf escaped +field-escaped+) (incf i 2))
                            (t (setf (aref ends k) i) (incf i) (return)))))
                  (setf (aref flags k) (logior +field-quoted+ escaped
                                               (if (>= high 128) +field-non-ascii+ 0)))
                  (complete-field record k)
                  (let ((c (at i)))
                    (unless (or (= c -1) (= c delim) (= c 10)
                                (and (= c 13) (= (at (1+ i)) 10)))
                      (ingest-error "unexpected character after closing quote in record ~D" number))))
                ;; unquoted field
                (let ((high 0))
                  (declare (type fixnum high))
                  (setf (aref starts k) i)
                  (loop
                    (let ((c (at i)))
                      (declare (type fixnum c))
                      (when (or (= c -1) (= c delim) (= c 10)
                                (and (= c 13) (= (at (1+ i)) 10)))
                        (return))
                      (setf high (logior high c))
                      (incf i)))
                  (setf (aref ends k) i
                        (aref flags k) (if (>= high 128) +field-non-ascii+ 0))
                  (complete-field record k)))
            (incf k)
            ;; after a field: delimiter, record terminator or end of input
            (let ((c (at i)))
              (cond ((= c -1) (return))
                    ((= c delim) (incf i))
                    ((= c 10) (incf i) (return))
                    (t (incf i 2) (return))))))
        (setf (csv-record-count record) k
              (csv-record-number record) number)
        i))))

(defun map-csv-records (source delimiter fn)
  "Call FN with a CSV-RECORD for each record of SOURCE (the record and its
octets are only valid during the call)."
  (let ((record (make-csv-record))
        (pos 0))
    (declare (type fixnum pos))
    (loop while (and (< (octet-source-end source) 3) (not (octet-source-eof source)))
          do (source-refill source 0))
    (let ((bytes (octet-source-buffer source)))
      (when (and (>= (octet-source-end source) 3)
                 (= (aref bytes 0) #xEF) (= (aref bytes 1) #xBB) (= (aref bytes 2) #xBF))
        (setf pos 3)))
    (loop
      (multiple-value-bind (next after-empty) (scan-record source pos delimiter record)
        (case next
          ((nil) (return))
          (:empty-line (setf pos after-empty))
          (:incomplete (setf pos (source-refill source pos)))
          (t (funcall fn record)
             (setf pos next)))))))

;;; ------------------------------------------------------------------
;;; Field conversion

(defun ascii-span-trim (bytes start end)
  "Bounds of BYTES[START,END) without leading/trailing spaces and tabs."
  (declare (type octets bytes) (type fixnum start end))
  (loop while (and (< start end) (member (aref bytes start) '(32 9))) do (incf start))
  (loop while (and (< start end) (member (aref bytes (1- end)) '(32 9))) do (decf end))
  (values start end))

(defun octets-unsigned (bytes start end)
  "The value of the ASCII digits BYTES[START,END) (1-18 digits) or NIL."
  (declare (type octets bytes) (type fixnum start end) (optimize speed))
  (when (<= 1 (- end start) 18)
    (let ((v 0))
      (declare (type (unsigned-byte 60) v))
      (loop for i of-type fixnum from start below end
            for d = (- (aref bytes i) 48)
            do (if (<= 0 d 9)
                   (setf v (+ (* v 10) d))
                   (return-from octets-unsigned nil)))
      v)))

(defun octets-sign (bytes start end)
  "(values negative-p start-after-sign)"
  (declare (type octets bytes) (type fixnum start end))
  (if (< start end)
      (case (aref bytes start)
        (43 (values nil (1+ start)))
        (45 (values t (1+ start)))
        (t (values nil start)))
      (values nil start)))

(defun octets-decimal-parts (bytes start end)
  "Parse [+-]?D*(.D*)? with 1-18 digits: (values negative-p digits-value
fraction-digits) or NIL."
  (declare (type octets bytes) (type fixnum start end))
  (multiple-value-bind (neg start) (octets-sign bytes start end)
    (let ((dot (position 46 bytes :start start :end end)))
      (if (null dot)
          (let ((v (octets-unsigned bytes start end)))
            (and v (values neg v 0)))
          (let ((int-digits (- dot start))
                (frac-digits (- end dot 1)))
            (when (<= 1 (+ int-digits frac-digits) 18)
              (let ((iv (if (zerop int-digits) 0 (octets-unsigned bytes start dot)))
                    (fv (if (zerop frac-digits) 0 (octets-unsigned bytes (1+ dot) end))))
                (and iv fv (values neg (+ (* iv (pow10 frac-digits)) fv) frac-digits)))))))))

(defun fast-convert (bytes start end type)
  "Convert the trimmed, non-empty ASCII text BYTES[START,END) to a value of
TYPE when it has the plain form the common cases use; otherwise NIL (the
caller then converts the text with TEXT-TO-VALUE, which also reports errors).
Agrees with TEXT-TO-VALUE on every input it accepts."
  (declare (type octets bytes) (type fixnum start end))
  (case (type-kind type)
    (:int64
     (multiple-value-bind (neg s) (octets-sign bytes start end)
       (let ((v (octets-unsigned bytes s end)))
         (and v (if neg (- v) v)))))
    (:decimal
     (unless (wide-decimal-type-p type)
       (multiple-value-bind (neg v frac) (octets-decimal-parts bytes start end)
         (let ((scale (decimal-scale type)))
           (when (and v (<= frac scale))
             (let ((unscaled (* v (pow10 (- scale frac)))))
               (when (fits-precision-p unscaled (decimal-precision type))
                 (if neg (- unscaled) unscaled))))))))
    (:float64
     (multiple-value-bind (neg v frac) (octets-decimal-parts bytes start end)
       (when (and v (< v (expt 10 15)))
         (let ((d (/ (coerce v 'double-float) (aref *exact-double-powers* frac))))
           (if neg (- d) d)))))
    (:boolean
     (let ((len (- end start)))
       (flet ((matches (word)
                (loop for i from 0 below len
                      always (= (logior (aref bytes (+ start i)) 32) (char-code (char word i))))))
         (cond ((and (= len 4) (matches "true")) :true)
               ((and (= len 5) (matches "false")) :false)))))))

(defun conversion-failure (record-number column-name text type explicit)
  "The CONVERSION_ERROR condition for TEXT in a column (not signalled)."
  (make-condition 'pq-error
                  :code "CONVERSION_ERROR"
                  :details (list (cons "record" record-number) (cons "column_name" column-name))
                  :message (format nil "record ~D, column ~A: cannot convert ~S to ~A~:[~; (inferred)~]"
                                   record-number column-name text (type-name-string type)
                                   (not explicit))))

(defstruct (csv-column (:constructor make-csv-column (name type builder)))
  (name "" :type string)
  type
  builder
  (failure nil))                         ; first CONVERSION_ERROR, if any

(defun append-text-value (column text record-number explicit)
  "Convert the already trimmed, non-empty TEXT and append it to COLUMN."
  (let ((type (csv-column-type column)))
    (multiple-value-bind (v status) (text-to-value text type)
      (if (eq status :ok)
          (builder-append-value (csv-column-builder column) v)
          (setf (csv-column-failure column)
                (conversion-failure record-number (csv-column-name column) text type explicit))))))

(defun append-csv-field (column record k explicit)
  "Convert field K of RECORD and append it to COLUMN (unless the column
already failed)."
  (unless (csv-column-failure column)
    (let* ((builder (csv-column-builder column))
           (type (csv-column-type column))
           (flags (aref (csv-record-flags record) k))
           (stringp (member (type-kind type) '(:string :null))))
      (multiple-value-bind (bytes start end) (record-field-octets record k)
        (cond
          ;; NULL: an unquoted empty field; a quoted empty one is "" for STRING
          ((= start end)
           (if (and stringp (logtest flags +field-quoted+))
               (builder-append-string builder "")
               (builder-append-null builder)))
          ((logtest flags +field-non-ascii+)
           (let ((text (svref (csv-record-texts record) k)))
             (if stringp
                 (builder-append-string builder text)
                 (let ((trimmed (trim-spaces-tabs text)))
                   (if (zerop (length trimmed))
                       (builder-append-null builder)
                       (append-text-value column trimmed (csv-record-number record) explicit))))))
          (stringp (builder-append-ascii builder bytes start end))
          (t
           (multiple-value-bind (s e) (ascii-span-trim bytes start end)
             (if (= s e)
                 (builder-append-null builder)
                 (let ((v (fast-convert bytes s e type)))
                   (case v
                     ((nil) (append-text-value column (decode-field bytes s e)
                                               (csv-record-number record) explicit))
                     (:true (builder-append-bool builder t))
                     (:false (builder-append-bool builder nil))
                     (t (builder-append-value builder v))))))))))))

;;; ------------------------------------------------------------------
;;; Type inference (first pass without an explicit schema)

(defun octets-plain-integer-p (bytes start end)
  (multiple-value-bind (neg s) (octets-sign bytes start end)
    (declare (ignore neg))
    (octets-unsigned bytes s end)))

(defun infer-field (masks seen record k)
  "Narrow the candidate mask of column K by field K of RECORD (texts empty
after trimming are not considered; SEEN[K] records that one was)."
  (let ((mask (aref masks k)))
    (when (plusp mask)
      (multiple-value-bind (bytes start end) (record-field-octets record k)
        (let ((narrowed
                (if (logtest (aref (csv-record-flags record) k) +field-non-ascii+)
                    (let ((text (trim-spaces-tabs (svref (csv-record-texts record) k))))
                      (and (plusp (length text)) (text-candidates text mask)))
                    (multiple-value-bind (s e) (ascii-span-trim bytes start end)
                      (and (< s e)
                           ;; a plain integer keeps INT64 and FLOAT64 and rules out
                           ;; DATE and TIMESTAMP (and BOOLEAN, checked by the slow path)
                           (if (and (not (logtest mask +cand-boolean+))
                                    (octets-plain-integer-p bytes s e))
                               (logand mask (logior +cand-int64+ +cand-float64+))
                               (text-candidates (decode-field bytes s e) mask)))))))
          (when narrowed
            (setf (aref masks k) narrowed
                  (svref seen k) t)))))))

;;; ------------------------------------------------------------------
;;; Ingestion

(defun csv-header-names (record)
  (loop for k below (csv-record-count record)
        collect (or (record-field-string record k) "")))

(defun check-field-count (record ncols)
  (unless (= (csv-record-count record) ncols)
    (signal-pq-error-with-details
     "INGEST_ERROR" (list (cons "record" (csv-record-number record)))
     "record ~D has ~D fields, expected ~D"
     (csv-record-number record) (csv-record-count record) ncols)))

(defun header-problem (names schema)
  "The INGEST_ERROR for a bad header (NAMES) or one that does not match the
explicit SCHEMA, as a condition, or NIL."
  (handler-case
      (progn
        (check-column-names names)
        (when schema
          (unless (and (= (length schema) (length names))
                       (every (lambda (c h) (ascii-string-equal (column-def-name c) h)) schema names))
            (ingest-error "CSV header does not match the explicit schema")))
        nil)
    (pq-error (e) e)))

(defun scan-csv (input spec on-header on-record)
  "Scan the CSV INPUT: ON-HEADER is called with the header names (if the
input has a header), ON-RECORD with every data record. Checks field counts
and the row limit. Returns the number of data rows."
  (let* ((header-p (ingest-spec-header spec))
         (schema (ingest-spec-schema spec))
         (ncols (if header-p nil (length schema)))
         (rows 0))
    (declare (type fixnum rows))
    (call-with-octet-source
     input
     (lambda (source)
       (map-csv-records
        source (ingest-spec-delimiter spec)
        (lambda (record)
          (cond ((null ncols)
                 (let ((names (csv-header-names record)))
                   (setf ncols (length names))
                   (funcall on-header names)))
                (t
                 (check-field-count record ncols)
                 (incf rows)
                 (when (> rows (ingest-spec-max-rows spec))
                   (check-row-limit rows spec))
                 (when (zerop (mod rows 4096))
                   (check-heap))
                 (funcall on-record record)))))))
    (when (and header-p (null ncols))
      (ingest-error "CSV input has no header record"))
    rows))

(defun infer-csv-types (input spec)
  "First pass without an explicit schema: (values names types)."
  (let ((names nil) (masks nil) (seen nil) (problem nil))
    (scan-csv input spec
              (lambda (header)
                (setf names header
                      problem (header-problem header nil)
                      masks (make-array (length header) :initial-element +cand-all+)
                      seen (make-array (length header) :initial-element nil)))
              (lambda (record)
                (dotimes (k (length names))
                  (infer-field masks seen record k))))
    (when problem (error problem))
    (values names
            (loop for k below (length names)
                  collect (if (svref seen k)
                              (candidates-to-type (aref masks k))
                              :string)))))

(defun ingest-csv (input spec &key (dictionary :auto))
  "Parse the CSV INPUT (an octet vector, or the native path of a file)
according to SPEC. Returns (values column-defs column-stores row-count)."
  (let* ((schema (ingest-spec-schema spec))
         (explicit (not (null schema)))
         (defs (if explicit
                   (mapcar (lambda (c) (make-column-def (column-def-name c) (column-def-type c))) schema)
                   (multiple-value-bind (names types) (infer-csv-types input spec)
                     (mapcar #'make-column-def names types))))
         (columns (map 'simple-vector
                       (lambda (def)
                         (make-csv-column (column-def-name def) (column-def-type def)
                                          (make-column-builder (column-def-type def)
                                                               :dictionary dictionary)))
                       defs))
         (problem nil)
         (rows (scan-csv input spec
                         (lambda (names)
                           (when explicit
                             (setf problem (header-problem names schema))))
                         (lambda (record)
                           (unless problem
                             (dotimes (k (length columns))
                               (append-csv-field (svref columns k) record k explicit)))))))
    (when (and explicit (not (ingest-spec-header spec)))
      (setf problem (handler-case (progn (check-column-names (mapcar #'column-def-name schema)) nil)
                      (pq-error (e) e))))
    (when problem (error problem))
    (let ((failed (find-if #'csv-column-failure columns)))
      (when failed (error (csv-column-failure failed))))
    (values defs
            (loop for column across columns
                  collect (prog1 (finish-column-builder (csv-column-builder column))
                            (setf (csv-column-builder column) nil)))
            rows)))
