(ns polyquery.catalog
  "The catalog: an immutable value mapping (case-folded) table names to
  tables. Mutations are pure functions returning a new catalog, so callers can
  publish them atomically (e.g. with swap! on an atom) and queries can work on
  a consistent snapshot."
  (:require [polyquery.errors :as err]
            [polyquery.util.text :as text]))

(def empty-catalog {:tables {}})

(defn table-key [name] (text/ascii-lower name))

(defn lookup
  "Returns the table or nil."
  [catalog name]
  (get-in catalog [:tables (table-key name)]))

(defn lookup!
  "Returns the table or throws NOT_FOUND."
  [catalog name]
  (or (lookup catalog name)
      (err/fail! "NOT_FOUND" (str "table '" name "' does not exist") {"table" name})))

(defn add-table
  "Adds a table; with `replace?` an existing table of the same name is
  replaced, otherwise ALREADY_EXISTS is thrown."
  [catalog table replace?]
  (let [k (table-key (:name table))]
    (when (and (not replace?) (contains? (:tables catalog) k))
      (err/fail! "ALREADY_EXISTS" (str "table '" (:name table) "' already exists")
                 {"table" (:name table)}))
    (assoc-in catalog [:tables k] table)))

(defn drop-table
  [catalog name]
  (lookup! catalog name)
  (update catalog :tables dissoc (table-key name)))

(defn tables
  "All tables sorted case-insensitively by name."
  [catalog]
  (sort-by (comp table-key :name) (vals (:tables catalog))))
