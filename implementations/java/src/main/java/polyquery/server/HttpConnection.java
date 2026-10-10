package polyquery.server;

import java.io.BufferedOutputStream;
import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;

/**
 * One HTTP/1.1 connection: request parsing (Content-Length and chunked bodies, size limit,
 * {@code Expect: 100-continue}), response writing (fixed-length and chunked), and detection of
 * a client disconnect while a request is being processed.
 */
final class HttpConnection implements Closeable {
    private static final int MAX_HEADER_BYTES = 64 * 1024;
    private static final int MAX_BUFFER = 1 << 20;
    private static final int READ_TIMEOUT_MS = 30_000;
    private static final byte[] CRLF = {'\r', '\n'};

    /** Thrown when a request cannot be read; carries the protocol error to answer with. */
    static final class BadRequest extends Exception {
        final PolyQueryException error;

        BadRequest(PolyQueryException error) {
            super(error.getMessage(), null, false, false);
            this.error = error;
        }
    }

    private final Socket socket;
    private final InputStream in;
    private final OutputStream out;
    private byte[] buf = new byte[16 * 1024];
    private int pos;
    private int lim;

    HttpConnection(Socket socket) throws IOException {
        this.socket = socket;
        socket.setTcpNoDelay(true);
        this.in = socket.getInputStream();
        this.out = new BufferedOutputStream(socket.getOutputStream(), 64 * 1024);
    }

    // ---------------------------------------------------------------- input

    /**
     * Reads more bytes into the buffer, waiting at most {@code timeoutMs}: returns the number
     * of bytes read, 0 on timeout, -1 at end of stream.
     */
    private int fill(int timeoutMs) throws IOException {
        if (pos == lim) {
            pos = 0;
            lim = 0;
        } else if (lim == buf.length) {
            if (pos > 0) {
                System.arraycopy(buf, pos, buf, 0, lim - pos);
                lim -= pos;
                pos = 0;
            } else if (buf.length < MAX_BUFFER) {
                buf = Arrays.copyOf(buf, buf.length * 2);
            } else {
                sleep(timeoutMs);
                return 0;
            }
        }
        socket.setSoTimeout(Math.max(1, timeoutMs));
        try {
            int n = in.read(buf, lim, buf.length - lim);
            if (n < 0) {
                return -1;
            }
            lim += n;
            return n;
        } catch (SocketTimeoutException e) {
            return 0;
        }
    }

    private static void sleep(int ms) {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    /**
     * Checks for a client disconnect, waiting at most {@code timeoutMs} for input. Bytes of a
     * pipelined next request are buffered.
     */
    boolean peerClosed(int timeoutMs) {
        try {
            return fill(timeoutMs) < 0;
        } catch (IOException e) {
            return true;
        }
    }

    /**
     * Reads the next request; null when the client closed the connection (or stayed idle for
     * {@code idleTimeoutMs}) between requests.
     */
    HttpRequest readRequest(int idleTimeoutMs, long maxBodyBytes) throws IOException, BadRequest {
        while (pos == lim || (lim - pos <= 2 && isBlankLine())) {
            if (pos < lim) {
                pos = lim; // tolerate stray CRLF between requests
            }
            int n = fill(idleTimeoutMs);
            if (n <= 0) {
                return null;
            }
        }
        int[] headerBytes = {0};
        String requestLine = readLine(headerBytes);
        String[] parts = requestLine.split(" ");
        if (parts.length != 3 || !parts[2].startsWith("HTTP/1.")) {
            throw bad("malformed request line");
        }
        String method = parts[0];
        String target = parts[1];
        boolean http10 = parts[2].equals("HTTP/1.0");
        Map<String, String> headers = new HashMap<>();
        while (true) {
            String line = readLine(headerBytes);
            if (line.isEmpty()) {
                break;
            }
            int colon = line.indexOf(':');
            if (colon <= 0) {
                throw bad("malformed header line");
            }
            String name = line.substring(0, colon).trim().toLowerCase(Locale.ROOT);
            String value = line.substring(colon + 1).trim();
            headers.merge(name, value, (a, b) -> a + ", " + b);
        }
        String connection = headers.getOrDefault("connection", "").toLowerCase(Locale.ROOT);
        boolean keepAlive = http10 ? connection.contains("keep-alive") : !connection.contains("close");
        byte[] body = readBody(headers, maxBodyBytes);
        int q = target.indexOf('?');
        String rawPath = q < 0 ? target : target.substring(0, q);
        return new HttpRequest(method, target, splitPath(rawPath), parseQuery(q < 0 ? "" : target.substring(q + 1)),
                headers, body, keepAlive);
    }

    private boolean isBlankLine() {
        for (int i = pos; i < lim; i++) {
            if (buf[i] != '\r' && buf[i] != '\n') {
                return false;
            }
        }
        return true;
    }

    private static BadRequest bad(String message) {
        return new BadRequest(new PolyQueryException(ErrorCode.INVALID_REQUEST, message));
    }

    /** One header line (CRLF or LF terminated) as ISO-8859-1 text. */
    private String readLine(int[] total) throws IOException, BadRequest {
        int scanned = pos;
        while (true) {
            for (int i = scanned; i < lim; i++) {
                if (buf[i] == '\n') {
                    int end = i > pos && buf[i - 1] == '\r' ? i - 1 : i;
                    String line = new String(buf, pos, end - pos, StandardCharsets.ISO_8859_1);
                    total[0] += i + 1 - pos;
                    pos = i + 1;
                    return line;
                }
            }
            scanned = lim;
            if (total[0] + (lim - pos) > MAX_HEADER_BYTES) {
                throw bad("request header too large");
            }
            int before = pos;
            int n = fill(READ_TIMEOUT_MS);
            scanned -= before - pos; // the buffer may have been compacted
            if (n <= 0) {
                throw new IOException("connection closed while reading the request header");
            }
        }
    }

    private byte[] readBody(Map<String, String> headers, long maxBodyBytes) throws IOException, BadRequest {
        String te = headers.get("transfer-encoding");
        String cl = headers.get("content-length");
        boolean chunked = te != null && te.toLowerCase(Locale.ROOT).contains("chunked");
        long length = 0;
        if (!chunked && cl != null) {
            try {
                length = Long.parseLong(cl.trim());
            } catch (NumberFormatException e) {
                throw bad("invalid Content-Length");
            }
            if (length < 0) {
                throw bad("invalid Content-Length");
            }
            if (length > maxBodyBytes || length > Integer.MAX_VALUE - 16) {
                throw tooLarge(maxBodyBytes);
            }
        }
        if ((chunked || length > 0) && "100-continue".equalsIgnoreCase(headers.getOrDefault("expect", ""))) {
            out.write("HTTP/1.1 100 Continue\r\n\r\n".getBytes(StandardCharsets.ISO_8859_1));
            out.flush();
        }
        if (chunked) {
            return readChunked(maxBodyBytes);
        }
        byte[] body = new byte[(int) length];
        readFully(body, 0, body.length);
        return body;
    }

    private static BadRequest tooLarge(long max) {
        return new BadRequest(PolyQueryException.of(ErrorCode.RESOURCE_LIMIT,
                "request body exceeds the limit of %d bytes", max));
    }

    private void readFully(byte[] dst, int off, int len) throws IOException {
        int done = 0;
        int buffered = Math.min(len, lim - pos);
        System.arraycopy(buf, pos, dst, off, buffered);
        pos += buffered;
        done += buffered;
        if (done < len) {
            socket.setSoTimeout(READ_TIMEOUT_MS);
            while (done < len) {
                int n = in.read(dst, off + done, len - done);
                if (n < 0) {
                    throw new IOException("connection closed while reading the request body");
                }
                done += n;
            }
        }
    }

    private byte[] readChunked(long maxBodyBytes) throws IOException, BadRequest {
        ByteArrayOutputStream body = new ByteArrayOutputStream();
        int[] total = {0};
        while (true) {
            String sizeLine = readLine(total);
            int semi = sizeLine.indexOf(';');
            long size;
            try {
                size = Long.parseLong((semi < 0 ? sizeLine : sizeLine.substring(0, semi)).trim(), 16);
            } catch (NumberFormatException e) {
                throw bad("invalid chunk size");
            }
            if (size < 0) {
                throw bad("invalid chunk size");
            }
            if (size == 0) {
                while (!readLine(total).isEmpty()) {
                    // skip trailers
                }
                return body.toByteArray();
            }
            if (body.size() + size > maxBodyBytes || body.size() + size > Integer.MAX_VALUE - 16) {
                throw tooLarge(maxBodyBytes);
            }
            byte[] chunk = new byte[(int) size];
            readFully(chunk, 0, chunk.length);
            body.write(chunk);
            readLine(total);
            total[0] = 0;
        }
    }

    private static List<String> splitPath(String rawPath) throws BadRequest {
        List<String> out = new ArrayList<>();
        for (String seg : rawPath.split("/")) {
            if (!seg.isEmpty()) {
                out.add(percentDecode(seg));
            }
        }
        return out;
    }

    private static String percentDecode(String s) throws BadRequest {
        if (s.indexOf('%') < 0) {
            return s;
        }
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '%') {
                if (i + 2 >= s.length()) {
                    throw bad("malformed percent-encoding in path");
                }
                int hi = Character.digit(s.charAt(i + 1), 16);
                int lo = Character.digit(s.charAt(i + 2), 16);
                if (hi < 0 || lo < 0) {
                    throw bad("malformed percent-encoding in path");
                }
                bytes.write(hi * 16 + lo);
                i += 2;
            } else {
                byte[] b = String.valueOf(c).getBytes(StandardCharsets.UTF_8);
                bytes.write(b, 0, b.length);
            }
        }
        return bytes.toString(StandardCharsets.UTF_8);
    }

    private static Map<String, String> parseQuery(String query) throws BadRequest {
        Map<String, String> out = new HashMap<>();
        for (String pair : query.split("&")) {
            if (pair.isEmpty()) {
                continue;
            }
            int eq = pair.indexOf('=');
            try {
                String k = URLDecoder.decode(eq < 0 ? pair : pair.substring(0, eq), StandardCharsets.UTF_8);
                String v = eq < 0 ? "" : URLDecoder.decode(pair.substring(eq + 1), StandardCharsets.UTF_8);
                out.put(k, v);
            } catch (IllegalArgumentException e) {
                throw bad("malformed query string");
            }
        }
        return out;
    }

    // ---------------------------------------------------------------- output

    private void writeHead(int status, String contentType, Map<String, String> headers, boolean keepAlive,
                           long contentLength) throws IOException {
        StringBuilder sb = new StringBuilder(256);
        sb.append("HTTP/1.1 ").append(status).append(' ').append(reason(status)).append("\r\n");
        if (contentType != null) {
            sb.append("Content-Type: ").append(contentType).append("\r\n");
        }
        if (contentLength >= 0) {
            sb.append("Content-Length: ").append(contentLength).append("\r\n");
        } else {
            sb.append("Transfer-Encoding: chunked\r\n");
        }
        for (Map.Entry<String, String> h : headers.entrySet()) {
            sb.append(h.getKey()).append(": ").append(h.getValue()).append("\r\n");
        }
        sb.append("Connection: ").append(keepAlive ? "keep-alive" : "close").append("\r\n\r\n");
        out.write(sb.toString().getBytes(StandardCharsets.ISO_8859_1));
    }

    /** Writes a complete fixed-length response. */
    void writeResponse(int status, String contentType, byte[] body, Map<String, String> headers, boolean keepAlive)
            throws IOException {
        writeHead(status, contentType, headers, keepAlive, body.length);
        out.write(body);
        out.flush();
    }

    /** Starts a chunked response; follow with {@link #writeChunk} and {@link #endChunks}. */
    void startChunked(int status, String contentType, Map<String, String> headers, boolean keepAlive)
            throws IOException {
        writeHead(status, contentType, headers, keepAlive, -1);
    }

    void writeChunk(byte[] data) throws IOException {
        if (data.length == 0) {
            return;
        }
        out.write(Integer.toHexString(data.length).getBytes(StandardCharsets.ISO_8859_1));
        out.write(CRLF);
        out.write(data);
        out.write(CRLF);
        out.flush();
    }

    void endChunks() throws IOException {
        out.write("0\r\n\r\n".getBytes(StandardCharsets.ISO_8859_1));
        out.flush();
    }

    /**
     * Closes after a response that was sent while request bytes may remain unread: half-closes
     * the output and drains input briefly so that the client sees the response instead of a reset.
     */
    void closeGracefully() {
        try {
            out.flush();
            socket.shutdownOutput();
            socket.setSoTimeout(200);
            byte[] sink = new byte[8192];
            long deadline = System.nanoTime() + 1_000_000_000L;
            while (System.nanoTime() < deadline && in.read(sink) >= 0) {
                // discard
            }
        } catch (IOException e) {
            // the connection is being closed anyway
        }
        close();
    }

    @Override
    public void close() {
        try {
            socket.close();
        } catch (IOException e) {
            // ignore
        }
    }

    private static String reason(int status) {
        return switch (status) {
            case 100 -> "Continue";
            case 200 -> "OK";
            case 201 -> "Created";
            case 400 -> "Bad Request";
            case 403 -> "Forbidden";
            case 404 -> "Not Found";
            case 405 -> "Method Not Allowed";
            case 409 -> "Conflict";
            case 413 -> "Payload Too Large";
            case 500 -> "Internal Server Error";
            case 503 -> "Service Unavailable";
            case 504 -> "Gateway Timeout";
            default -> "Status";
        };
    }
}
