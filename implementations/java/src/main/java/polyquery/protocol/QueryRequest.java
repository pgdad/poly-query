package polyquery.protocol;

import java.util.Map;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.engine.QueryOptions;
import polyquery.physical.PhysicalPlanner.JoinStrategy;

/**
 * The validated fields of a {@code query}/{@code explain} request (protocol.md §5.2).
 *
 * @param queryId the client-assigned {@code options.query_id}, or null
 */
public record QueryRequest(String sql, QueryOptions options, String queryId) {

    /** Validates {@code sql} and {@code options}; INVALID_REQUEST / UNSUPPORTED on bad input. */
    public static QueryRequest parse(Map<String, Object> req) {
        String sql = RequestHandler.requireString(req, "sql");
        Map<String, Object> o = RequestHandler.optionalObject(req, "options");
        QueryOptions options = parseOptions(o);
        Object queryId = o.get("query_id");
        if (queryId != null && !(queryId instanceof String)) {
            throw RequestException.invalid("'query_id' must be a string");
        }
        return new QueryRequest(sql, options, (String) queryId);
    }

    private static QueryOptions parseOptions(Map<String, Object> o) {
        Long maxRows = RequestHandler.optionalNonNegativeLong(o, "max_rows");
        Long timeout = RequestHandler.optionalNonNegativeLong(o, "timeout_ms");
        boolean countOnly = false;
        Object result = o.get("result");
        if (result != null) {
            if (!(result instanceof String rs)) {
                throw RequestException.invalid("'result' must be a string");
            }
            switch (rs) {
                case "rows" -> countOnly = false;
                case "count" -> countOnly = true;
                default -> throw PolyQueryException.of(ErrorCode.UNSUPPORTED, "result mode '%s' is not supported", rs);
            }
        }
        Object mode = o.get("mode");
        if (mode != null) {
            if (!(mode instanceof String ms)) {
                throw RequestException.invalid("'mode' must be a string");
            }
            if (!ms.equals("auto") && !ms.equals("row")) {
                throw PolyQueryException.of(ErrorCode.UNSUPPORTED, "execution mode '%s' is not supported", ms);
            }
        }
        JoinStrategy joinStrategy = JoinStrategy.AUTO;
        Object join = o.get("join");
        if (join != null) {
            if (!(join instanceof String js)) {
                throw RequestException.invalid("'join' must be a string");
            }
            joinStrategy = switch (js) {
                case "auto", "merge" -> JoinStrategy.AUTO;
                case "hash" -> JoinStrategy.HASH;
                case "nested_loop" -> JoinStrategy.NESTED_LOOP;
                default -> throw PolyQueryException.of(ErrorCode.UNSUPPORTED, "join algorithm '%s' is not supported", js);
            };
        }
        Long threads = RequestHandler.optionalNonNegativeLong(o, "threads");
        if (threads != null && threads < 1) {
            throw RequestException.invalid("'threads' must be >= 1");
        }
        boolean optimize = RequestHandler.optionalBoolean(o, "optimize", true);
        boolean useIndexes = RequestHandler.optionalBoolean(o, "use_indexes", true);
        RequestHandler.optionalBoolean(o, "native", false);
        return new QueryOptions(maxRows == null ? -1 : maxRows, timeout == null ? 0 : timeout, countOnly, optimize,
                joinStrategy, useIndexes);
    }
}
