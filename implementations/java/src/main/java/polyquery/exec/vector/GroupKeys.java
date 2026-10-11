package polyquery.exec.vector;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import polyquery.ffi.NativeKernels;
import polyquery.types.DataType;

/**
 * Hash table assigning dense ids (0, 1, 2, … in order of first appearance) to key tuples, used
 * for GROUP BY, DISTINCT and hash joins.
 *
 * <p>Cache-conscious layout: every key column value is encoded as a {@code long} (INT64 and
 * friends as is, FLOAT64 as the bits of the value with -0.0 normalized, STRING as an id of an
 * interning dictionary, with a per-dictionary code→id cache for dictionary-encoded input), plus
 * null bits. Hashes are computed from the values (strings by {@link String#hashCode}), so
 * equal keys have equal hashes in all tables — partial tables of parallel workers can be
 * partitioned by hash and merged partition by partition. Tuples are stored flat in a {@code long[]} (struct of arrays), the open-addressing
 * index ({@code int[]}, linear probing) holds only group ids, and the full hash of each group is
 * kept so most mismatches are rejected without touching the keys. Equality is that of GROUP BY
 * and DISTINCT: NULLs are equal to each other.
 *
 * <p>Single-column keys (the common case) are hashed with the MurmurHash3 finalizer
 * {@code fmix64(value ^ SEED)}; with native kernels (option {@code native}) a batch is hashed by
 * {@code pqk_hash_i64}, which computes exactly the same function, so tables built with and
 * without the library are identical.
 */
final class GroupKeys {
    private static final long M1 = 0x9E3779B97F4A7C15L;
    private static final long M2 = 0xC2B2AE3D27D4EB4FL;
    /** Seed of single-column key hashes. */
    private static final long SEED = 0x2545F4914F6CDD1DL;
    /** Hash of a NULL single-column key. */
    private static final long NULL_HASH = 0x6A09E667F3BCC909L;

    private final DataType[] types;
    private final Vec.Kind[] kinds;
    private final int k;
    private final int nullWords;
    private long[] keys;
    private long[] nullBits;
    private long[] hashes;
    private int groups;
    private int[] index;
    private int mask;
    // STRING key columns: interning
    private final List<Map<String, Integer>> interned;
    private final List<List<String>> strings;
    private final String[][] seenDict;
    private final int[][] dictIds;
    // per-batch scratch
    private long[][] codes;
    /** Per column, the values hashed: the codes, except for STRING columns (String.hashCode). */
    private long[][] hashIn;
    private int[][] dictHashes;
    private long[][] nulls;
    private long[] rowHash;
    private final long[] tupleCodes;
    private final long[] tupleNulls;
    private final NativeKernels kernels;

    /** @param kernels native kernels for hashing, or null */
    GroupKeys(DataType[] types, NativeKernels kernels) {
        this.kernels = kernels;
        this.types = types.clone();
        this.k = types.length;
        this.kinds = new Vec.Kind[k];
        this.interned = new ArrayList<>();
        this.strings = new ArrayList<>();
        for (int j = 0; j < k; j++) {
            kinds[j] = Vec.kindOf(types[j]);
            interned.add(kinds[j] == Vec.Kind.OBJECT ? new HashMap<>() : null);
            strings.add(kinds[j] == Vec.Kind.OBJECT ? new ArrayList<>() : null);
        }
        this.nullWords = Math.max(1, (k + 63) >>> 6);
        this.seenDict = new String[k][];
        this.dictIds = new int[k][];
        this.keys = new long[16 * Math.max(1, k)];
        this.nullBits = new long[16 * nullWords];
        this.hashes = new long[16];
        this.index = new int[64];
        this.mask = 63;
        this.codes = new long[k][0];
        this.hashIn = new long[k][0];
        this.dictHashes = new int[k][];
        this.nulls = new long[nullWords][0];
        this.rowHash = new long[0];
        this.tupleCodes = new long[k];
        this.tupleNulls = new long[nullWords];
    }

    /** Hash of group g's key values (independent of the table: equal keys hash equally in every table). */
    long hash(int g) {
        return hashes[g];
    }

    /** A view sharing this (no longer modified) table with its own scratch space, for concurrent lookups. */
    private GroupKeys(GroupKeys t) {
        this.kernels = t.kernels;
        this.types = t.types;
        this.kinds = t.kinds;
        this.k = t.k;
        this.nullWords = t.nullWords;
        this.keys = t.keys;
        this.nullBits = t.nullBits;
        this.hashes = t.hashes;
        this.groups = t.groups;
        this.index = t.index;
        this.mask = t.mask;
        this.interned = t.interned;
        this.strings = t.strings;
        this.seenDict = new String[k][];
        this.dictIds = new int[k][];
        this.codes = new long[k][0];
        this.hashIn = new long[k][0];
        this.dictHashes = new int[k][];
        this.nulls = new long[nullWords][0];
        this.rowHash = new long[0];
        this.tupleCodes = new long[k];
        this.tupleNulls = new long[nullWords];
    }

    /** A read-only view for {@link #lookup} from another thread (the table must not change anymore). */
    GroupKeys prober() {
        return new GroupKeys(this);
    }

    int groupCount() {
        return groups;
    }

    int keyCount() {
        return k;
    }

    private static long mix(long h, long v) {
        h = (h ^ v) * M1;
        return h ^ (h >>> 31);
    }

    private static int fold(long h) {
        h *= M2;
        return (int) (h ^ (h >>> 32));
    }

    private int internId(int j, String s) {
        Map<String, Integer> map = interned.get(j);
        Integer id = map.get(s);
        if (id == null) {
            id = map.size();
            map.put(s, id);
            strings.get(j).add(s);
        }
        return id;
    }

    /** Id of {@code s} in column j's interning dictionary, or -1 (lookup only). */
    private int lookupId(int j, String s) {
        Integer id = interned.get(j).get(s);
        return id == null ? -1 : id;
    }

    /**
     * Encodes key column j at the active positions into {@code codes[j]} / {@code nulls}.
     * With {@code insert == false} unknown strings get code -1 (they cannot match any group).
     */
    private void encode(int j, Vec v, int[] sel, int n, boolean insert) {
        long[] c = codes[j];
        long bit = 1L << (j & 63);
        long[] nw = nulls[j >>> 6];
        boolean nullable = v.hasNulls;
        switch (v.kind) {
            case LONG -> {
                long[] x = v.longs;
                for (int kk = 0; kk < n; kk++) {
                    int i = sel == null ? kk : sel[kk];
                    c[i] = x[i];
                }
            }
            case DOUBLE -> {
                double[] x = v.doubles;
                for (int kk = 0; kk < n; kk++) {
                    int i = sel == null ? kk : sel[kk];
                    double d = x[i];
                    c[i] = Double.doubleToLongBits(d == 0.0 ? 0.0 : d);
                }
            }
            case DICT -> {
                if (seenDict[j] != v.dict) {
                    seenDict[j] = v.dict;
                    dictIds[j] = new int[v.dict.length];
                    Arrays.fill(dictIds[j], -2);
                    dictHashes[j] = new int[v.dict.length];
                    for (int d = 0; d < v.dict.length; d++) {
                        dictHashes[j][d] = v.dict[d].hashCode();
                    }
                }
                int[] ids = dictIds[j];
                int[] hashes = dictHashes[j];
                long[] h = hashIn[j];
                for (int kk = 0; kk < n; kk++) {
                    int i = sel == null ? kk : sel[kk];
                    if (nullable && v.nulls[i]) {
                        continue;
                    }
                    int code = v.codes[i];
                    int id = ids[code];
                    if (id == -2 || id == -1 && insert) {
                        id = insert ? internId(j, v.dict[code]) : lookupId(j, v.dict[code]);
                        ids[code] = id;
                    }
                    c[i] = id;
                    h[i] = hashes[code];
                }
            }
            case OBJECT -> {
                long[] h = hashIn[j];
                for (int kk = 0; kk < n; kk++) {
                    int i = sel == null ? kk : sel[kk];
                    if (nullable && v.nulls[i]) {
                        continue;
                    }
                    String s = (String) v.objects[i];
                    if (s == null) {
                        continue;
                    }
                    c[i] = insert ? internId(j, s) : lookupId(j, s);
                    h[i] = s.hashCode();
                }
            }
        }
        for (int kk = 0; kk < n; kk++) {
            int i = sel == null ? kk : sel[kk];
            if (v.isNull(i) || v.kind == Vec.Kind.OBJECT && v.objects[i] == null) {
                nw[i] |= bit;
                c[i] = 0;
                hashIn[j][i] = 0;
            }
        }
    }

    private void prepare(int size) {
        if (rowHash.length < size) {
            for (int j = 0; j < k; j++) {
                codes[j] = new long[size];
                hashIn[j] = kinds[j] == Vec.Kind.OBJECT ? new long[size] : codes[j];
            }
            for (int w = 0; w < nullWords; w++) {
                nulls[w] = new long[size];
            }
            rowHash = new long[size];
        }
    }

    /** Encodes and hashes the key tuples of the active rows. */
    private void encodeAll(Vec[] vecs, int[] sel, int n, int size, boolean insert) {
        prepare(size);
        for (int w = 0; w < nullWords; w++) {
            long[] nw = nulls[w];
            for (int kk = 0; kk < n; kk++) {
                nw[sel == null ? kk : sel[kk]] = 0;
            }
        }
        for (int j = 0; j < k; j++) {
            encode(j, vecs[j], sel, n, insert);
        }
        if (k == 1) {
            hashSingle(vecs[0], sel, n);
            return;
        }
        for (int kk = 0; kk < n; kk++) {
            int i = sel == null ? kk : sel[kk];
            long h = M2;
            for (int j = 0; j < k; j++) {
                h = mix(h, hashIn[j][i]);
            }
            for (int w = 0; w < nullWords; w++) {
                h = mix(h, nulls[w][i]);
            }
            rowHash[i] = h;
        }
    }

    /** Hashes of single-column keys: {@code fmix64(hashIn ^ SEED)}, NULL keys {@link #NULL_HASH}. */
    private void hashSingle(Vec v, int[] sel, int n) {
        long[] h = hashIn[0];
        long[] nw = nulls[0];
        if (kernels != null && n > 0) {
            // dense over the positions up to the last active one (inactive ones are harmless)
            kernels.hash(h, sel == null ? n : sel[n - 1] + 1, SEED, rowHash);
            if (v.hasNulls || v.kind == Vec.Kind.OBJECT) {
                for (int kk = 0; kk < n; kk++) {
                    int i = sel == null ? kk : sel[kk];
                    if (nw[i] != 0) {
                        rowHash[i] = NULL_HASH;
                    }
                }
            }
            return;
        }
        for (int kk = 0; kk < n; kk++) {
            int i = sel == null ? kk : sel[kk];
            rowHash[i] = nw[i] != 0 ? NULL_HASH : NativeKernels.fmix64(h[i] ^ SEED);
        }
    }

    private boolean rowEquals(int g, int i) {
        int base = g * k;
        for (int j = 0; j < k; j++) {
            if (keys[base + j] != codes[j][i]) {
                return false;
            }
        }
        int nb = g * nullWords;
        for (int w = 0; w < nullWords; w++) {
            if (nullBits[nb + w] != nulls[w][i]) {
                return false;
            }
        }
        return true;
    }

    /**
     * Group ids of the active rows, written to {@code gids} at their positions; tuples not seen
     * before become new groups (in row order).
     */
    void groupIds(Vec[] vecs, int[] sel, int n, int size, int[] gids) {
        if (k == 0) {
            if (groups == 0) {
                addGroup(M2);
            }
            for (int kk = 0; kk < n; kk++) {
                gids[sel == null ? kk : sel[kk]] = 0;
            }
            return;
        }
        encodeAll(vecs, sel, n, size, true);
        for (int kk = 0; kk < n; kk++) {
            int i = sel == null ? kk : sel[kk];
            long h = rowHash[i];
            int slot = fold(h) & mask;
            while (true) {
                int g = index[slot] - 1;
                if (g < 0) {
                    g = addGroup(h);
                    int base = g * k;
                    for (int j = 0; j < k; j++) {
                        keys[base + j] = codes[j][i];
                    }
                    int nb = g * nullWords;
                    for (int w = 0; w < nullWords; w++) {
                        nullBits[nb + w] = nulls[w][i];
                    }
                    index[slot] = g + 1;
                    gids[i] = g;
                    if (groups * 2 > index.length) {
                        rehash();
                    }
                    break;
                }
                if (hashes[g] == h && rowEquals(g, i)) {
                    gids[i] = g;
                    break;
                }
                slot = (slot + 1) & mask;
            }
        }
    }

    /**
     * Looks up the active rows without inserting: {@code gids} receives the group id or -1. Rows
     * with a NULL key component get -1 when {@code nullsMatch} is false (join semantics).
     */
    void lookup(Vec[] vecs, int[] sel, int n, int size, int[] gids, boolean nullsMatch) {
        encodeAll(vecs, sel, n, size, false);
        for (int kk = 0; kk < n; kk++) {
            int i = sel == null ? kk : sel[kk];
            boolean unknown = false;
            for (int j = 0; j < k && !unknown; j++) {
                unknown = kinds[j] == Vec.Kind.OBJECT && codes[j][i] < 0;
            }
            if (unknown) {
                gids[i] = -1;
                continue;
            }
            if (!nullsMatch) {
                boolean anyNull = false;
                for (int w = 0; w < nullWords; w++) {
                    anyNull |= nulls[w][i] != 0;
                }
                if (anyNull) {
                    gids[i] = -1;
                    continue;
                }
            }
            long h = rowHash[i];
            int slot = fold(h) & mask;
            int found = -1;
            while (true) {
                int g = index[slot] - 1;
                if (g < 0) {
                    break;
                }
                if (hashes[g] == h && rowEquals(g, i)) {
                    found = g;
                    break;
                }
                slot = (slot + 1) & mask;
            }
            gids[i] = found;
        }
    }

    /** True if group g has a NULL key component. */
    boolean hasNull(int g) {
        int nb = g * nullWords;
        for (int w = 0; w < nullWords; w++) {
            if (nullBits[nb + w] != 0) {
                return true;
            }
        }
        return false;
    }

    private int addGroup(long h) {
        if (groups == hashes.length) {
            int n = hashes.length * 2;
            hashes = Arrays.copyOf(hashes, n);
            keys = Arrays.copyOf(keys, n * Math.max(1, k));
            nullBits = Arrays.copyOf(nullBits, n * nullWords);
        }
        hashes[groups] = h;
        return groups++;
    }

    /** Makes room for {@code n} groups without further growth or rehashing. */
    void ensureCapacity(int n) {
        if (hashes.length < n) {
            hashes = Arrays.copyOf(hashes, n);
            keys = Arrays.copyOf(keys, n * Math.max(1, k));
            nullBits = Arrays.copyOf(nullBits, n * nullWords);
        }
        if (index.length < 2L * n) {
            int cap = Integer.highestOneBit(Math.max(64, 2 * n - 1)) << 1;
            index = new int[cap / 2];
            rehash();
        }
    }

    private void rehash() {
        int cap = index.length * 2;
        index = new int[cap];
        mask = cap - 1;
        for (int g = 0; g < groups; g++) {
            int slot = fold(hashes[g]) & mask;
            while (index[slot] != 0) {
                slot = (slot + 1) & mask;
            }
            index[slot] = g + 1;
        }
    }

    /**
     * Id of the group of {@code other}'s group {@code g} in this table, inserting it if absent
     * (merging partial aggregation tables of the same key types).
     */
    int addFrom(GroupKeys other, int g) {
        if (k == 0) {
            if (groups == 0) {
                addGroup(M2);
            }
            return 0;
        }
        System.arraycopy(other.nullBits, g * nullWords, tupleNulls, 0, nullWords);
        for (int j = 0; j < k; j++) {
            long c = other.keys[g * k + j];
            boolean isNull = (tupleNulls[j >>> 6] & (1L << (j & 63))) != 0;
            if (kinds[j] == Vec.Kind.OBJECT && !isNull) {
                c = internId(j, other.strings.get(j).get((int) c));
            }
            tupleCodes[j] = c;
        }
        long h = other.hashes[g]; // value-based, so equal across tables
        int slot = fold(h) & mask;
        while (true) {
            int found = index[slot] - 1;
            if (found < 0) {
                break;
            }
            if (hashes[found] == h && tupleEquals(found)) {
                return found;
            }
            slot = (slot + 1) & mask;
        }
        int ng = addGroup(h);
        System.arraycopy(tupleCodes, 0, keys, ng * k, k);
        System.arraycopy(tupleNulls, 0, nullBits, ng * nullWords, nullWords);
        index[slot] = ng + 1;
        if (groups * 2 > index.length) {
            rehash();
        }
        return ng;
    }

    private boolean tupleEquals(int g) {
        for (int j = 0; j < k; j++) {
            if (keys[g * k + j] != tupleCodes[j]) {
                return false;
            }
        }
        for (int w = 0; w < nullWords; w++) {
            if (nullBits[g * nullWords + w] != tupleNulls[w]) {
                return false;
            }
        }
        return true;
    }

    /** Writes key column j of group g to position {@code pos} of {@code out} (null mask prepared). */
    void decode(int g, int j, Vec out, int pos) {
        if ((nullBits[g * nullWords + (j >>> 6)] & (1L << (j & 63))) != 0) {
            out.nulls[pos] = true;
            if (out.kind == Vec.Kind.OBJECT) {
                out.objects[pos] = null;
            }
            return;
        }
        out.nulls[pos] = false;
        long c = keys[g * k + j];
        switch (kinds[j]) {
            case LONG -> out.longs[pos] = c;
            case DOUBLE -> out.doubles[pos] = Double.longBitsToDouble(c);
            default -> out.objects[pos] = strings.get(j).get((int) c);
        }
    }

    DataType type(int j) {
        return types[j];
    }
}
