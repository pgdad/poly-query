(ns polyquery.storage.pqcf-test
  "PQCF v1 writing and reading: round trips for every encoding, memory
  mapping, validation of corrupt and unsupported files."
  (:require [clojure.test :refer [deftest is testing]]
            [polyquery.storage.pqcf :as pqcf]
            [polyquery.storage.table :as table]
            [polyquery.test-util :refer [error-code]])
  (:import (java.io File)
           (java.nio.file Files)
           (java.nio.file.attribute FileAttribute)
           (java.util.zip CRC32)))

(def columns
  [(table/->Column "i" :int64) (table/->Column "d" [:decimal 10 2]) (table/->Column "f" :float64)
   (table/->Column "b" :boolean) (table/->Column "s" :string) (table/->Column "dt" :date)
   (table/->Column "ts" :timestamp)])

(def rows
  [[1 1050 1.5 true "a" 0 0]
   [nil nil nil nil nil nil nil]
   [1 -99 -0.5 false "ünï" -719162 253402300799999999]
   [7 0 0.0 true "" 2932896 -62135596800000000]
   [1 1050 1.5 true "a" 0 0]])

(def tbl
  (table/make-table "t" columns (apply mapv (fn [& xs] (object-array xs)) rows) (count rows)))

(defn- temp-dir ^File []
  (.toFile (Files/createTempDirectory "pqcf-test" (make-array FileAttribute 0))))

(defn- read-rows [contents]
  (let [t (table/->Table "t" (:columns contents) (:row-count contents) :column (:segments contents) [] nil)
        cols (mapv #(vec (table/column-array t %)) (range (count (:columns contents))))]
    (apply mapv vector cols)))

(deftest crc32-check-value
  (let [c (CRC32.)]
    (.update c (.getBytes "123456789" "US-ASCII"))
    (is (= 0xCBF43926 (.getValue c)))))

(deftest round-trips
  (let [dir (temp-dir)]
    (doseq [encoding ["auto" "plain" "dict" "rle"]
            rg [1 2 1000]
            mmap? [false true]]
      (let [f (File. dir (str encoding rg ".pqcf"))
            size (pqcf/save! tbl f {:row-group-size rg :encoding encoding})
            contents (pqcf/open f {:mmap? mmap?})]
        (is (= size (.length f)))
        (is (= (count rows) (:row-count contents)))
        (is (= (mapv :name columns) (mapv :name (:columns contents))))
        (is (= rows (read-rows contents)) (str encoding " " rg " " mmap?))))
    (testing "no temporary files are left behind"
      (is (empty? (filter #(.startsWith (.getName ^File %) ".") (.listFiles dir)))))
    (testing "empty tables"
      (let [f (File. dir "empty.pqcf")
            empty-tbl (table/make-table "e" columns (repeat (count columns) (object-array 0)) 0)]
        (pqcf/save! empty-tbl f {})
        (is (= 0 (:row-count (pqcf/open f {}))))))))

(deftest invalid-files
  (let [dir (temp-dir)
        f (File. dir "t.pqcf")
        _ (pqcf/save! tbl f {})
        good (Files/readAllBytes (.toPath f))
        variant (fn [mutate]
                  (let [b (aclone ^bytes good)
                        b (or (mutate b) b)
                        g (File. dir "bad.pqcf")]
                    (Files/write (.toPath g) ^bytes b (make-array java.nio.file.OpenOption 0))
                    (error-code (read-rows (pqcf/open g {})))))]
    (is (= "STORAGE_CORRUPT" (variant (fn [^bytes b] (aset b 0 (byte 0x58)) nil))))
    (is (= "STORAGE_VERSION_UNSUPPORTED" (variant (fn [^bytes b] (aset b 4 (byte 2)) nil))))
    (is (= "STORAGE_VERSION_UNSUPPORTED" (variant (fn [^bytes b] (aset b 6 (byte 1)) nil))))
    (is (= "STORAGE_CORRUPT" (variant (fn [^bytes b] (aset b 8 (byte (bit-xor (aget b 8) 1))) nil))))
    (is (= "STORAGE_CORRUPT" (variant (fn [^bytes b] (java.util.Arrays/copyOf b (- (alength b) 3))))))
    (is (= "STORAGE_CORRUPT" (variant (fn [_] (byte-array 0)))))
    (testing "lazily verified chunks of mapped files fail on first use"
      (let [g (File. dir "lazy.pqcf")
            b (aclone ^bytes good)]
        (aset b 8 (byte (bit-xor (aget b 8) 1)))
        (Files/write (.toPath g) b (make-array java.nio.file.OpenOption 0))
        (let [contents (pqcf/open g {:mmap? true})]
          (is (= "STORAGE_CORRUPT" (error-code (read-rows contents)))))))
    (is (= "NOT_FOUND" (error-code (pqcf/open (File. dir "missing.pqcf") {}))))
    (is (= "IO_ERROR" (error-code (pqcf/save! tbl (File. dir "no/such/dir.pqcf") {}))))))
