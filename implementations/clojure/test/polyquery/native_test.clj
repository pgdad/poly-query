(ns polyquery.native-test
  "Native kernel integration (spec/phases/native-kernels.md): the bitmap
  helpers, the FFM binding against the Java implementations, and
  differential tests — every query of the Phase 5 matrix plus integer
  overflow cases must give exactly the same result (or error) with
  `native: true` as without.

  The library is looked up in $PQ_NATIVE_KERNELS, else in
  ../../native-kernels/build/<arch>/libpqkernels.so; when it is not built,
  the tests that need it are skipped (the engine does not require it)."
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.test :refer [deftest is testing use-fixtures]]
            [polyquery.catalog :as catalog]
            [polyquery.engine :as engine]
            [polyquery.engine-phase5-test :as p5]
            [polyquery.exec.batch :as b]
            [polyquery.exec.grouping :as g]
            [polyquery.ingest.csv :as csv]
            [polyquery.native.bits :as bits]
            [polyquery.native.ffi :as ffi]
            [polyquery.storage.table :as table]
            [polyquery.types :as t])
  (:import (java.io StringReader)
           (java.util Random)))

(defn- library-path []
  (let [arch (case (System/getProperty "os.arch") ("amd64" "x86_64") "x86_64" ("aarch64" "arm64") "aarch64" "other")
        candidates [(System/getenv "PQ_NATIVE_KERNELS")
                    (str "../../native-kernels/build/" arch "/libpqkernels.so")]]
    (first (filter #(and % (.isFile (io/file %))) candidates))))

(def ^:private lib
  (delay (when-let [p (library-path)] (ffi/load! p))))

(use-fixtures :once (fn [f]
                      (when-not @lib
                        (println "native-test: libpqkernels not built; native tests skipped"))
                      (f)))

(defmacro ^:private with-library [& body]
  `(when-let [~'lib @lib] ~@body))

;; ---------------------------------------------------------------------------
;; Bitmap helpers (no library needed)

(deftest bitmap-helpers
  (let [nulls (boolean-array b/capacity)
        out (bits/bitmap)]
    (aset nulls 2 true)
    (aset nulls 70 true)
    (bits/valid-bits! nulls 100 out)
    (is (= (remove #{2 70} (range 100))
           (let [[sel n] (bits/bitmap->sel out 100 false)] (take n (seq sel)))))
    (testing "identity selection when every position is set"
      (is (identical? b/identity-sel (first (bits/bitmap->sel (bits/fill! (bits/bitmap) 64 true) 64 true)))))
    (testing "selection bitmaps and spans"
      (let [sel (int-array [1 5 63 64 1023])]
        (is (= 1024 (bits/span sel 5)))
        (is (= 6 (bits/span sel 2)))
        (is (= [1 5 63 64 1023] (let [[s n] (bits/bitmap->sel (bits/sel-bits! sel 5 (bits/bitmap)) 1024 false)]
                                  (take n (seq s)))))
        (is (= [1 63 1023] (let [nl (boolean-array b/capacity)]
                             (aset nl 5 true) (aset nl 64 true)
                             (let [[s n] (bits/bitmap->sel (bits/valid-sel-bits! nl sel 5 (bits/bitmap))
                                                           1024 false)]
                               (take n (seq s))))))
        (is (nil? (bits/valid-sel-bits! nil b/identity-sel 10 (bits/bitmap))))))
    (testing "bit 63 (a negative word)"
      (let [bm (bits/bitmap)]
        (aset bm 0 Long/MIN_VALUE)
        (is (= [63] (let [[s n] (bits/bitmap->sel bm 64 false)] (take n (seq s)))))))))

;; ---------------------------------------------------------------------------
;; The binding against Java implementations

(deftest kernels-match-java
  (with-library
    (let [rnd (Random. 7)
          n 1000
          data (long-array (repeatedly n #(- (.nextInt rnd 200) 100)))
          nulls (boolean-array (repeatedly n #(< (.nextInt rnd 10) 2)))
          valid (bits/valid-bits! (java.util.Arrays/copyOf nulls b/capacity) n (bits/bitmap))
          java-sel (fn [pred] (filterv #(and (not (aget nulls %)) (pred (aget data %))) (range n)))]
      (is (= ffi/abi-version 1))
      (testing "filter_i64 / filter_i64_bitmap / count_i64"
        (doseq [[op pred] [[ffi/EQ #(= % 7)] [ffi/NE #(not= % 7)] [ffi/LT #(< % 7)] [ffi/LE #(<= % 7)]
                           [ffi/GT #(> % 7)] [ffi/GE #(>= % 7)] [ffi/BETWEEN #(<= -20 % 7)]]]
          (let [a (if (= op ffi/BETWEEN) -20 7)
                c (if (= op ffi/BETWEEN) 7 0)
                out (int-array n)
                cnt (ffi/filter-i64 lib data valid n op a c out)
                bm (bits/bitmap)
                bcnt (ffi/filter-i64-bitmap lib data valid n op a c bm)]
            (is (= (java-sel pred) (vec (take cnt out))))
            (is (= cnt bcnt (ffi/count-i64 lib data valid n op a c)))
            (is (= (java-sel pred) (let [[s m] (bits/bitmap->sel bm n false)] (vec (take m s))))))))
      (testing "hash_i64 is fmix64"
        (let [out (long-array n)]
          (ffi/hash-i64! lib data n 0 out)
          (is (every? #(= (aget out %) (g/fmix64 (aget data %))) (range n)))))
      (testing "sum_i64 is exact and reports overflow of the final sum"
        (let [out (long-array 1)
              big (long-array [Long/MAX_VALUE Long/MAX_VALUE (- Long/MAX_VALUE) (- Long/MAX_VALUE) 5])]
          (is (= ffi/OK (ffi/sum-i64 lib big nil 5 out)))
          (is (= 5 (aget out 0)))
          (is (= ffi/OVERFLOW (ffi/sum-i64 lib big nil 2 out)))))
      (testing "group_sum_i64 wraps, counts and flags overflow"
        (let [sums (long-array 2) counts (long-array 2)
              gids (int-array [0 1 0 1])
              vals (long-array [Long/MAX_VALUE 1 1 2])]
          (is (= ffi/OVERFLOW (ffi/group-sum-i64 lib gids vals nil 4 sums counts 2)))
          (is (= [Long/MIN_VALUE 3] (vec sums)))
          (is (= [2 2] (vec counts)))
          (is (= ffi/EINVAL (ffi/group-sum-i64 lib gids vals nil 4 sums counts 1)))))
      (testing "minmax, gather, bitmap operations, compare_i64"
        (let [mm (long-array 2)]
          (is (= (count (remove #(aget nulls %) (range n))) (ffi/minmax-i64 lib data valid n mm)))
          (is (= [(apply min (keep #(when-not (aget nulls %) (aget data %)) (range n)))
                  (apply max (keep #(when-not (aget nulls %) (aget data %)) (range n)))]
                 (vec mm))))
        (let [out (long-array 3)]
          (ffi/gather-i64! lib data (int-array [5 0 999]) 3 out)
          (is (= [(aget data 5) (aget data 0) (aget data 999)] (vec out))))
        (let [x (long-array [0x0F 0]) y (long-array [0x3C -1]) out (long-array 2)]
          (ffi/bitmap-and! lib x y out 2)
          (is (= [0x0C 0] (vec out)))
          (ffi/bitmap-or! lib x y out 2)
          (is (= [0x3F -1] (vec out)))
          (ffi/bitmap-andnot! lib x y out 2)
          (is (= [0x03 0] (vec out)))
          (is (= 6 (ffi/popcount lib (long-array [0x3F -1]) 6))))
        (let [out (bits/bitmap)
              cnt (ffi/compare-i64 lib (long-array [1 2 3]) (long-array [3 2 1]) 3 ffi/LT out)]
          (is (= 1 cnt))
          (is (= 1 (aget out 0))))))))

;; ---------------------------------------------------------------------------
;; Identical results with and without the library

(def ^:private native-configs
  [{:mode "vectorized" :threads 1 :native true}
   {:mode "vectorized" :threads 4 :join "hash" :native true}
   {:mode "auto" :optimize false :native true}
   {:mode "row" :native true}])

(defn- strict-run
  "Runs a query without the row-mode re-execution after unexpected
  exceptions (which would hide defects of the native paths)."
  [cat sql opts]
  (with-redefs [polyquery.engine/strict? true]
    (#'p5/run cat sql opts)))

(deftest phase5-queries-identical-with-native-kernels
  (with-library
    (let [cat @p5/the-catalog]
      (doseq [[sql ordered?] p5/queries]
        (let [expected (#'p5/comparable (strict-run cat sql p5/reference) ordered?)]
          (testing sql
            (doseq [c native-configs]
              (testing (pr-str c)
                (is (= expected (#'p5/comparable (strict-run cat sql c) ordered?)))))))))))

(defn- overflow-catalog
  "Tables whose integer sums wrap in int64 part-way (int64 v) and whose
  final sums overflow (w), with NULLs, over several batches."
  []
  (let [rnd (Random. 3)
        big 4611686018427387904 ; 2^62
        rows (for [i (range 5000)]
               [i (mod i 7)
                (if (zero? (mod i 11)) "" (str (if (even? (quot i 2)) big (- big))))
                (if (zero? (mod i 13)) "" (str (+ big (.nextInt rnd 1000))))
                (str (- (.nextInt rnd 2000000) 1000000) "." (format "%02d" (.nextInt rnd 100)))
                (format "2024-%02d-%02d" (inc (.nextInt rnd 12)) (inc (.nextInt rnd 28)))])
        text (str "id,g,v,w,d,dt\n" (str/join (map #(str (str/join "," %) "\n") rows)))]
    (atom (catalog/add-table
           catalog/empty-catalog
           (csv/load-csv (StringReader. text)
                         {:name "o" :header? true :delimiter \,
                          :schema (mapv (fn [[n ty]] (table/->Column n ty))
                                        [["id" :int64] ["g" :int64] ["v" :int64] ["w" :int64]
                                         ["d" (t/decimal 18 2)] ["dt" :date]])
                          :limits {:max-table-rows 100000}})
           false))))

(deftest overflow-flags-are-honoured
  (with-library
    (let [cat (overflow-catalog)
          queries ["SELECT SUM(v), COUNT(v), AVG(v) FROM o"
                   "SELECT g, SUM(v), COUNT(v), AVG(v) FROM o GROUP BY g"
                   "SELECT g, SUM(v) FROM o WHERE id % 3 = 0 GROUP BY g"
                   "SELECT SUM(w) FROM o"
                   "SELECT SUM(w) FROM o WHERE id < 2"
                   "SELECT g, SUM(w) FROM o GROUP BY g"
                   "SELECT g, AVG(w), MIN(w), MAX(w) FROM o GROUP BY g"
                   "SELECT MIN(v), MAX(v), MIN(d), MAX(d), MIN(dt), MAX(dt), SUM(d) FROM o WHERE w > 4611686018427388000"
                   "SELECT dt, SUM(d), COUNT(*) FROM o WHERE d BETWEEN -500000 AND 500000.5 GROUP BY dt"
                   "SELECT id FROM o WHERE v > w OR id IN (1, 2, 3) OR NOT (g <> 3)"
                   "SELECT id FROM o WHERE v IS NULL AND NOT (w IS NOT NULL)"
                   "SELECT id FROM o WHERE dt NOT BETWEEN DATE '2024-02-01' AND DATE '2024-11-30' AND g NOT IN (1, 2)"
                   "SELECT id FROM o WHERE g NOT IN (1, NULL)"
                   "SELECT a.id, b.g FROM o a JOIN o b ON b.id = a.g WHERE a.v > 0"]]
      (doseq [sql queries]
        (let [expected (strict-run cat sql p5/reference)]
          (testing sql
            (doseq [c native-configs]
              (testing (pr-str c)
                (is (= (#'p5/comparable expected false)
                       (#'p5/comparable (strict-run cat sql c) false)))))))))))

(deftest native-option-without-library
  (let [cat @p5/the-catalog
        loaded (ffi/library)]
    (try
      (ffi/unload!)
      (is (= (#'p5/comparable (#'p5/run cat "SELECT g, SUM(k) FROM t WHERE k > 100 GROUP BY g" p5/reference) false)
             (#'p5/comparable (#'p5/run cat "SELECT g, SUM(k) FROM t WHERE k > 100 GROUP BY g" {:native true}) false)))
      (finally (when loaded (ffi/load! (.-path ^polyquery.native.ffi.Library loaded)))))))

(deftest unusable-library-is-ignored
  (let [loaded (ffi/library)]
    (try
      (is (nil? (ffi/load! "/nonexistent/libpqkernels.so")))
      (is (nil? (ffi/library)))
      (finally (when loaded (ffi/load! (.-path ^polyquery.native.ffi.Library loaded)))))))
