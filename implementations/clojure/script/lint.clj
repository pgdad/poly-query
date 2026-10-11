;; Lint build (invoked by `make lint`): compiles every namespace into
;; target/lint-classes with *warn-on-reflection* and *unchecked-math*
;; :warn-on-boxed, and fails on any reflection, boxed-math or performance
;; (e.g. non-primitive `case` test) warning. Only the lint classes use
;; unchecked math; the release build (script/compile.clj) keeps checked math.
(require '[clojure.string :as str])

(def warnings
  (let [err (java.io.StringWriter.)]
    (binding [*compile-path* "target/lint-classes"
              *warn-on-reflection* true
              *unchecked-math* :warn-on-boxed
              *err* (java.io.PrintWriter. err true)]
      (compile 'polyquery.main))
    (->> (str/split-lines (str err))
         (filter #(or (str/includes? % "Reflection warning")
                      (str/includes? % "Boxed math warning")
                      (str/includes? % "Performance warning")))
         distinct)))

(doseq [w warnings] (println w))
(if (seq warnings)
  (do (println (count warnings) "lint warnings (reflection, boxed math or performance)")
      (System/exit 1))
  (println "lint: no reflection, boxed-math or performance warnings"))
