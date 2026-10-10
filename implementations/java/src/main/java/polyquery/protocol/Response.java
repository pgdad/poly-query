package polyquery.protocol;

import polyquery.common.ErrorCode;

/**
 * A rendered protocol response.
 *
 * @param json    the single-line JSON response object
 * @param error   the error code of an error response, null on success
 * @param queryId the id of the query a {@code query} request ran as (null for other ops)
 */
public record Response(String json, ErrorCode error, String queryId) {
    public boolean ok() {
        return error == null;
    }
}
