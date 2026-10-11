(ns polyquery.native.ffi
  "Binding of the native kernel library libpqkernels
  (native-kernels/include/pq_kernels.h, ABI version 1) through the Java
  Foreign Function & Memory API (spec/phases/native-kernels.md).

  Every C function is bound once, when the library is loaded, as a downcall
  method handle. Clojure cannot invoke a method handle's signature-
  polymorphic invokeExact directly, so each handle is wrapped by
  java.lang.invoke.MethodHandleProxies into an instance of a one-method
  interface with the C signature in primitive Java types (the interfaces
  below); the proxy calls invokeExact on a constant handle, which the JIT
  compiles to a direct native call.

  The kernels are bound as *critical* downcalls (Linker.Option.critical with
  heap access): they are short, never block or call back into the JVM, so
  they may read and write Java arrays in place. Callers pass long[]/int[]
  arrays, wrapped as heap memory segments; no data is copied. Bitmaps are
  long[] arrays: on a little-endian machine the bytes of a long[] are
  exactly the LSB-first byte bitmap of the C ABI (row i = bit i%8 of byte
  i/8 = bit i%64 of word i/64).

  The library is optional: `load!` returns nil (and logs why) when it
  cannot be loaded or has another ABI version, and the engine then runs
  its own code paths."
  (:require [polyquery.util.log :as log])
  (:import (java.lang.foreign Arena FunctionDescriptor Linker Linker$Option MemoryLayout
                              MemorySegment SymbolLookup ValueLayout)
           (java.lang.invoke MethodHandle MethodHandleProxies)
           (java.nio ByteOrder)
           (java.nio.file Path)))

(set! *warn-on-reflection* true)

(def ^:const abi-version 1)

;; status codes and comparison operators of the C ABI
(def ^:const OK 0)
(def ^:const OVERFLOW 1)
(def ^:const EINVAL 2)

(def ^:const EQ 0)
(def ^:const NE 1)
(def ^:const LT 2)
(def ^:const LE 3)
(def ^:const GT 4)
(def ^:const GE 5)
(def ^:const BETWEEN 6)

;; ---------------------------------------------------------------------------
;; One interface per C signature (size_t ↔ long, int ↔ int, pointers ↔
;; MemorySegment)

(definterface IntFn
  (^int call []))

(definterface PtrFn
  (^java.lang.foreign.MemorySegment call []))

(definterface PredicateFn
  ;; pqk_filter_i64, pqk_filter_i64_bitmap
  (^long call [^java.lang.foreign.MemorySegment data ^java.lang.foreign.MemorySegment validity
               ^long n ^int op ^long a ^long b ^java.lang.foreign.MemorySegment out]))

(definterface CountFn
  (^long call [^java.lang.foreign.MemorySegment data ^java.lang.foreign.MemorySegment validity
               ^long n ^int op ^long a ^long b]))

(definterface SumFn
  (^int call [^java.lang.foreign.MemorySegment data ^java.lang.foreign.MemorySegment validity
              ^long n ^java.lang.foreign.MemorySegment out]))

(definterface MinMaxFn
  ;; pqk_minmax_i64, pqk_minmax_f64
  (^long call [^java.lang.foreign.MemorySegment data ^java.lang.foreign.MemorySegment validity
               ^long n ^java.lang.foreign.MemorySegment outMin ^java.lang.foreign.MemorySegment outMax]))

(definterface BitmapFn
  ;; pqk_bitmap_and, pqk_bitmap_or, pqk_bitmap_andnot
  (^void call [^java.lang.foreign.MemorySegment a ^java.lang.foreign.MemorySegment b
               ^java.lang.foreign.MemorySegment out ^long nbytes]))

(definterface PopcountFn
  (^long call [^java.lang.foreign.MemorySegment bits ^long nbits]))

(definterface HashFn
  (^void call [^java.lang.foreign.MemorySegment data ^long n ^long seed
               ^java.lang.foreign.MemorySegment out]))

(definterface CompareFn
  (^long call [^java.lang.foreign.MemorySegment a ^java.lang.foreign.MemorySegment b
               ^long n ^int op ^java.lang.foreign.MemorySegment out]))

(definterface GroupSumFn
  (^int call [^java.lang.foreign.MemorySegment gids ^java.lang.foreign.MemorySegment values
              ^java.lang.foreign.MemorySegment validity ^long n
              ^java.lang.foreign.MemorySegment sums ^java.lang.foreign.MemorySegment counts
              ^long ngroups]))

(definterface GatherFn
  (^void call [^java.lang.foreign.MemorySegment data ^java.lang.foreign.MemorySegment idx
               ^long m ^java.lang.foreign.MemorySegment out]))

(deftype Library [^String path ^String variant ^String available
                  ^PredicateFn filter-i64 ^PredicateFn filter-i64-bitmap ^CountFn count-i64
                  ^SumFn sum-i64 ^MinMaxFn minmax-i64 ^MinMaxFn minmax-f64
                  ^BitmapFn bitmap-and ^BitmapFn bitmap-or ^BitmapFn bitmap-andnot
                  ^PopcountFn bitmap-popcount ^HashFn hash-i64 ^CompareFn compare-i64
                  ^GroupSumFn group-sum-i64 ^GatherFn gather-i64])

;; ---------------------------------------------------------------------------
;; Loading

(def ^:private A ValueLayout/ADDRESS)
(def ^:private L ValueLayout/JAVA_LONG)
(def ^:private I ValueLayout/JAVA_INT)

(defn- downcall
  "Interface instance `iface` calling C function `fname` of the library
  with the given result layout (nil = void) and argument layouts."
  [^SymbolLookup lookup ^Class iface fname result args critical?]
  (let [sym (.orElseThrow (.find lookup ^String fname))
        args (into-array MemoryLayout args)
        desc (if result
               (FunctionDescriptor/of result args)
               (FunctionDescriptor/ofVoid args))
        opts (into-array Linker$Option (when critical? [(Linker$Option/critical true)]))
        ^MethodHandle mh (.downcallHandle (Linker/nativeLinker) ^MemorySegment sym
                                          ^FunctionDescriptor desc opts)]
    (MethodHandleProxies/asInterfaceInstance iface mh)))

(defn- c-string ^String [^MemorySegment p]
  (when-not (= p MemorySegment/NULL)
    (.getString (.reinterpret p 4096) 0)))

(defn- open-library
  [^String path]
  (let [lookup (SymbolLookup/libraryLookup (Path/of path (make-array String 0)) (Arena/global))
        f (fn [iface fname result args] (downcall lookup iface fname result args true))
        ^IntFn abi (downcall lookup IntFn "pqk_abi_version" I [] false)
        version (.call abi)]
    (if (not= abi-version version)
      (do (log/warn "native kernel library has an unsupported ABI version; not used"
                    {"path" path "abi_version" version})
          nil)
      (let [^IntFn init (downcall lookup IntFn "pqk_init" I [] false)
            ^PtrFn variant (downcall lookup PtrFn "pqk_variant" A [] false)
            ^PtrFn available (downcall lookup PtrFn "pqk_available_variants" A [] false)]
        (.call init)
        (Library. path (c-string (.call variant)) (c-string (.call available))
                  (f PredicateFn "pqk_filter_i64" L [A A L I L L A])
                  (f PredicateFn "pqk_filter_i64_bitmap" L [A A L I L L A])
                  (f CountFn "pqk_count_i64" L [A A L I L L])
                  (f SumFn "pqk_sum_i64" I [A A L A])
                  (f MinMaxFn "pqk_minmax_i64" L [A A L A A])
                  (f MinMaxFn "pqk_minmax_f64" L [A A L A A])
                  (f BitmapFn "pqk_bitmap_and" nil [A A A L])
                  (f BitmapFn "pqk_bitmap_or" nil [A A A L])
                  (f BitmapFn "pqk_bitmap_andnot" nil [A A A L])
                  (f PopcountFn "pqk_bitmap_popcount" L [A L])
                  (f HashFn "pqk_hash_i64" nil [A L L A])
                  (f CompareFn "pqk_compare_i64" L [A A L I A])
                  (f GroupSumFn "pqk_group_sum_i64" I [A A A L A A L])
                  (f GatherFn "pqk_gather_i64" nil [A A L A]))))))

(defonce ^:private loaded (atom nil))

(defn library
  "The loaded Library, or nil."
  ^polyquery.native.ffi.Library []
  @loaded)

(defn load!
  "Loads libpqkernels from `path` (--native-kernels) and makes it the
  process's kernel library. Returns the Library, or nil (with a warning
  logged) when it cannot be used; the engine then uses its own code."
  [^String path]
  (let [lib (try
              (if (not= ByteOrder/LITTLE_ENDIAN (ByteOrder/nativeOrder))
                (do (log/warn "native kernels need a little-endian platform; not used" {"path" path})
                    nil)
                (open-library path))
              (catch Throwable t
                (log/warn "cannot load the native kernel library; using the engine's own kernels"
                          {"path" path "error" (str t)})
                nil))]
    (when lib
      (log/info "native kernel library loaded"
                {"path" path "variant" (.-variant ^Library lib) "available" (.-available ^Library lib)}))
    (reset! loaded lib)))

(defn unload!
  "Forgets the loaded library (tests)."
  []
  (reset! loaded nil))

(defn info
  "{\"path\" \"variant\" \"available\"} of the loaded library, or nil."
  []
  (when-let [^Library lib @loaded]
    {"path" (.-path lib) "variant" (.-variant lib) "available" (.-available lib)}))

;; ---------------------------------------------------------------------------
;; Calls on Java arrays. Arrays are passed in place (heap segments); nil
;; stands for a NULL pointer (e.g. "all rows valid"). The calls are macros
;; so that every call site compiles to a direct interface call with
;; primitive arguments (Clojure functions take at most 4 primitive args).

(defmacro segment
  "Heap segment of a primitive array expression with type tag `tag`
  (nil → the NULL pointer)."
  [x tag]
  (let [s (with-meta (gensym "a") {:tag tag})]
    `(let [~s ~x] (if (nil? ~s) MemorySegment/NULL (MemorySegment/ofArray ~s)))))

(defn- lib-sym [] (with-meta (gensym "lib") {:tag `Library}))

(defmacro filter-i64
  "Writes the indices i < n (ascending) where `data[i] op (a, b)` holds and
  row i is valid to int[] out; returns their count (long)."
  [lib data validity n op a b out]
  (let [l (lib-sym)]
    `(let [~l ~lib]
       (.call ^PredicateFn (.-filter-i64 ~l) (segment ~data "[J") (segment ~validity "[J")
              (long ~n) (int ~op) (long ~a) (long ~b) (segment ~out "[I")))))

(defmacro filter-i64-bitmap
  "Bitmap (long[] out) of the rows i < n where `data[i] op (a, b)` holds and
  row i is valid; returns the number of set bits."
  [lib data validity n op a b out]
  (let [l (lib-sym)]
    `(let [~l ~lib]
       (.call ^PredicateFn (.-filter-i64-bitmap ~l) (segment ~data "[J") (segment ~validity "[J")
              (long ~n) (int ~op) (long ~a) (long ~b) (segment ~out "[J")))))

(defmacro count-i64
  "Number of valid rows i < n where `data[i] op (a, b)` holds."
  [lib data validity n op a b]
  (let [l (lib-sym)]
    `(let [~l ~lib]
       (.call ^CountFn (.-count-i64 ~l) (segment ~data "[J") (segment ~validity "[J")
              (long ~n) (int ~op) (long ~a) (long ~b)))))

(defmacro sum-i64
  "Exact sum of the valid values of data[0..n) into (long[] out)[0];
  returns OK or OVERFLOW (out untouched)."
  [lib data validity n out]
  (let [l (lib-sym)]
    `(let [~l ~lib]
       (.call ^SumFn (.-sum-i64 ~l) (segment ~data "[J") (segment ~validity "[J") (long ~n)
              (segment ~out "[J")))))

(defmacro minmax-i64
  "Number of valid values of data[0..n); when positive, their minimum and
  maximum are in (long[] out)[0] and [1]."
  [lib data validity n out]
  (let [l (lib-sym) o (with-meta (gensym "out") {:tag 'java.lang.foreign.MemorySegment})]
    `(let [~l ~lib ~o (segment ~out "[J")]
       (.call ^MinMaxFn (.-minmax-i64 ~l) (segment ~data "[J") (segment ~validity "[J") (long ~n)
              (.asSlice ~o 0 8) (.asSlice ~o 8 8)))))

(defmacro minmax-f64
  "minmax-i64 for (finite) doubles: double[] data and out."
  [lib data validity n out]
  (let [l (lib-sym) o (with-meta (gensym "out") {:tag 'java.lang.foreign.MemorySegment})]
    `(let [~l ~lib ~o (segment ~out "[D")]
       (.call ^MinMaxFn (.-minmax-f64 ~l) (segment ~data "[D") (segment ~validity "[J") (long ~n)
              (.asSlice ~o 0 8) (.asSlice ~o 8 8)))))

(defmacro bitmap-call
  "Call of one of the three binary bitmap kernels (field: its accessor)."
  [field lib a b out nwords]
  (let [l (lib-sym)]
    `(let [~l ~lib]
       (.call ^BitmapFn (~field ~l) (segment ~a "[J") (segment ~b "[J") (segment ~out "[J")
              (* 8 (long ~nwords))))))

(defmacro bitmap-and!
  "out = a & b over nwords 64-bit words (out may be a or b)."
  [lib a b out nwords]
  `(bitmap-call .-bitmap-and ~lib ~a ~b ~out ~nwords))

(defmacro bitmap-or!
  "out = a | b over nwords words."
  [lib a b out nwords]
  `(bitmap-call .-bitmap-or ~lib ~a ~b ~out ~nwords))

(defmacro bitmap-andnot!
  "out = a & ~b over nwords words."
  [lib a b out nwords]
  `(bitmap-call .-bitmap-andnot ~lib ~a ~b ~out ~nwords))

(defmacro popcount
  "Set bits among the first nbits bits of a long[] bitmap."
  [lib bits nbits]
  (let [l (lib-sym)]
    `(let [~l ~lib]
       (.call ^PopcountFn (.-bitmap-popcount ~l) (segment ~bits "[J") (long ~nbits)))))

(defmacro hash-i64!
  "out[i] = fmix64(data[i] ^ seed) for i < n (long[] data and out)."
  [lib data n seed out]
  (let [l (lib-sym)]
    `(let [~l ~lib]
       (.call ^HashFn (.-hash-i64 ~l) (segment ~data "[J") (long ~n) (long ~seed) (segment ~out "[J")))))

(defmacro compare-i64
  "Bitmap (long[] out) of `a[i] op b[i]` for i < n (validity not
  consulted); returns the number of set bits."
  [lib a b n op out]
  (let [l (lib-sym)]
    `(let [~l ~lib]
       (.call ^CompareFn (.-compare-i64 ~l) (segment ~a "[J") (segment ~b "[J") (long ~n) (int ~op)
              (segment ~out "[J")))))

(defmacro group-sum-i64
  "sums[gids[i]] += values[i], counts[gids[i]] += 1 for the valid rows
  i < n (wrapping); returns OK, OVERFLOW (some addition wrapped) or EINVAL."
  [lib gids values validity n sums counts ngroups]
  (let [l (lib-sym)]
    `(let [~l ~lib]
       (.call ^GroupSumFn (.-group-sum-i64 ~l) (segment ~gids "[I") (segment ~values "[J")
              (segment ~validity "[J") (long ~n) (segment ~sums "[J") (segment ~counts "[J")
              (long ~ngroups)))))

(defmacro gather-i64!
  "out[j] = data[idx[j]] for j < m (long[] data/out, int[] idx)."
  [lib data idx m out]
  (let [l (lib-sym)]
    `(let [~l ~lib]
       (.call ^GatherFn (.-gather-i64 ~l) (segment ~data "[J") (segment ~idx "[I") (long ~m)
              (segment ~out "[J")))))
