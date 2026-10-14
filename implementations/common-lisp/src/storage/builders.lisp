;;;; builders.lisp — incremental construction of column stores.
;;;;
;;;; Ingestion appends values one row at a time without knowing the final
;;;; row count. A COLUMN-BUILDER collects them in fixed-size typed chunks
;;;; (no boxing, no per-value objects except strings) and assembles the final
;;;; COLUMN-STORE (see columns.lisp) at the end: memory stays at about one
;;;; copy of the column plus one chunk, instead of the value vectors, field
;;;; texts and growth copies of a vector-push-extend build.
;;;;
;;;; STRING builders that may produce a dictionary column intern their
;;;; values in a STRING-INTERNER, an open-addressing table that can be probed
;;;; with a span of ASCII octets as well as with a string, so repeated values
;;;; are recognised without allocating. Whether the result is dictionary
;;;; encoded follows the same rule as BUILD-COLUMN-STORE (DICTIONARY T, NIL or
;;;; :AUTO = fewer than n/2 distinct values and at least 16 rows).

(in-package #:polyquery)

(defconstant +builder-chunk-size+ 65536
  "Rows per builder chunk (a multiple of 64, so chunk bitmaps are word aligned).")

;;; ------------------------------------------------------------------
;;; String interner

(deftype u32-array () '(simple-array (unsigned-byte 32) (*)))

(defstruct (string-interner (:constructor %make-string-interner))
  (strings (make-array 16) :type simple-vector)     ; entry -> string
  (hashes (make-array 16 :element-type '(unsigned-byte 32)) :type u32-array)
  (count 0 :type fixnum)
  (slots (make-array 32 :element-type '(unsigned-byte 32) :initial-element 0)
   :type u32-array))                                ; entry + 1, 0 = empty

(defun make-string-interner ()
  (%make-string-interner))

;; 32-bit FNV-1a over character codes (octets of ASCII text are their codes).
(defconstant +fnv-offset+ 2166136261)
(defmacro fnv-mix (h code)
  `(logand (* (logxor ,h ,code) 16777619) #xFFFFFFFF))

(declaim (inline octets-hash string-hash-code))
(defun octets-hash (bytes start end)
  "Hash of the characters of an ASCII octet span (equal to STRING-HASH-CODE of
the same characters)."
  (declare (type (simple-array (unsigned-byte 8) (*)) bytes) (type fixnum start end)
           (optimize speed (safety 0)))
  (let ((h +fnv-offset+))
    (declare (type (unsigned-byte 32) h))
    (loop for i of-type fixnum from start below end
          do (setf h (fnv-mix h (aref bytes i))))
    h))

(defun string-hash-code (s)
  (declare (type simple-string s) (optimize speed (safety 0)))
  (let ((h +fnv-offset+))
    (declare (type (unsigned-byte 32) h))
    (dotimes (i (length s))
      (setf h (fnv-mix h (logand (char-code (schar s i)) #xFFFFFF))))
    h))

(defun interner-grow (interner)
  (let* ((old-strings (string-interner-strings interner))
         (count (string-interner-count interner))
         (capacity (* 2 (length old-strings)))
         (strings (make-array capacity))
         (hashes (make-array capacity :element-type '(unsigned-byte 32)))
         (slots (make-array (* 2 capacity) :element-type '(unsigned-byte 32) :initial-element 0))
         (mask (1- (length slots))))
    (check-heap)
    (replace strings old-strings :end2 count)
    (replace hashes (string-interner-hashes interner) :end2 count)
    (dotimes (e count)
      (loop for p = (logand (aref hashes e) mask) then (logand (1+ p) mask)
            when (zerop (aref slots p))
              do (setf (aref slots p) (1+ e)) (return)))
    (setf (string-interner-strings interner) strings
          (string-interner-hashes interner) hashes
          (string-interner-slots interner) slots)))

(defun interner-add (interner string hash slot)
  "Add STRING (with HASH) as a new entry stored in SLOT; returns its entry."
  (let ((e (string-interner-count interner)))
    (setf (svref (string-interner-strings interner) e) string
          (aref (string-interner-hashes interner) e) hash
          (aref (string-interner-slots interner) slot) (1+ e)
          (string-interner-count interner) (1+ e))
    (when (= (string-interner-count interner) (length (string-interner-strings interner)))
      (interner-grow interner))
    e))

(defun intern-string (interner string)
  "Entry number of STRING, adding it when new."
  (declare (type simple-string string))
  (let* ((hash (string-hash-code string))
         (slots (string-interner-slots interner))
         (mask (1- (length slots)))
         (strings (string-interner-strings interner))
         (hashes (string-interner-hashes interner)))
    (declare (type (unsigned-byte 32) hash) (type fixnum mask))
    (loop for p of-type fixnum = (logand hash mask) then (logand (1+ p) mask)
          for e of-type fixnum = (1- (aref slots p))
          do (cond ((minusp e) (return (interner-add interner string hash p)))
                   ((and (= (aref hashes e) hash) (string= (svref strings e) string))
                    (return e))))))

(defun intern-ascii-octets (interner bytes start end)
  "Entry number of the ASCII text BYTES[START,END), adding a fresh string when new."
  (declare (type (simple-array (unsigned-byte 8) (*)) bytes) (type fixnum start end)
           (optimize speed))
  (let* ((hash (octets-hash bytes start end))
         (len (- end start))
         (slots (string-interner-slots interner))
         (mask (1- (length slots)))
         (strings (string-interner-strings interner))
         (hashes (string-interner-hashes interner)))
    (declare (type (unsigned-byte 32) hash) (type fixnum mask len))
    (flet ((same-p (s)
             (declare (type simple-string s))
             (and (= (length s) len)
                  (loop for i of-type fixnum from 0 below len
                        always (= (char-code (schar s i)) (aref bytes (+ start i)))))))
      (loop for p of-type fixnum = (logand hash mask) then (logand (1+ p) mask)
            for e of-type fixnum = (1- (aref slots p))
            do (cond ((minusp e)
                      (let ((s (make-string len)))
                        (dotimes (i len)
                          (setf (schar s i) (code-char (aref bytes (+ start i)))))
                        (return (interner-add interner s hash p))))
                     ((and (= (aref hashes e) hash) (same-p (svref strings e)))
                      (return e)))))))

;;; ------------------------------------------------------------------
;;; Builders

(defstruct (column-builder (:constructor %make-column-builder))
  (kind :int :type (member :int :float :bool :wide :string :dict))
  (type nil)
  (dictionary :auto)
  (chunk nil)                            ; current chunk (typed array)
  (fill 0 :type fixnum)                  ; values in the current chunk
  (chunk-validity nil)                   ; bit vector of the current chunk, or NIL
  (chunks '())                           ; full chunks, most recent first: (values . validity)
  (count 0 :type fixnum)                 ; total values
  (any-null nil)
  (interner nil))                        ; :DICT builders

(defun builder-kind-for-type (type dictionary)
  (if (wide-decimal-type-p type)
      :wide
      (ecase (type-kind type)
        ((:int64 :decimal :date :timestamp) :int)
        (:float64 :float)
        (:boolean :bool)
        ((:string :null) (if dictionary :dict :string)))))

(defun new-builder-chunk (kind)
  (check-heap)
  (let ((n +builder-chunk-size+))
    (ecase kind
      (:int (make-array n :element-type '(signed-byte 64) :initial-element 0))
      (:float (make-array n :element-type 'double-float :initial-element 0d0))
      (:bool (make-array n :element-type 'bit :initial-element 0))
      (:wide (make-array n :initial-element 0))
      (:string (make-array n :initial-element ""))
      (:dict (make-array n :element-type '(unsigned-byte 32) :initial-element 0)))))

(defun make-column-builder (type &key (dictionary :auto))
  "A builder for a column of TYPE. DICTIONARY applies to STRING columns."
  (let ((kind (builder-kind-for-type type dictionary)))
    (%make-column-builder :kind kind :type type :dictionary dictionary
                          :chunk (new-builder-chunk kind)
                          :interner (and (eq kind :dict) (make-string-interner)))))

(defun builder-next-slot (b)
  "Index in the current chunk for the next value (starting a new chunk when
the current one is full)."
  (declare (type column-builder b))
  (when (= (column-builder-fill b) +builder-chunk-size+)
    (push (cons (column-builder-chunk b) (column-builder-chunk-validity b))
          (column-builder-chunks b))
    (setf (column-builder-chunk b) (new-builder-chunk (column-builder-kind b))
          (column-builder-fill b) 0
          (column-builder-chunk-validity b) nil))
  (column-builder-fill b))

(defmacro define-builder-append (name (value-var) &body store)
  "Define (NAME builder value): store VALUE-VAR in the current chunk, which
STORE does with CHUNK and SLOT bound."
  `(defun ,name (b ,value-var)
     (declare (type column-builder b))
     (let ((slot (builder-next-slot b))
           (chunk (column-builder-chunk b)))
       (declare (type fixnum slot) (ignorable chunk))
       ,@store
       (setf (column-builder-fill b) (1+ slot))
       (incf (column-builder-count b)))
     nil))

(defun builder-append-null (b)
  (declare (type column-builder b))
  (let* ((slot (builder-next-slot b))
         (validity (or (column-builder-chunk-validity b)
                      (setf (column-builder-chunk-validity b)
                            (make-array +builder-chunk-size+ :element-type 'bit
                                                             :initial-element 1)))))
    (setf (sbit validity slot) 0
          (column-builder-any-null b) t
          (column-builder-fill b) (1+ slot))
    (incf (column-builder-count b))
    nil))

(define-builder-append builder-append-int (v)
  (setf (aref (the (simple-array (signed-byte 64) (*)) chunk) slot) v))

(define-builder-append builder-append-float (v)
  (setf (aref (the (simple-array double-float (*)) chunk) slot) v))

(define-builder-append builder-append-bool (v)
  (setf (sbit (the simple-bit-vector chunk) slot) (if v 1 0)))

(define-builder-append builder-append-generic (v)
  (setf (svref chunk slot) v))

(define-builder-append builder-append-code (code)
  (setf (aref (the (simple-array (unsigned-byte 32) (*)) chunk) slot) code))

(defun builder-append-string (b s)
  (if (eq (column-builder-kind b) :dict)
      (builder-append-code b (intern-string (column-builder-interner b) s))
      (builder-append-generic b s)))

(defun builder-append-ascii (b bytes start end)
  "Append the ASCII text BYTES[START,END) to a STRING builder."
  (if (eq (column-builder-kind b) :dict)
      (builder-append-code b (intern-ascii-octets (column-builder-interner b) bytes start end))
      (builder-append-generic b (let ((s (make-string (- end start))))
                                  (loop for i from start below end
                                        for j from 0
                                        do (setf (schar s j) (code-char (aref bytes i))))
                                  s))))

(defun builder-append-value (b v)
  "Append the runtime value V (or +NULL+) of the builder's type."
  (cond ((null-value-p v) (builder-append-null b))
        (t (ecase (column-builder-kind b)
             (:int (builder-append-int b v))
             (:float (builder-append-float b v))
             (:bool (builder-append-bool b v))
             (:wide (builder-append-generic b v))
             ((:string :dict) (builder-append-string b v))))))

;;; ------------------------------------------------------------------
;;; Assembly

(defun builder-element-bytes (kind)
  (ecase kind ((:int :float :wide :string) 8) (:dict 4) (:bool 1/8)))

(defun assemble-chunks (b element-type initial-element)
  "The values of builder B as one array of ELEMENT-TYPE, and its validity
bitmap (or NIL). The chunks are released as they are copied."
  (let* ((n (column-builder-count b))
         (chunks (reverse (cons (cons (column-builder-chunk b) (column-builder-chunk-validity b))
                                (column-builder-chunks b))))
         (_ (ensure-heap-room (ceiling (* n (builder-element-bytes (column-builder-kind b))))))
         (out (make-array n :element-type element-type :initial-element initial-element))
         (validity (and (column-builder-any-null b)
                        (make-array n :element-type 'bit :initial-element 1)))
         (start 0))
    (declare (ignore _) (type fixnum start))
    (setf (column-builder-chunks b) '()
          (column-builder-chunk b) nil)
    (loop while chunks
          do (destructuring-bind (values . bits) (pop chunks)
               (let ((count (min +builder-chunk-size+ (- n start))))
                 (replace out values :start1 start :end2 count)
                 (when bits
                   (replace validity bits :start1 start :end2 count))
                 (incf start count))))
    (values out validity)))

(defun finish-column-builder (b)
  "The COLUMN-STORE holding the values appended to builder B."
  (let ((n (column-builder-count b)))
    (ecase (column-builder-kind b)
      (:int (multiple-value-bind (v valid) (assemble-chunks b '(signed-byte 64) 0)
              (make-int-column :length n :validity valid :values v)))
      (:float (multiple-value-bind (v valid) (assemble-chunks b 'double-float 0d0)
                (make-float-column :length n :validity valid :values v)))
      (:bool (multiple-value-bind (v valid) (assemble-chunks b 'bit 0)
               (make-bool-column :length n :validity valid :values v)))
      (:wide (multiple-value-bind (v valid) (assemble-chunks b t 0)
               (make-wide-column :length n :validity valid :values v)))
      (:string (multiple-value-bind (v valid) (assemble-chunks b t "")
                 (make-string-column :length n :validity valid :values v)))
      (:dict (finish-dict-builder b)))))

(defun finish-dict-builder (b)
  "A dictionary column, or a plain string column when the dictionary does not
pay off under :AUTO (see DICTIONARY-BENEFICIAL-P)."
  (let* ((n (column-builder-count b))
         (interner (column-builder-interner b))
         (distinct (string-interner-count interner))
         (dict (subseq (string-interner-strings interner) 0 distinct)))
    (setf (column-builder-interner b) nil)
    (multiple-value-bind (codes validity) (assemble-chunks b '(unsigned-byte 32) 0)
      (declare (type (simple-array (unsigned-byte 32) (*)) codes))
      (if (or (eq (column-builder-dictionary b) t)
              (and (>= n 16) (< (* 2 distinct) n)))
          (make-dict-column :length n :validity validity :codes codes :dictionary dict)
          (let ((out (progn (ensure-heap-room (* 8 n)) (make-array n :initial-element ""))))
            (dotimes (i n)
              (unless (and validity (zerop (sbit validity i)))
                (setf (svref out i) (svref dict (aref codes i)))))
            (make-string-column :length n :validity validity :values out))))))
