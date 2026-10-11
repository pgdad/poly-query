package polyquery.storage.pqcf;

import java.io.BufferedOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.channels.Channels;
import java.nio.channels.FileChannel;
import java.nio.file.DirectoryStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;
import java.util.zip.CRC32;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.index.Index;
import polyquery.json.JsonWriter;
import polyquery.storage.ColumnCursor;
import polyquery.storage.ColumnSchema;
import polyquery.storage.Table;
import polyquery.types.DataType;
import polyquery.types.DateTimes;
import polyquery.types.Decimals;

/**
 * Writes a table as a PQCF v1 file (pqcf-v1.md) atomically: the file is written to a
 * temporary file in the target directory, fsynced, renamed over the target, and the
 * directory is fsynced (§5).
 */
public final class PqcfWriter {
    public static final int DEFAULT_ROW_GROUP_SIZE = 65_536;
    /** Highest format version read and written (PQCF v2: wide DECIMAL columns, CR-2 §7). */
    public static final int MAX_FORMAT_VERSION = 2;
    private static final AtomicLong COUNTER = new AtomicLong();

    private PqcfWriter() {
    }

    /**
     * Saves {@code table} to {@code target}.
     *
     * @param writer       value of the metadata {@code writer} key
     * @param rowGroupSize maximum rows per row group (≥ 1)
     * @return the size of the written file in bytes
     */
    public static long save(Table table, Path target, String writer, int rowGroupSize, SaveEncoding encoding) {
        Path dir = target.getParent();
        if (dir == null || !Files.isDirectory(dir)) {
            throw new PolyQueryException(ErrorCode.IO_ERROR, "target directory does not exist");
        }
        if (Files.isDirectory(target)) {
            throw new PolyQueryException(ErrorCode.IO_ERROR, "target path is a directory");
        }
        String tmpPrefix = "." + target.getFileName() + ".tmp-";
        removeStaleTemporaries(dir, tmpPrefix);
        Path tmp = dir.resolve(tmpPrefix + ProcessHandle.current().pid() + "-" + System.nanoTime() + "-"
                + COUNTER.incrementAndGet());
        try {
            long size;
            try (FileChannel ch = FileChannel.open(tmp, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE)) {
                OutputStream out = new BufferedOutputStream(Channels.newOutputStream(ch), 1 << 20);
                size = write(table, out, writer, rowGroupSize, encoding);
                out.flush();
                ch.force(true);
            }
            try {
                Files.move(tmp, target, StandardCopyOption.ATOMIC_MOVE);
            } catch (AtomicMoveNotSupportedException e) {
                Files.move(tmp, target, StandardCopyOption.REPLACE_EXISTING);
            }
            syncDirectory(dir);
            return size;
        } catch (IOException e) {
            throw PolyQueryException.of(ErrorCode.IO_ERROR, "cannot write file: %s", e.getMessage());
        } finally {
            try {
                Files.deleteIfExists(tmp);
            } catch (IOException ignored) {
                // best effort: readers ignore temporary files
            }
        }
    }

    /**
     * Deletes temporary files of earlier saves to the same target whose writing process no
     * longer exists (left behind by a crash). Temporaries of live processes are kept.
     */
    private static void removeStaleTemporaries(Path dir, String prefix) {
        try (DirectoryStream<Path> files = Files.newDirectoryStream(dir, p -> p.getFileName().toString().startsWith(prefix))) {
            for (Path f : files) {
                String rest = f.getFileName().toString().substring(prefix.length());
                int dash = rest.indexOf('-');
                long pid;
                try {
                    pid = Long.parseLong(dash < 0 ? rest : rest.substring(0, dash));
                } catch (NumberFormatException e) {
                    continue;
                }
                if (ProcessHandle.of(pid).isEmpty()) {
                    Files.deleteIfExists(f);
                }
            }
        } catch (IOException | RuntimeException e) {
            // best effort only
        }
    }

    private static void syncDirectory(Path dir) {
        try (FileChannel ch = FileChannel.open(dir, StandardOpenOption.READ)) {
            ch.force(true);
        } catch (IOException | UnsupportedOperationException e) {
            // not supported on every platform; the rename itself is atomic
        }
    }

    /** Streams the complete file; returns its size. */
    private static long write(Table table, OutputStream out, String writer, int rowGroupSize, SaveEncoding encoding)
            throws IOException {
        List<ColumnSchema> columns = table.columns();
        int rows = table.rowCount();
        int version = formatVersion(columns);
        out.write(PqcfReader.MAGIC);
        out.write(new byte[] {(byte) version, 0, 0, 0});
        long pos = PqcfReader.HEADER_SIZE;
        ColumnCursor[] cursors = new ColumnCursor[columns.size()];
        for (int c = 0; c < cursors.length; c++) {
            cursors[c] = new ColumnCursor(table.data(), c);
        }
        List<Object> groups = new ArrayList<>();
        for (int start = 0; start < rows; start += rowGroupSize) {
            int n = Math.min(rowGroupSize, rows - start);
            List<Object> chunks = new ArrayList<>();
            for (int c = 0; c < columns.size(); c++) {
                DataType type = columns.get(c).type();
                Object[] values = new Object[n];
                for (int i = 0; i < n; i++) {
                    values[i] = cursors[c].get(start + i);
                }
                ChunkEncoder.EncodedChunk chunk = ChunkEncoder.encode(type, values, encoding);
                int pad = (int) ((8 - (pos & 7)) & 7);
                out.write(new byte[pad]);
                pos += pad;
                out.write(chunk.bytes());
                CRC32 crc = new CRC32();
                crc.update(chunk.bytes());
                Map<String, Object> meta = new LinkedHashMap<>();
                meta.put("offset", pos);
                meta.put("length", (long) chunk.bytes().length);
                meta.put("crc32", crc.getValue());
                meta.put("encoding", chunk.encoding().name());
                meta.put("null_count", (long) chunk.nullCount());
                if (chunk.min() != null) {
                    meta.put("min", statistic(chunk.min(), type));
                    meta.put("max", statistic(chunk.max(), type));
                }
                chunks.add(meta);
                pos += chunk.bytes().length;
            }
            Map<String, Object> group = new LinkedHashMap<>();
            group.put("row_count", (long) n);
            group.put("chunks", chunks);
            groups.add(group);
        }
        byte[] meta = JsonWriter.write(metadata(table, writer, groups, version)).getBytes(StandardCharsets.UTF_8);
        out.write(meta);
        CRC32 crc = new CRC32();
        crc.update(meta);
        out.write(le32(meta.length));
        out.write(le32((int) crc.getValue()));
        out.write(PqcfReader.MAGIC);
        return pos + meta.length + PqcfReader.FOOTER_SIZE;
    }

    /**
     * Writer rule of CR-2 §7: a table with a wide DECIMAL column is written as v2, every other
     * table as v1 (readable by v1-only engines).
     */
    static int formatVersion(List<ColumnSchema> columns) {
        for (ColumnSchema c : columns) {
            if (c.type().isWideDecimal()) {
                return 2;
            }
        }
        return 1;
    }

    private static Map<String, Object> metadata(Table table, String writer, List<Object> groups, int version) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("format_version", (long) version);
        m.put("writer", writer);
        m.put("table", table.name());
        m.put("row_count", (long) table.rowCount());
        List<Object> cols = new ArrayList<>();
        for (ColumnSchema c : table.columns()) {
            Map<String, Object> e = new LinkedHashMap<>();
            e.put("name", c.name());
            e.put("type", c.type().toString());
            cols.add(e);
        }
        m.put("columns", cols);
        List<Object> indexes = new ArrayList<>();
        for (Index i : table.indexes()) {
            Map<String, Object> e = new LinkedHashMap<>();
            e.put("name", i.name());
            e.put("column", table.columns().get(i.column()).name());
            e.put("kind", i.kind().name());
            indexes.add(e);
        }
        m.put("indexes", indexes);
        m.put("row_groups", groups);
        return m;
    }

    /** A chunk min/max value serialized as in types.md §9. */
    private static Object statistic(Object v, DataType type) {
        return switch (type.kind()) {
            case DECIMAL -> Decimals.toString(v, type.scale());
            case DATE -> DateTimes.formatDate((Integer) v);
            case TIMESTAMP -> DateTimes.formatTimestamp((Long) v);
            default -> v;
        };
    }

    private static byte[] le32(int v) {
        return new byte[] {(byte) v, (byte) (v >>> 8), (byte) (v >>> 16), (byte) (v >>> 24)};
    }
}
