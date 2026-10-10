package polyquery.engine;

import polyquery.storage.pqcf.SaveEncoding;

/** A validated {@code save} operation (protocol.md §5.7). */
public record SaveRequest(String table, String path, int rowGroupSize, SaveEncoding encoding) {
}
