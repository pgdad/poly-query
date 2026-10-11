;;;; system.lisp — facts about the host system.

(in-package #:polyquery)

(defun affinity-cpu-count ()
  "Number of CPUs in this process's affinity mask (sched_getaffinity), or NIL."
  (ignore-errors
   (sb-alien:with-alien ((mask (array (sb-alien:unsigned 64) 16)))
     (let ((rc (sb-alien:alien-funcall
                (sb-alien:extern-alien "sched_getaffinity"
                                       (function sb-alien:int sb-alien:int sb-alien:unsigned-long
                                                 (* (array (sb-alien:unsigned 64) 16))))
                0 (* 8 16) (sb-alien:addr mask))))
       (when (zerop rc)
         (let ((n (loop for i below 16 sum (logcount (sb-alien:deref mask i)))))
           (and (plusp n) n)))))))

(defun online-cpu-count ()
  "Number of online CPUs (sysconf), or NIL."
  (let ((n (ignore-errors
            (sb-alien:alien-funcall
             (sb-alien:extern-alien "sysconf" (function sb-alien:long sb-alien:int))
             84))))                       ; _SC_NPROCESSORS_ONLN on Linux
    (and (integerp n) (plusp n) n)))

(defun cpu-count ()
  "Number of CPUs this process can use (4 when unknown)."
  (or (affinity-cpu-count) (online-cpu-count) 4))
