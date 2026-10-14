;;;; table.lisp — immutable in-memory tables in row or column layout.
;;;;
;;;; A table is an immutable value: loading or opening produces a fresh table
;;;; object that is published atomically in the catalog. Its rows are split
;;;; into SEGMENTs (one for loaded tables, one per row group for tables opened
;;;; from PQCF files). A segment stores its rows either
;;;;   * column-oriented (:COLUMN layout): one COLUMN-STORE per column, possibly
;;;;     a LAZY-CHUNK that is decoded (and checksum-verified) on first use, or
;;;;   * row-oriented (:ROW layout): a SIMPLE-VECTOR of row tuples.
;;;; Segments may carry per-column CHUNK-STATS (min/max/null count) used to
;;;; skip whole segments during scans.
;;;;
;;;; Rows are addressed by a global row id (0-based position in the table),
;;;; which is what indexes store.

(in-package #:polyquery)

(defstruct (column-def (:constructor make-column-def (name type)))
  (name "" :type string)
  type)

(defstruct chunk-stats
  "Bounds of one column within a segment; MIN/MAX are NIL when unknown."
  (null-count nil)
  (min nil)
  (max nil))

(defstruct (lazy-chunk (:constructor make-lazy-chunk (loader)))
  (loader nil :type function))

(defstruct segment
  (start 0 :type fixnum)                 ; global row id of the first row
  (count 0 :type fixnum)
  (columns nil)                          ; :COLUMN layout: SIMPLE-VECTOR of stores / LAZY-CHUNKs
  (rows nil)                             ; :ROW layout: SIMPLE-VECTOR of row vectors
  (stats nil))                           ; SIMPLE-VECTOR of CHUNK-STATS (or NIL entries), or NIL

(defstruct (table (:constructor %make-table))
  (name "" :type string)
  (columns #() :type simple-vector)      ; of COLUMN-DEF
  (layout :column)                       ; :COLUMN or :ROW
  (segments #() :type simple-vector)     ; of SEGMENT, in row order
  (row-count 0 :type fixnum)
  (stats-cache nil)                      ; per column: COLUMN-STATISTICS or NIL (see stats.lisp)
  (source nil))                          ; NIL, or a description of the backing file

(defun table-column-count (table)
  (length (table-columns table)))

(defun table-column-type (table index)
  (column-def-type (svref (table-columns table) index)))

(defun find-column-index (table name)
  "Index of the column called NAME (ASCII case-insensitive) or NIL."
  (position name (table-columns table)
            :key #'column-def-name :test #'ascii-string-equal))

(defun columns-json (column-defs)
  "Protocol representation of column metadata."
  (loop for c across (coerce column-defs 'simple-vector)
        collect (jobj "name" (column-def-name c)
                      "type" (type-name-string (column-def-type c)))))

;;; ------------------------------------------------------------------
;;; Construction

(defun make-table-from-segments (name column-defs segments &key (layout :column) source)
  (let ((segments (coerce segments 'simple-vector)))
    (%make-table :name name
                 :columns (coerce column-defs 'simple-vector)
                 :layout layout
                 :segments segments
                 :row-count (loop for s across segments sum (segment-count s))
                 :stats-cache (make-array (length column-defs) :initial-element nil)
                 :source source)))

(defun rows-from-columns (column-data row-count)
  "Row tuples built from per-column value vectors."
  (let* ((columns (coerce column-data 'simple-vector))
         (width (length columns))
         (rows (make-array row-count)))
    (dotimes (i row-count rows)
      (let ((row (make-array width)))
        (dotimes (k width)
          (setf (svref row k) (svref (svref columns k) i)))
        (setf (svref rows i) row)))))

(defun make-table (name column-defs column-data row-count &key (layout :column) (dictionary :auto))
  "Table NAME from per-column SIMPLE-VECTORs of values (COLUMN-DATA), stored
in LAYOUT (:COLUMN or :ROW). DICTIONARY controls dictionary encoding of STRING
columns in the column layout (T, NIL or :AUTO)."
  (let ((defs (coerce column-defs 'simple-vector)))
    (make-table-from-segments
     name defs
     (list (ecase layout
             (:column
              (make-segment :start 0 :count row-count
                            :columns (map 'simple-vector
                                          (lambda (def values)
                                            (build-column-store values (column-def-type def)
                                                                :dictionary dictionary))
                                          defs column-data)))
             (:row
              (make-segment :start 0 :count row-count
                            :rows (rows-from-columns column-data row-count)))))
     :layout layout)))

;;; ------------------------------------------------------------------
;;; Construction from column stores (ingestion)

(defun rows-from-stores (stores row-count)
  "Row tuples holding the values of the COLUMN-STOREs STORES."
  (let* ((readers (map 'simple-vector #'column-reader stores))
         (width (length readers))
         (rows (progn (ensure-heap-room (* row-count (+ 24 (* 8 width))))
                      (make-array row-count))))
    (dotimes (i row-count rows)
      (when (zerop (mod i 65536)) (check-heap))
      (let ((row (make-array width)))
        (dotimes (k width)
          (setf (svref row k) (funcall (the function (svref readers k)) i)))
        (setf (svref rows i) row)))))

(defun make-table-from-stores (name column-defs stores row-count &key (layout :column))
  "Table NAME holding the COLUMN-STOREs STORES (one per column, ROW-COUNT
values each) in LAYOUT."
  (let ((stores (coerce stores 'simple-vector)))
    (make-table-from-segments
     name column-defs
     (list (ecase layout
             (:column (make-segment :start 0 :count row-count :columns stores))
             (:row (make-segment :start 0 :count row-count
                                 :rows (rows-from-stores stores row-count)))))
     :layout layout)))

;;; ------------------------------------------------------------------
;;; Access

(defun segment-column (segment k)
  "The COLUMN-STORE of column K in a column-layout SEGMENT, decoding a lazy
chunk on first access."
  (let* ((columns (segment-columns segment))
         (c (svref columns k)))
    (if (lazy-chunk-p c)
        (setf (svref columns k) (funcall (lazy-chunk-loader c)))
        c)))

(defun segment-column-reader (segment k)
  "Function (local-row-index) -> value of column K in SEGMENT."
  (if (segment-rows segment)
      (let ((rows (segment-rows segment)))
        (declare (type simple-vector rows))
        (lambda (i) (declare (type fixnum i)) (svref (svref rows i) k)))
      (if (zerop (segment-count segment))
          (lambda (i) (declare (ignore i)) +null+)
          (column-reader (segment-column segment k)))))

(defun segment-chunk-stats (segment k)
  (let ((stats (segment-stats segment)))
    (and stats (svref stats k))))

(defun map-column-values (fn table k)
  "Call FN with (row-id value) for every row of column K, in row order."
  (declare (type function fn))
  (loop for seg across (table-segments table)
        for start of-type fixnum = (segment-start seg)
        unless (zerop (segment-count seg))
          do (let ((read (segment-column-reader seg k)))
               (declare (type function read))
               (dotimes (i (segment-count seg))
                 (funcall fn (+ start i) (funcall read i))))))

(defun table-column-values (table k)
  "All values of column K as a SIMPLE-VECTOR (row-id order)."
  (let ((out (make-array (table-row-count table))))
    (map-column-values (lambda (id v) (setf (svref out id) v)) table k)
    out))

(defun find-segment-index (table row-id)
  "Index of the segment containing ROW-ID (binary search on segment starts)."
  (let* ((segs (table-segments table))
         (lo 0) (hi (1- (length segs))))
    (declare (type fixnum lo hi))
    (loop while (< lo hi)
          do (let ((mid (ceiling (+ lo hi) 2)))
               (if (<= (segment-start (svref segs mid)) row-id)
                   (setf lo mid)
                   (setf hi (1- mid)))))
    lo))

(defun table-row-fetcher (table column-indexes)
  "Function (row-id) -> fresh row vector holding COLUMN-INDEXES of that row."
  (let* ((segs (table-segments table))
         (column-indexes (coerce column-indexes 'simple-vector))
         (width (length column-indexes))
         (readers (make-array (length segs) :initial-element nil)))
    (flet ((segment-readers (s)
             (or (svref readers s)
                 (setf (svref readers s)
                       (let ((seg (svref segs s)))
                         (map 'simple-vector (lambda (k) (segment-column-reader seg k))
                              column-indexes))))))
      (lambda (row-id)
        (let* ((s (find-segment-index table row-id))
               (local (- row-id (segment-start (svref segs s))))
               (rs (segment-readers s))
               (row (make-array width)))
          (dotimes (k width row)
            (setf (svref row k) (funcall (the function (svref rs k)) local))))))))

(defun table-layout-name (table)
  (ecase (table-layout table) (:column "column") (:row "row")))
