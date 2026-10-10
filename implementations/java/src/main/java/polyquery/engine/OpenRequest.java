package polyquery.engine;

import polyquery.storage.Layout;

/** A validated {@code open} operation (protocol.md §5.7). */
public record OpenRequest(String table, String path, boolean mmap, boolean replace, Layout layout) {
}
