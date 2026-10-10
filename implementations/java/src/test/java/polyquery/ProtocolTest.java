package polyquery;

import java.io.PrintStream;
import java.io.OutputStream;
import polyquery.protocol.Logger;
import polyquery.protocol.RequestHandler;

final class ProtocolTest {
    private ProtocolTest() {
    }

    private static RequestHandler handler() {
        return new RequestHandler(EngineTest.engine(),
                new Logger(Logger.Level.OFF, new PrintStream(OutputStream.nullOutputStream())));
    }

    private static void contains(String haystack, String needle) {
        Assert.check(haystack.contains(needle), "expected " + needle + " in " + haystack);
    }

    static void testRequests() {
        RequestHandler h = handler();
        contains(h.handleLine("{\"op\":\"tables\",\"id\":[1,{\"x\":2.50}]}"),
                "{\"id\":[1,{\"x\":2.50}],\"ok\":true,\"tables\":[{\"name\":\"people\",\"row_count\":4}]}");
        contains(h.handleLine("{\"op\":\"schema\",\"table\":\"PEOPLE\"}"), "\"table\":\"people\"");
        contains(h.handleLine("{\"op\":\"schema\",\"table\":\"nope\"}"), "\"code\":\"NOT_FOUND\"");
        contains(h.handleLine("not json"), "{\"id\":null,\"ok\":false,\"error\":{\"code\":\"INVALID_REQUEST\"");
        contains(h.handleLine("{\"op\":\"nope\"}"), "INVALID_REQUEST");
        contains(h.handleLine("{\"op\":\"query\",\"sql\":1}"), "INVALID_REQUEST");
        contains(h.handleLine("{\"op\":\"load\",\"table\":\"x\",\"format\":\"csv\",\"path\":\"../x.csv\"}"),
                "ACCESS_DENIED");
        contains(h.handleLine("{\"op\":\"load\",\"table\":\"x\",\"format\":\"csv\",\"path\":\"/etc/passwd\"}"),
                "ACCESS_DENIED");
        contains(h.handleLine("{\"op\":\"query\",\"sql\":\"SELECT id FROM people\",\"options\":{\"result\":\"count\"}}"),
                "\"columns\":[{\"name\":\"id\",\"type\":\"INT64\"}],\"row_count\":4");
    }

    static void testValueSerialization() {
        RequestHandler h = handler();
        contains(h.handleLine("{\"op\":\"query\",\"sql\":\"SELECT -0.0e0, 'a\\\"b\\\\c', DATE '0099-01-02', TIMESTAMP '2024-01-01 00:00:00.25'\"}"),
                "\"rows\":[[0.0,\"a\\\"b\\\\c\",\"0099-01-02\",\"2024-01-01 00:00:00.250000\"]]");
    }
}
