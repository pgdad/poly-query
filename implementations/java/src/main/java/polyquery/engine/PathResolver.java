package polyquery.engine;

import java.nio.file.Path;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;

/** Resolves request paths strictly inside the data directory (protocol.md §6). */
public final class PathResolver {
    private final Path root;

    public PathResolver(Path root) {
        this.root = root.toAbsolutePath().normalize();
    }

    public Path resolve(String path) {
        if (path.isEmpty() || path.indexOf('\0') >= 0) {
            throw denied(path);
        }
        if (path.startsWith("/") || path.startsWith("\\") || (path.length() > 1 && path.charAt(1) == ':')) {
            throw denied(path);
        }
        for (String part : path.split("[/\\\\]")) {
            if (part.equals("..")) {
                throw denied(path);
            }
        }
        Path p;
        try {
            p = root.resolve(path).normalize();
        } catch (RuntimeException e) {
            throw denied(path);
        }
        if (!p.startsWith(root) || p.isAbsolute() && !p.startsWith(root)) {
            throw denied(path);
        }
        return p;
    }

    private static PolyQueryException denied(String path) {
        return PolyQueryException.of(ErrorCode.ACCESS_DENIED, "path '%s' is not permitted",
                path.replace("\0", "\\0"));
    }
}
