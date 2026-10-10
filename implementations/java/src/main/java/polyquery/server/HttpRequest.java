package polyquery.server;

import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * A parsed HTTP/1.1 request.
 *
 * @param path      the decoded path segments (without empty segments)
 * @param query     decoded query-string parameters (last occurrence wins)
 * @param headers   header values by lower-case name
 * @param keepAlive whether the client wants the connection to persist
 */
record HttpRequest(String method, String target, List<String> path, Map<String, String> query,
                   Map<String, String> headers, byte[] body, boolean keepAlive) {

    String header(String name) {
        return headers.get(name.toLowerCase(Locale.ROOT));
    }
}
