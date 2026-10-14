;;;; cli.lisp — the command line (pqledger.md §2): global options, commands,
;;;; their options and arguments, and dispatch to the command implementations.

(in-package #:pqledger)

(defparameter *usage* "Usage: pqledger [--config PATH] [--format table|csv|json] COMMAND [ARGS]

Commands:
  init                                  create an empty ledger in data_dir
  import FILE --account NAME            import a bank statement CSV export
  report monthly    [FILTERS]           income, expenses and net per month
  report categories [FILTERS]           spending per category with shares
  report merchants  [FILTERS] [--top N] the merchants with the most spending
  budget --month M [--account NAME]     compare a month's spending with the budgets
  accounts                              transactions, balance and dates per account
  list [FILTERS] [--category C | --uncategorized]
                                        list transactions
  export [FILTERS]                      all columns of the transactions
  set-category ID CATEGORY              override the category of a transaction
  set-category ID --clear               remove the override
  query SQL                             run SQL on the ledger tables
  help                                  show this text
  version                               show the version

Filters: --month YYYY-MM | --from YYYY-MM | --to YYYY-MM, --account NAME

The configuration is --config PATH, else $PQLEDGER_CONFIG, else ./pqledger.conf.
")

;;; ------------------------------------------------------------------
;;; Parsing

(defstruct invocation
  "A parsed command line."
  (config-path nil)
  (format nil)
  (command nil)                         ; e.g. "import", "report monthly"
  (options '())                         ; plist keyword -> parsed value
  (arguments '()))                      ; positional arguments

(defparameter *filter-options* '(("--month" . :month) ("--from" . :month) ("--to" . :month)
                                  ("--account" . :account)))

(defparameter *commands*
  ;; command -> (minimum maximum positional arguments, options as (name . kind))
  `(("init" 0 0)
    ("import" 1 1 ("--account" . :account))
    ("report monthly" 0 0 ,@*filter-options*)
    ("report categories" 0 0 ,@*filter-options*)
    ("report merchants" 0 0 ("--top" . :count) ,@*filter-options*)
    ("budget" 0 0 ("--month" . :month) ("--account" . :account))
    ("accounts" 0 0)
    ("list" 0 0 ("--category" . :category) ("--uncategorized" . :flag) ,@*filter-options*)
    ("export" 0 0 ,@*filter-options*)
    ("set-category" 1 2 ("--clear" . :flag))
    ("query" 1 1)
    ("help" 0 0)
    ("version" 0 0)))

(defun option-p (arg)
  (and (> (length arg) 2) (starts-with-p "--" arg)))

(defun parse-option-value (option kind value)
  "The parsed VALUE of OPTION of KIND; a malformed value is a usage error."
  (or (ecase kind
        (:month (parse-month value))
        (:account (and (account-name-p value) value))
        (:category (and (category-name-p value) value))
        (:count (let ((n (parse-digits value))) (and n (plusp n) n))))
      (usage-error "invalid value ~S for ~A" value option)))

(defun option-keyword (option)
  (intern (string-upcase (subseq option 2)) :keyword))

(defun parse-command-line (args)
  "Parse ARGS into an INVOCATION; signals usage errors."
  (let ((invocation (make-invocation)))
    ;; global options
    (loop while (and args (option-p (first args)))
          do (let ((option (pop args)))
               (flet ((value ()
                        (or (pop args) (usage-error "option ~A requires a value" option))))
                 (cond ((string= option "--help")
                        (when (invocation-command invocation)
                          (usage-error "option --help given twice"))
                        (setf (invocation-command invocation) "help"))
                       ((string= option "--config")
                        (when (invocation-config-path invocation)
                          (usage-error "option --config given twice"))
                        (setf (invocation-config-path invocation) (value)))
                       ((string= option "--format")
                        (when (invocation-format invocation)
                          (usage-error "option --format given twice"))
                        (let ((value (value)))
                          (setf (invocation-format invocation)
                                (or (output-format-keyword value)
                                    (usage-error "invalid output format ~S" value)))))
                       (t (usage-error "unknown option ~A" option))))))
    (if (string= (invocation-command invocation) "help")
        (when args (usage-error "unexpected argument ~A" (first args)))
        (parse-command invocation args))
    invocation))

(defun parse-command (invocation args)
  (let ((name (or (pop args) (usage-error "no command given (see `pqledger help`)"))))
    (when (string= name "report")
      (setf name (concatenate 'string "report "
                              (or (pop args)
                                  (usage-error "report needs a kind: monthly, categories or merchants")))))
    (destructuring-bind (min-args max-args &rest option-specs)
        (or (cdr (assoc name *commands* :test #'string=))
            (usage-error "unknown command ~A" name))
      (setf (invocation-command invocation) name)
      (let ((options '()) (arguments '()))
        (loop while args
              do (let ((arg (pop args)))
                   (if (option-p arg)
                       (let ((spec (assoc arg option-specs :test #'string=))
                             (key (option-keyword arg)))
                         (unless spec
                           (usage-error "unknown option ~A for ~A" arg name))
                         (when (getf options key)
                           (usage-error "option ~A given twice" arg))
                         (setf (getf options key)
                               (if (eq (cdr spec) :flag)
                                   t
                                   (parse-option-value arg (cdr spec)
                                                       (or (pop args)
                                                           (usage-error "option ~A requires a value"
                                                                        arg))))))
                       (push arg arguments))))
        (setf arguments (nreverse arguments))
        (unless (<= min-args (length arguments) max-args)
          (if (< (length arguments) min-args)
              (usage-error "missing argument for ~A" name)
              (usage-error "unexpected argument ~A" (nth max-args arguments))))
        (setf (invocation-options invocation) options
              (invocation-arguments invocation) arguments)
        (check-option-combinations invocation)))))

(defun check-option-combinations (invocation)
  (let ((options (invocation-options invocation))
        (command (invocation-command invocation)))
    (flet ((opt (key) (getf options key)))
      (when (and (opt :month) (or (opt :from) (opt :to)))
        (usage-error "--month cannot be combined with --from or --to"))
      (when (and (opt :from) (opt :to) (month< (opt :to) (opt :from)))
        (usage-error "--from is later than --to"))
      (when (and (opt :category) (opt :uncategorized))
        (usage-error "--category cannot be combined with --uncategorized"))
      (cond ((string= command "import")
             (unless (opt :account) (usage-error "import requires --account NAME")))
            ((string= command "budget")
             (unless (opt :month) (usage-error "budget requires --month YYYY-MM")))
            ((string= command "set-category")
             (let ((arguments (invocation-arguments invocation)))
               (unless (let ((id (parse-digits (first arguments)))) (and id (plusp id)))
                 (usage-error "invalid transaction id ~S" (first arguments)))
               (cond ((and (opt :clear) (rest arguments))
                      (usage-error "give either a category or --clear"))
                     ((opt :clear))
                     ((null (rest arguments))
                      (usage-error "set-category needs a category or --clear"))
                     ((not (category-name-p (second arguments)))
                      (usage-error "invalid category name ~S" (second arguments))))))))))

(defun invocation-filters (invocation)
  (let ((options (invocation-options invocation)))
    (make-filters :month (getf options :month) :from (getf options :from)
                  :to (getf options :to) :account (getf options :account))))

;;; ------------------------------------------------------------------
;;; Dispatch

(defun execute (invocation out)
  "Run the parsed INVOCATION, writing its output to OUT. Returns the exit status."
  (let ((command (invocation-command invocation)))
    (cond
      ((string= command "help") (write-string *usage* out) 0)
      ((string= command "version")
       (format out "pqledger ~A (PolyQuery engine ~A, ~A ~A)~%" *version* polyquery:*engine-version*
               (lisp-implementation-type) (lisp-implementation-version))
       0)
      (t (let ((config (load-config (invocation-config-path invocation))))
           (execute-with-config invocation config
                                (or (invocation-format invocation) (config-format config))
                                out))))))

(defun execute-with-config (invocation config format out)
  (let* ((command (invocation-command invocation))
         (options (invocation-options invocation))
         (arguments (invocation-arguments invocation))
         (filters (invocation-filters invocation)))
    (when (string= command "init")
      (init-ledger config)
      (write-line "initialized ledger" out)
      (return-from execute-with-config 0))
    (let ((rules (load-rules config))
          (budgets (and (member command '("budget" "query") :test #'string=)
                        (load-budgets config :required (string= command "budget"))))
          (status 0))
      (unless (ledger-exists-p config)
        (ledger-error "no ledger in ~A (run `pqledger init` first)" (config-data-dir config)))
      (flet ((show (report) (write-report report format out)))
        (cond
          ((string= command "import")
           (let* ((file (first arguments))
                  (account (getf options :account))
                  (entries (read-statement (absolute-path file (current-directory)) file
                                           (account-settings config account))))
             (with-ledger (ledger config)
               (multiple-value-bind (batch imported duplicates)
                   (import-entries ledger account (base-name file) entries)
                 (format out "batch ~D: imported ~D, duplicates ~D~%" batch imported duplicates)))))
          ((string= command "set-category")
           (let ((id (parse-integer (first arguments)))
                 (category (second arguments)))
             (with-ledger (ledger config)
               (set-override ledger id category))
             (if category
                 (format out "transaction ~D: category ~A~%" id category)
                 (format out "transaction ~D: category cleared~%" id))))
          (t
           (with-ledger (ledger config)
             (install-rules ledger rules)
             (cond
               ((string= command "report monthly") (show (monthly-report ledger filters)))
               ((string= command "report categories") (show (categories-report ledger filters)))
               ((string= command "report merchants")
                (show (merchants-report ledger filters (or (getf options :top) 10))))
               ((string= command "budget")
                (install-budgets ledger budgets)
                (multiple-value-bind (report over) (budget-report ledger filters)
                  (show report)
                  (when over (setf status 3))))
               ((string= command "accounts") (show (accounts-report ledger)))
               ((string= command "list")
                (show (list-report ledger filters (if (getf options :uncategorized)
                                                      "uncategorized"
                                                      (getf options :category)))))
               ((string= command "export") (show (export-report ledger filters)))
               ((string= command "query")
                (show (query-report ledger (first arguments) budgets))))))))
      status)))
