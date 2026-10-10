(ns polyquery.catalog
  "The catalog: an immutable value mapping (case-folded) table names to
  tables. Mutations are pure functions returning a new catalog, so callers can
  publish them atomically (e.g. with swap! on an atom) and queries can work on
  a consistent snapshot.

  Indexes are stored in their table (`:indexes`), so dropping or replacing a
  table drops its indexes; index names are nevertheless global (unique across
  all tables, case-insensitively)."
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

(defn index-table
  "The table owning the index named `idx-name`, or nil."
  [catalog idx-name]
  (let [k (text/ascii-lower idx-name)]
    (first (filter (fn [tbl] (some #(= k (text/ascii-lower (:name %))) (:indexes tbl)))
                   (vals (:tables catalog))))))

(defn check-index-names!
  "Throws ALREADY_EXISTS if one of the index names is in use by a table other
  than the one named `replaced` (nil: any table)."
  [catalog idx-names replaced]
  (doseq [nm idx-names]
    (when-let [owner (index-table catalog nm)]
      (when-not (and replaced (= (table-key replaced) (table-key (:name owner))))
        (err/fail! "ALREADY_EXISTS" (str "index '" nm "' already exists"))))))

(defn add-table
  "Adds a table; with `replace?` an existing table of the same name (and its
  indexes) is replaced, otherwise ALREADY_EXISTS is thrown. The new table's
  own index names must not be used by any other table."
  [catalog table replace?]
  (let [k (table-key (:name table))]
    (when (and (not replace?) (contains? (:tables catalog) k))
      (err/fail! "ALREADY_EXISTS" (str "table '" (:name table) "' already exists")
                 {"table" (:name table)}))
    (check-index-names! catalog (map :name (:indexes table)) (when replace? (:name table)))
    (assoc-in catalog [:tables k] table)))

(defn drop-table
  [catalog name]
  (lookup! catalog name)
  (update catalog :tables dissoc (table-key name)))

(defn tables
  "All tables sorted case-insensitively by name."
  [catalog]
  (sort-by (comp table-key :name) (vals (:tables catalog))))

(defn create-index
  "Adds index `idx` (built by polyquery.storage.index) to its table `tname`."
  [catalog tname idx]
  (check-index-names! catalog [(:name idx)] nil)
  (update-in catalog [:tables (table-key tname) :indexes] conj idx))

(defn drop-index
  "Removes the index named idx-name; NOT_FOUND if there is none."
  [catalog idx-name]
  (let [owner (or (index-table catalog idx-name)
                  (err/fail! "NOT_FOUND" (str "index '" idx-name "' does not exist")))
        k (text/ascii-lower idx-name)]
    (update-in catalog [:tables (table-key (:name owner)) :indexes]
               (fn [idxs] (filterv #(not= k (text/ascii-lower (:name %))) idxs)))))

(defn update!
  "Applies the (pure, possibly expensive) catalog function f to the catalog
  atom, retrying if the catalog changed concurrently. Returns the new
  catalog."
  [catalog-atom f]
  (loop []
    (let [old @catalog-atom
          new (f old)]
      (if (compare-and-set! catalog-atom old new)
        new
        (recur)))))
