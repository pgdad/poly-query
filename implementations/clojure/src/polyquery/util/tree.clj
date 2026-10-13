(ns polyquery.util.tree
  "Tree traversal that stays linear on degenerate trees.

  `clojure.core/tree-seq` nests one lazy `concat` per tree level, so
  realizing it on a left-deep tree (a long chain of binary operators) costs
  O(nodes × depth). `pre-order` walks with an explicit stack instead: linear
  time and no recursion (spec/changes/expression-limits.md)."
  (:import (java.util ArrayList)))

(set! *warn-on-reflection* true)

(defn pre-order
  "Vector of the nodes of the tree rooted at root, in the order of
  (tree-seq branch? children root)."
  [branch? children root]
  (let [stack (ArrayList.)]
    (.add stack root)
    (loop [out (transient [])]
      (let [n (.size stack)]
        (if (zero? n)
          (persistent! out)
          (let [node (.remove stack (unchecked-dec-int n))]
            (when (branch? node)
              (let [cs (vec (children node))]
                (loop [i (dec (count cs))]
                  (when (>= i 0)
                    (.add stack (nth cs i))
                    (recur (dec i))))))
            (recur (conj! out node))))))))
