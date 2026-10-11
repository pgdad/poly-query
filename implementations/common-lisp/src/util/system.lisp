;;;; system.lisp — facts about the host: usable CPUs.

(in-package #:polyquery)

(defun affinity-cpu-count ()
  "Number of CPUs in this process's affinity mask (sched_getaffinity), or NIL."
  (ignore-errors
   (let ((bytes 128))                     ; a cpu_set_t of 1024 CPUs
     (sb-alien:with-alien ((mask (array (sb-alien:unsigned 8) 128)))
       (let ((rc (sb-alien:alien-funcall
                  (sb-alien:extern-alien "sched_getaffinity"
                                         (function sb-alien:int sb-alien:int sb-alien:unsigned-long
                                                   (* (array (sb-alien:unsigned 8) 128))))
                  0 bytes (sb-alien:addr mask))))
         (when (zerop rc)
           (let ((n (loop for i below bytes sum (logcount (sb-alien:deref mask i)))))
             (and (plusp n) n))))))))

(defun online-cpu-count ()
  "Number of online CPUs (sysconf), or NIL."
  (let ((n (ignore-errors
            (sb-alien:alien-funcall
             (sb-alien:extern-alien "sysconf" (function sb-alien:long sb-alien:int))
             84))))                       ; _SC_NPROCESSORS_ONLN on Linux
    (and (integerp n) (plusp n) n)))

(defun cpu-count ()
  "CPUs this process may run on: its affinity mask, else the online CPUs, else 4."
  (or (affinity-cpu-count) (online-cpu-count) 4))

(defparameter *max-default-query-threads* 16
  "Upper bound of the automatic per-query thread count: beyond it the fixed
costs of starting and merging workers outweigh the gains on typical
analytical queries.")

(defun default-query-threads ()
  "Worker threads per query when neither the request nor --threads sets them."
  (max 1 (min (cpu-count) *max-default-query-threads*)))
