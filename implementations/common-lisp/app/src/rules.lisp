;;;; rules.lisp — the category rules file and the budget file (pqledger.md §5).

(in-package #:pqledger)

(defstruct (rule (:constructor make-rule (number category pattern)))
  "One pattern of the rules file: its NUMBER (1, 2, ... in file order), the
CATEGORY it assigns and the PATTERN as written, upper-cased."
  number category pattern)

(defun parse-rules (text file)
  "The list of RULEs in the rules file TEXT (read from FILE)."
  (let ((rules '()) (number 0))
    (map-ini-lines
     (lambda (line kind category value)
       (declare (ignore kind))
       (unless (category-name-p category)
         (config-error "~A:~D: invalid category name ~S" file line category))
       (dolist (part (split-on-comma value))
         (let ((pattern (trim-blanks part)))
           (when (zerop (length pattern))
             (config-error "~A:~D: empty pattern" file line))
           (when (find-if (lambda (c) (member c '(#\% #\_))) pattern)
             (config-error "~A:~D: pattern ~S contains % or _" file line pattern))
           (push (make-rule (incf number) category (ascii-upcase pattern)) rules))))
     text file)
    (nreverse rules)))

(defun split-on-comma (s)
  (loop with start = 0
        for pos = (position #\, s :start start)
        collect (subseq s start pos)
        while pos
        do (setf start (1+ pos))))

(defun parse-budget-amount (text)
  "The amount in cents of a budget AMOUNT ([0-9]+(\\.[0-9]{1,2})?, at most 16
integer digits), or NIL."
  (let* ((dot (position #\. text))
         (int-end (or dot (length text))))
    (when (and (digits-p text :end int-end)
               (<= int-end 16)
               (or (null dot)
                   (and (<= 1 (- (length text) dot 1) 2) (digits-p text :start (1+ dot)))))
      (let ((fraction (if dot (subseq text (1+ dot)) "")))
        (+ (* 100 (parse-integer text :end int-end))
           (if (zerop (length fraction))
               0
               (* (parse-integer fraction) (if (= (length fraction) 1) 10 1))))))))

(defun parse-budgets (text file)
  "The budgets of the budget file TEXT as an alist (category . cents), in file order."
  (let ((budgets '()))
    (map-ini-lines
     (lambda (line kind category value)
       (declare (ignore kind))
       (unless (category-name-p category)
         (config-error "~A:~D: invalid category name ~S" file line category))
       (when (assoc category budgets :test #'string=)
         (config-error "~A:~D: category ~A is listed twice" file line category))
       (push (cons category (or (parse-budget-amount value)
                                (config-error "~A:~D: invalid amount ~S" file line value)))
             budgets))
     text file)
    (nreverse budgets)))

(defun load-rules (config)
  "The rules of CONFIG's rules file (none if it has none)."
  (let ((file (config-rules-file config)))
    (and file (parse-rules (read-text-file-or-fail file "rules file" #'config-error) file))))

(defun load-budgets (config &key required)
  "The budgets of CONFIG's budget file; if REQUIRED, a missing budget_file
setting is a configuration error."
  (let ((file (config-budget-file config)))
    (cond (file (parse-budgets (read-text-file-or-fail file "budget file" #'config-error) file))
          (required (config-error "no budget_file is configured in ~A" (config-path config)))
          (t '()))))
