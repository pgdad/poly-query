package polyquery.storage.pqcf;

import java.util.Locale;

/** The {@code save} option {@code encoding}: automatic choice per chunk, or a forced encoding. */
public enum SaveEncoding {
    AUTO, PLAIN, DICT, RLE;

    /** Parses {@code auto|plain|dict|rle}; null if unknown. */
    public static SaveEncoding fromName(String name) {
        for (SaveEncoding e : values()) {
            if (e.name().toLowerCase(Locale.ROOT).equals(name)) {
                return e;
            }
        }
        return null;
    }
}
