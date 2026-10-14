;;;; memory.lisp — the process-wide heap guard.
;;;;
;;;; SBCL's heap (dynamic space) has a fixed size chosen at build time. When an
;;;; allocation cannot be satisfied SBCL signals HEAP-EXHAUSTED-ERROR, but when
;;;; the garbage collector itself runs out of space the process dies ("Heap
;;;; exhausted, game over"). The guard keeps the heap well below that point:
;;;; long-running work (loads, query loops, materialization) calls CHECK-HEAP,
;;;; which compares the bytes in use with a soft limit. Above the limit the
;;;; heap is first collected in full (garbage of dropped tables and failed
;;;; requests lives in old generations); if the live data still exceeds the
;;;; limit the current request fails with RESOURCE_LIMIT and its data becomes
;;;; garbage, so the engine keeps serving.
;;;;
;;;; The soft limit is a fraction of the dynamic space (leaving room for the
;;;; collector to copy survivors) and of the physical memory (or cgroup limit)
;;;; of the host, whichever is smaller; --max-memory-mb lowers it further.

(in-package #:polyquery)

(defparameter *heap-reserve-fraction* 0.15
  "Fraction of the dynamic space kept free for the garbage collector.")

(defparameter *min-heap-reserve* (* 2 1024 1024 1024)
  "Minimum bytes of the dynamic space kept free for the garbage collector.")

(defparameter *physical-memory-fraction* 0.8
  "Fraction of the host's (or cgroup's) memory the heap may use.")

(defvar *heap-limit* nil
  "Soft limit on the bytes in use in the heap, or NIL (computed on first use).")

(defvar *heap-reclaim-lock* (sb-thread:make-mutex :name "heap reclaim"))

(defvar *consed-at-last-reclaim* 0
  "Value of GET-BYTES-CONSED after the last full collection by the guard.")

(defparameter *reclaim-min-consed* (* 256 1024 1024)
  "A full collection is only worth trying again after this many bytes were
allocated since the previous one; otherwise the guard fails immediately
(repeated full collections of a nearly full heap would only thrash).")

(defun read-first-integer-from-file (path &key (prefix nil) (multiplier 1))
  "The first integer in the file PATH (on the line starting with PREFIX, if
given) times MULTIPLIER, or NIL."
  (ignore-errors
   (with-open-file (in path :if-does-not-exist nil)
     (when in
       (loop for line = (read-line in nil)
             while line
             when (or (null prefix)
                      (and (>= (length line) (length prefix))
                           (string= prefix line :end2 (length prefix))))
               do (let* ((start (position-if #'digit-char-p line))
                         (n (and start (parse-integer line :start start :junk-allowed t))))
                    (return (and n (* n multiplier)))))))))

(defun physical-memory-bytes ()
  "Memory available to this process: the smaller of the host's physical
memory and a cgroup memory limit, or NIL when unknown."
  (let ((total (read-first-integer-from-file "/proc/meminfo" :prefix "MemTotal:" :multiplier 1024))
        (cgroup (or (read-first-integer-from-file "/sys/fs/cgroup/memory.max")
                    (read-first-integer-from-file "/sys/fs/cgroup/memory/memory.limit_in_bytes"))))
    (let ((limits (remove-if-not (lambda (n) (and n (plusp n) (< n (expt 2 60))))
                                 (list total cgroup))))
      (and limits (reduce #'min limits)))))

(defun default-heap-limit ()
  "The soft heap limit derived from the dynamic space and the host memory."
  (let* ((space (sb-ext:dynamic-space-size))
         (reserve (max *min-heap-reserve* (floor (* space *heap-reserve-fraction*))))
         (by-space (max (floor space 2) (- space reserve)))
         (physical (physical-memory-bytes)))
    (if physical
        (min by-space (floor (* physical *physical-memory-fraction*)))
        by-space)))

(defun configure-heap-limit (&optional max-memory-mb)
  "Set the soft heap limit: the default, lowered to MAX-MEMORY-MB if given."
  (setf *heap-limit*
        (let ((default (default-heap-limit)))
          (if (and max-memory-mb (plusp max-memory-mb))
              (min default (* max-memory-mb 1024 1024))
              default))))

(declaim (inline heap-limit))
(defun heap-limit ()
  (or *heap-limit* (configure-heap-limit)))

(defun heap-bytes-in-use ()
  (sb-kernel:dynamic-usage))

(defun reclaim-heap ()
  "Collect the whole heap unless another thread just did. Returns true when
the bytes in use are below the soft limit afterwards."
  (sb-thread:with-mutex (*heap-reclaim-lock*)
    (or (<= (heap-bytes-in-use) (heap-limit))
        (when (> (- (sb-ext:get-bytes-consed) *consed-at-last-reclaim*) *reclaim-min-consed*)
          (sb-ext:gc :full t)
          (setf *consed-at-last-reclaim* (sb-ext:get-bytes-consed))
          (<= (heap-bytes-in-use) (heap-limit))))))

(defun note-memory-failure ()
  "A request failed for lack of memory: its data is about to become garbage,
so the next check above the limit collects the heap again."
  (setf *consed-at-last-reclaim* 0))

(defun heap-limit-error ()
  (note-memory-failure)
  (resource-limit-error "out of memory: the engine's heap limit (~D MB) is exhausted"
                        (floor (heap-limit) (* 1024 1024))))

(declaim (inline check-heap))
(defun check-heap ()
  "Signal RESOURCE_LIMIT when the heap is (still, after a full collection)
above the soft limit. Cheap enough to call every few thousand rows."
  (when (> (heap-bytes-in-use) (heap-limit))
    (unless (reclaim-heap)
      (heap-limit-error))))

(defun ensure-heap-room (bytes)
  "Signal RESOURCE_LIMIT unless BYTES more can be allocated within the soft
limit (used before large allocations whose size is known)."
  (when (> (+ (heap-bytes-in-use) bytes) (heap-limit))
    (sb-thread:with-mutex (*heap-reclaim-lock*)
      (when (> (- (sb-ext:get-bytes-consed) *consed-at-last-reclaim*) *reclaim-min-consed*)
        (sb-ext:gc :full t)
        (setf *consed-at-last-reclaim* (sb-ext:get-bytes-consed))))
    (when (> (+ (heap-bytes-in-use) bytes) (heap-limit))
      (heap-limit-error))))
