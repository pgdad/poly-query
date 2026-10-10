;;;; files.lisp — crash-safe file replacement and read access to PQCF files
;;;; (storage/pqcf-v1.md §4-§5).
;;;;
;;;; WRITE-FILE-ATOMICALLY writes a temporary file `.<name>.tmp-<unique>` in
;;;; the target's directory, fsyncs it, renames it over the target and fsyncs
;;;; the directory, so the target is always absent, the old or the new file.
;;;;
;;;; A FILE-SOURCE gives byte-range access to a file that is either read into
;;;; memory (buffered) or memory-mapped (read-only, private mapping; ranges
;;;; are copied out of the mapping on demand, so chunks are only touched when
;;;; a query needs them).

(in-package #:polyquery)

(defun native-directory-of (native-path)
  (let ((slash (position #\/ native-path :from-end t)))
    (if slash (subseq native-path 0 (1+ slash)) "./")))

(defun native-file-name-of (native-path)
  (let ((slash (position #\/ native-path :from-end t)))
    (if slash (subseq native-path (1+ slash)) native-path)))

(sb-ext:defglobal **temp-counter** (list 0))

(defun temporary-path-for (native-path)
  "`.<target>.tmp-<pid>-<counter>` in the target's directory."
  (format nil "~A.~A.tmp-~D-~D"
          (native-directory-of native-path) (native-file-name-of native-path)
          (sb-posix:getpid) (sb-ext:atomic-incf (car **temp-counter**))))

(defun fsync-directory (directory)
  "Flush the directory entry changes of DIRECTORY (best effort)."
  (handler-case
      (let ((fd (sb-posix:open directory sb-posix:o-rdonly)))
        (unwind-protect (ignore-errors (sb-posix:fsync fd))
          (sb-posix:close fd)))
    (error () nil)))

(defun write-file-atomically (native-path writer)
  "Replace the file at NATIVE-PATH with the octets WRITER (a function of an
octet output stream) produces. Returns WRITER's value. Failures are IO_ERROR."
  (let ((temp (temporary-path-for native-path))
        (done nil))
    (unwind-protect
         (handler-case
             (let ((result
                     (with-open-file (out (sb-ext:parse-native-namestring temp)
                                          :direction :output :element-type '(unsigned-byte 8)
                                          :if-exists :error :if-does-not-exist :create)
                       (prog1 (funcall writer out)
                         (finish-output out)
                         (sb-posix:fsync (sb-sys:fd-stream-fd out))))))
               (sb-posix:rename temp native-path)
               (setf done t)
               (fsync-directory (native-directory-of native-path))
               result)
           ((or file-error stream-error sb-posix:syscall-error) (e)
             (signal-pq-error "IO_ERROR" "cannot write ~A: ~A" (native-file-name-of native-path)
                              (type-of e))))
      (unless done
        (ignore-errors (sb-posix:unlink temp))))))

;;; ------------------------------------------------------------------
;;; Sources

(defstruct file-source
  (size 0 :type fixnum)
  (octets nil)                           ; buffered: the whole file
  (sap nil)                              ; mapped: system area pointer
  (mapped nil))

(defun source-range (source offset length)
  "Returns (values octets start) such that the requested range is
OCTETS[START, START+LENGTH)."
  (declare (type fixnum offset length))
  (if (file-source-mapped source)
      (let ((out (make-octets length)))
        (sb-kernel:copy-ub8-from-system-area (file-source-sap source) offset out 0 length)
        (values out 0))
      (values (file-source-octets source) offset)))

(defun source-copy (source offset length)
  "A fresh octet vector holding the requested range."
  (multiple-value-bind (buf start) (source-range source offset length)
    (if (and (zerop start) (= length (length buf)))
        buf
        (subseq buf start (+ start length)))))

(defun open-file-source (native-path &key mmap)
  "Open the file for reading. Missing files are NOT_FOUND, unreadable ones
IO_ERROR."
  (let ((fd (handler-case (sb-posix:open native-path sb-posix:o-rdonly)
              (sb-posix:syscall-error (e)
                (if (= (sb-posix:syscall-errno e) sb-posix:enoent)
                    (signal-pq-error "NOT_FOUND" "file not found")
                    (signal-pq-error "IO_ERROR" "cannot open file"))))))
    (unwind-protect
         (let* ((stat (sb-posix:fstat fd))
                (size (sb-posix:stat-size stat)))
           (unless (sb-posix:s-isreg (sb-posix:stat-mode stat))
             (signal-pq-error "IO_ERROR" "not a regular file"))
           (if (and mmap (plusp size))
               (let* ((sap (handler-case (sb-posix:mmap nil size sb-posix:prot-read
                                                        sb-posix:map-private fd 0)
                             (sb-posix:syscall-error ()
                               (signal-pq-error "IO_ERROR" "cannot map file"))))
                      (source (make-file-source :size size :sap sap :mapped t)))
                 (sb-ext:finalize source (lambda () (ignore-errors (sb-posix:munmap sap size)))
                                  :dont-save t)
                 source)
               (let ((buf (make-octets size)))
                 (handler-case
                     (loop with pos = 0
                           while (< pos size)
                           do (let ((n (sb-sys:with-pinned-objects (buf)
                                         (sb-unix:unix-read fd (sb-sys:sap+ (sb-sys:vector-sap buf) pos)
                                                            (- size pos)))))
                                (unless (and n (plusp n))
                                  (signal-pq-error "IO_ERROR" "cannot read file"))
                                (incf pos n)))
                   (sb-posix:syscall-error ()
                     (signal-pq-error "IO_ERROR" "cannot read file")))
                 (make-file-source :size size :octets buf))))
      (sb-posix:close fd))))
