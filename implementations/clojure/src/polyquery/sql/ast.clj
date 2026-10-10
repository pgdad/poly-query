(ns polyquery.sql.ast
  "Shapes of the parser's AST and helpers to inspect it.

  Expressions ({:node … :pos {:line :col}}):
    :literal   {:kind :number|:string|:bool|:null|:date|:timestamp, :text|:value}
    :column    {:table (nil|name) :name}
    :unary     {:op \"-\"|\"+\" :arg}
    :binary    {:op \"+\" \"-\" \"*\" \"/\" \"%\" \"||\" \"=\" \"<>\" \"<\" \"<=\" \">\" \">=\" \"AND\" \"OR\"
                :left :right}
    :not       {:arg}
    :is-null   {:not? :arg}
    :between   {:not? :arg :low :high}
    :in-list   {:not? :arg :items}
    :in-query  {:not? :arg :query}
    :like      {:not? :arg :pattern}
    :func      {:name :args :distinct? :star?}
    :cast      {:arg :type-name {:name :params}}
    :case      {:operand :whens [[cond result] …] :else}
    :exists    {:query}
    :subquery  {:query}

  Query: {:node :query :with [cte…] :select core :order-by [{:expr :desc? :nulls}]
          :limit :offset}
  Select core: {:distinct? :items [{:kind :star :table} | {:kind :expr :expr :alias}]
                :from :where :group-by :having}
  From items: {:node :table :name :alias} | {:node :derived :query :alias}
              | {:node :join :kind :inner|:left|:cross :left :right :on}
  Statements: {:node :select :query} | {:node :explain :query}
              | {:node :create-index …} | {:node :drop-index …}"
  (:require [polyquery.util.text :as text]))

(def aggregate-functions #{"COUNT" "SUM" "AVG" "MIN" "MAX"})

(defn aggregate-call?
  [e]
  (and (= :func (:node e))
       (contains? aggregate-functions (text/ascii-upper (:name e)))))

(defn children
  "Direct sub-expressions of an expression (not descending into subqueries)."
  [e]
  (case (:node e)
    (:unary :not :is-null :cast) [(:arg e)]
    :binary [(:left e) (:right e)]
    :between [(:arg e) (:low e) (:high e)]
    :in-list (cons (:arg e) (:items e))
    :in-query [(:arg e)]
    :like [(:arg e) (:pattern e)]
    :func (:args e)
    :case (concat (when (:operand e) [(:operand e)])
                  (mapcat identity (:whens e))
                  (when (:else e) [(:else e)]))
    []))

(defn contains-aggregate?
  [e]
  (boolean (or (aggregate-call? e) (some contains-aggregate? (children e)))))
