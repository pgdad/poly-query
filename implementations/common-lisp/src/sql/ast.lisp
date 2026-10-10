;;;; ast.lisp — abstract syntax tree produced by the parser.
;;;;
;;;; Nodes are plain structures; every node records the source position of
;;;; its first token so later stages can report errors with line/column.

(in-package #:polyquery)

(defstruct (ast-node (:constructor nil))
  (line 0 :type fixnum)
  (column 0 :type fixnum))

;;; ------------------------------------------------------------------
;;; Expressions

(defstruct (ast-literal (:include ast-node))
  "KIND is :INTEGER, :NUMBER, :STRING, :BOOLEAN, :NULL, :DATE or :TIMESTAMP.
VALUE is the literal text (or T/NIL for booleans)."
  kind value)

(defstruct (ast-column-ref (:include ast-node))
  qualifier                             ; NIL or range variable name
  name)

(defstruct (ast-star (:include ast-node))
  "`*` or `qualifier.*` in a select list."
  qualifier)

(defstruct (ast-unary (:include ast-node))
  op operand)                           ; op is :NEG or :POS

(defstruct (ast-binary (:include ast-node))
  op left right)                        ; arithmetic, :CONCAT, comparisons, :AND, :OR

(defstruct (ast-not (:include ast-node))
  operand)

(defstruct (ast-is-null (:include ast-node))
  operand negated)

(defstruct (ast-between (:include ast-node))
  operand low high negated)

(defstruct (ast-in-list (:include ast-node))
  operand items negated)

(defstruct (ast-in-subquery (:include ast-node))
  operand query negated)

(defstruct (ast-like (:include ast-node))
  operand pattern negated)

(defstruct (ast-function (:include ast-node))
  name args distinct star)

(defstruct (ast-cast (:include ast-node))
  operand type-name type-params)

(defstruct (ast-case (:include ast-node))
  operand whens else)                   ; whens: list of (condition . result)

(defstruct (ast-exists (:include ast-node))
  query)

(defstruct (ast-subquery (:include ast-node))
  query)

;;; ------------------------------------------------------------------
;;; Queries

(defstruct (ast-query (:include ast-node))
  ctes                                  ; list of AST-CTE
  body                                  ; AST-SELECT
  order-by                              ; list of AST-ORDER-ITEM
  limit offset)

(defstruct (ast-cte (:include ast-node))
  name columns query)

(defstruct (ast-select (:include ast-node))
  distinct items from where group-by having)

(defstruct (ast-select-item (:include ast-node))
  expr alias)

(defstruct (ast-table-ref (:include ast-node))
  name alias)

(defstruct (ast-derived-table (:include ast-node))
  query alias)

(defstruct (ast-join (:include ast-node))
  kind left right condition)            ; kind: :INNER :LEFT :CROSS

(defstruct (ast-order-item (:include ast-node))
  expr descending nulls)                ; nulls: NIL, :FIRST or :LAST

;;; ------------------------------------------------------------------
;;; Statements

(defstruct (ast-explain (:include ast-node))
  query)

(defstruct (ast-create-index (:include ast-node))
  name table index-column kind if-not-exists)

(defstruct (ast-drop-index (:include ast-node))
  name if-exists)
