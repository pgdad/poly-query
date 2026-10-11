package polyquery.engine;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Static engine identity and capabilities. */
public final class Version {
    public static final String ENGINE = "polyquery-java";
    public static final String ENGINE_VERSION = "0.1.0";
    public static final int PROTOCOL_VERSION = 1;
    public static final String SPEC_VERSION = "1.0.0";
    public static final List<String> CAPABILITIES = List.of(
            "phase1", "ingest.csv", "ingest.json", "ingest.jsonl", "sql.basic", "test.functions",
            "phase2", "sql.groupby", "sql.join", "sql.functions", "sql.subquery", "sql.cte", "sql.correlated_subquery",
            "phase3", "storage.pqcf", "storage.mmap", "index.hash", "index.btree",
            "phase4", "http.streaming",
            "phase5", "exec.row", "exec.vectorized", "exec.parallel", "join.hash", "join.merge", "join.nested_loop",
            "native.kernels");

    private Version() {
    }

    public static Map<String, Object> versionFields() {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("engine", ENGINE);
        m.put("engine_version", ENGINE_VERSION);
        m.put("language", "java");
        m.put("protocol_version", (long) PROTOCOL_VERSION);
        m.put("spec_version", SPEC_VERSION);
        m.put("runtime", System.getProperty("java.vm.name", "Java") + " " + Runtime.version());
        Map<String, Object> build = new LinkedHashMap<>();
        build.put("profile", "release");
        build.put("flags", "javac --release 27");
        m.put("build", build);
        return m;
    }

    public static Map<String, Object> capabilityFields() {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("protocol_version", (long) PROTOCOL_VERSION);
        m.put("capabilities", CAPABILITIES);
        return m;
    }
}
