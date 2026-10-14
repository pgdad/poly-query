;;;; test-ledger.lisp — duplicates, shares and a ledger round trip through the engine.

(in-package #:pqledger-tests)

(deftest share.rounding
    (list (pqledger::share-tenths 39701/100 40001/100) (pqledger::share-tenths 3 40001/100)
          (pqledger::share-tenths 1 8) (pqledger::share-tenths 1 1))
  (993 7 125 1000))

(defun entry (date cents merchant)
  (pqledger::make-entry 0 date cents merchant merchant))

(deftest duplicates.selection
    (let ((existing (make-hash-table :test 'equal)))
      (setf (gethash (list 1 -450 "X") existing) 1)
      (multiple-value-bind (fresh duplicates)
          (pqledger::select-new-entries (list (entry 1 -450 "X") (entry 1 -450 "X") (entry 2 -450 "X")
                                              (entry 1 -450 "Y"))
                                        existing)
        (list (mapcar (lambda (e) (list (pqledger::entry-date e) (pqledger::entry-merchant e))) fresh)
              duplicates)))
  (((1 "X") (2 "X") (1 "Y")) 1))

(defun test-config (dir)
  (pqledger::parse-config (format nil "[ledger]~%data_dir = ledger~%rules_file = rules.conf~%")
                          (format nil "~Apqledger.conf" dir)))

(deftest ledger.round-trip
    (let* ((dir (temporary-directory))
           (config (test-config dir)))
      (write-file (format nil "~Arules.conf" dir) (format nil "food = BAKERY*, CAF?~%"))
      (pqledger::init-ledger config)
      (let ((init-again (status-of (pqledger::init-ledger config)))
            (entries (list (pqledger::make-entry 2 (pq:make-date 2026 1 5) -450 "Bakery 1" "BAKERY 1")
                           (pqledger::make-entry 3 (pq:make-date 2026 1 6) 10000 "Pay" "PAY")
                           (pqledger::make-entry 4 (pq:make-date 2026 2 1) -300 "Cafe" "CAFE"))))
        (list init-again
              (pqledger::with-ledger (ledger config)
                (multiple-value-list (pqledger::import-entries ledger "giro" "a.csv" entries)))
              (pqledger::with-ledger (ledger config)
                (multiple-value-list (pqledger::import-entries ledger "giro" "b.csv" (rest entries))))
              (pqledger::with-ledger (ledger config)
                (pqledger::set-override ledger 2 "salary")
                (status-of (pqledger::set-override ledger 9 "x")))
              (pqledger::with-ledger (ledger config)
                (pqledger::install-rules ledger (pqledger::load-rules config))
                (map 'list (lambda (row) (coerce row 'list))
                     (pqledger::report-rows
                      (pqledger::list-report ledger (pqledger::make-filters) nil))))
              (pqledger::with-ledger (ledger config)
                (pqledger::install-rules ledger (pqledger::load-rules config))
                (map 'list (lambda (row) (coerce row 'list))
                     (pqledger::report-rows
                      (pqledger::categories-report ledger (pqledger::make-filters
                                                           :month '(2026 . 1)))))))))
  (6 (1 3 0) (2 0 2) 6
   ((1 20458 "giro" "Bakery 1" -9/2 "food")
    (2 20459 "giro" "Pay" 100 "salary")
    (3 20485 "giro" "Cafe" -3 "food"))
   (("food" 9/2 100 1))))
