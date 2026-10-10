package polyquery.storage.pqcf;

import java.io.IOException;
import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.channels.FileChannel;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.AccessDeniedException;
import java.nio.file.Files;
import java.nio.file.NoSuchFileException;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.zip.CRC32;
import polyquery.common.ErrorCode;
import polyquery.common.Names;
import polyquery.common.PolyQueryException;
import polyquery.index.IndexKind;
import polyquery.json.JsonException;
import polyquery.json.JsonNumber;
import polyquery.json.JsonParser;
import polyquery.storage.ColumnSchema;
import polyquery.storage.TableData;
import polyquery.types.DataType;
import polyquery.types.DateTimes;
import polyquery.types.TextParsers;

/**
 * Opens PQCF v1 files (pqcf-v1.md). Header, footer, metadata checksum and structure are
 * validated at open; chunk checksums and values are validated when chunks are decoded
 * (immediately for buffered reads, on first access for memory-mapped files).
 */
public final class PqcfReader {
    static final byte[] MAGIC = {'P', 'Q', 'C', 'F'};
    static final int HEADER_SIZE = 8;
    static final int FOOTER_SIZE = 12;
    private static final ValueLayout.OfInt U32 = ValueLayout.JAVA_INT_UNALIGNED.withOrder(ByteOrder.LITTLE_ENDIAN);
    private static final ValueLayout.OfShort U16 = ValueLayout.JAVA_SHORT_UNALIGNED.withOrder(ByteOrder.LITTLE_ENDIAN);

    /** An opened file: its data plus the index definitions recorded in it. */
    public record OpenedFile(List<ColumnSchema> columns, TableData data, List<IndexDefinition> indexes) {
    }

    /** An index recorded in the file metadata. */
    public record IndexDefinition(String name, int column, IndexKind kind) {
    }

    private PqcfReader() {
    }

    static PolyQueryException corrupt(String message) {
        return new PolyQueryException(ErrorCode.STORAGE_CORRUPT, "corrupt PQCF file: " + message);
    }

    private static PolyQueryException unsupported(String message) {
        return new PolyQueryException(ErrorCode.STORAGE_VERSION_UNSUPPORTED, message);
    }

    /**
     * Opens and validates a file.
     *
     * @param mmap    memory-map the file and decode chunks lazily
     * @param maxRows RESOURCE_LIMIT if the file holds more rows
     */
    public static OpenedFile open(Path path, boolean mmap, long maxRows) {
        MemorySegment file = load(path, mmap);
        FileMeta meta = readMeta(file);
        if (meta.rowCount() > maxRows) {
            throw new PolyQueryException(ErrorCode.RESOURCE_LIMIT, "file exceeds the table row limit");
        }
        PqcfTableData data = new PqcfTableData(meta, file);
        if (!mmap) {
            data.decodeAll();
        }
        List<IndexDefinition> indexes = new ArrayList<>();
        for (FileMeta.IndexMeta i : meta.indexes()) {
            indexes.add(new IndexDefinition(i.name(), i.column(), i.kind()));
        }
        return new OpenedFile(meta.columns(), data, indexes);
    }

    private static MemorySegment load(Path path, boolean mmap) {
        try {
            if (Files.isDirectory(path)) {
                throw new PolyQueryException(ErrorCode.IO_ERROR, "path is a directory");
            }
            try (FileChannel ch = FileChannel.open(path, StandardOpenOption.READ)) {
                long size = ch.size();
                if (mmap || size > Integer.MAX_VALUE - 64) {
                    return size == 0 ? MemorySegment.ofArray(new byte[0])
                            : ch.map(FileChannel.MapMode.READ_ONLY, 0, size, Arena.ofAuto());
                }
                ByteBuffer buf = ByteBuffer.allocate((int) size);
                while (buf.hasRemaining() && ch.read(buf) >= 0) {
                    // keep reading until full or EOF
                }
                buf.flip();
                byte[] bytes = new byte[buf.remaining()];
                buf.get(bytes);
                return MemorySegment.ofArray(bytes);
            }
        } catch (NoSuchFileException e) {
            throw PolyQueryException.of(ErrorCode.NOT_FOUND, "file not found");
        } catch (AccessDeniedException e) {
            throw PolyQueryException.of(ErrorCode.IO_ERROR, "permission denied reading file");
        } catch (IOException e) {
            throw PolyQueryException.of(ErrorCode.IO_ERROR, "cannot read file: %s", e.getMessage());
        }
    }

    // ---------------------------------------------------------------- header, footer, metadata

    private static FileMeta readMeta(MemorySegment file) {
        long size = file.byteSize();
        if (size < HEADER_SIZE || !hasMagic(file, 0)) {
            throw corrupt("bad header magic");
        }
        int version = Short.toUnsignedInt(file.get(U16, 4));
        int flags = Short.toUnsignedInt(file.get(U16, 6));
        if (version == 0) {
            throw corrupt("format version 0");
        }
        if (version > 1) {
            throw unsupported("PQCF format version " + version + " is not supported");
        }
        if (flags != 0) {
            throw unsupported("PQCF header flags " + flags + " are not supported");
        }
        if (size < HEADER_SIZE + FOOTER_SIZE || !hasMagic(file, size - 4)) {
            throw corrupt("bad trailer magic (truncated file?)");
        }
        long m = Integer.toUnsignedLong(file.get(U32, size - 12));
        long crc = Integer.toUnsignedLong(file.get(U32, size - 8));
        long metaStart = size - FOOTER_SIZE - m;
        if (metaStart < HEADER_SIZE) {
            throw corrupt("metadata length out of range");
        }
        byte[] metaBytes = file.asSlice(metaStart, m).toArray(ValueLayout.JAVA_BYTE);
        CRC32 c = new CRC32();
        c.update(metaBytes);
        if (c.getValue() != crc) {
            throw corrupt("metadata checksum mismatch");
        }
        String text;
        try {
            text = StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(metaBytes)).toString();
        } catch (CharacterCodingException e) {
            throw corrupt("metadata is not valid UTF-8");
        }
        Object json;
        try {
            json = JsonParser.parse(text);
        } catch (JsonException | StackOverflowError e) {
            throw corrupt("metadata is not valid JSON");
        }
        if (!(json instanceof Map<?, ?> root)) {
            throw corrupt("metadata is not a JSON object");
        }
        FileMeta meta = parseMeta(root, metaStart);
        checkPadding(file, meta, metaStart);
        return meta;
    }

    /**
     * Bytes between the header and the metadata that belong to no chunk may only be zero
     * padding (§1). Checking them means a damaged padding byte cannot go unnoticed.
     */
    private static void checkPadding(MemorySegment file, FileMeta meta, long metaStart) {
        List<long[]> ranges = new ArrayList<>();
        for (FileMeta.GroupMeta g : meta.groups()) {
            for (FileMeta.ChunkMeta c : g.chunks()) {
                ranges.add(new long[] {c.offset(), c.offset() + c.length()});
            }
        }
        ranges.sort((a, b) -> Long.compare(a[0], b[0]));
        long pos = HEADER_SIZE;
        for (long[] r : ranges) {
            checkZero(file, pos, r[0]);
            pos = Math.max(pos, r[1]);
        }
        checkZero(file, pos, metaStart);
    }

    private static void checkZero(MemorySegment file, long from, long to) {
        for (long i = from; i < to; i++) {
            if (file.get(ValueLayout.JAVA_BYTE, i) != 0) {
                throw corrupt("non-zero bytes outside column chunks");
            }
        }
    }

    private static boolean hasMagic(MemorySegment file, long offset) {
        for (int i = 0; i < 4; i++) {
            if (file.get(ValueLayout.JAVA_BYTE, offset + i) != MAGIC[i]) {
                return false;
            }
        }
        return true;
    }

    private static FileMeta parseMeta(Map<?, ?> root, long metaStart) {
        if (integer(root, "format_version", 0, Long.MAX_VALUE) != 1) {
            throw corrupt("metadata format_version does not match the header");
        }
        if (!(root.get("table") instanceof String table)) {
            throw corrupt("missing table name");
        }
        long rowCount = integer(root, "row_count", 0, Integer.MAX_VALUE);
        List<ColumnSchema> columns = parseColumns(array(root, "columns"));
        List<FileMeta.IndexMeta> indexes = root.get("indexes") == null ? List.of()
                : parseIndexes(array(root, "indexes"), columns);
        List<FileMeta.GroupMeta> groups = new ArrayList<>();
        long total = 0;
        for (Object g : array(root, "row_groups")) {
            FileMeta.GroupMeta group = parseGroup(g, columns, metaStart);
            total += group.rowCount();
            groups.add(group);
        }
        if (total != rowCount) {
            throw corrupt("row_count does not equal the sum of the row groups");
        }
        return new FileMeta(table, (int) rowCount, columns, indexes, groups);
    }

    private static List<ColumnSchema> parseColumns(List<?> list) {
        List<ColumnSchema> out = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        for (Object o : list) {
            if (!(o instanceof Map<?, ?> col) || !(col.get("name") instanceof String name)
                    || !(col.get("type") instanceof String typeName)) {
                throw corrupt("invalid column entry");
            }
            if (name.isEmpty() || !seen.add(Names.key(name))) {
                throw corrupt("empty or duplicate column name");
            }
            DataType type;
            try {
                type = DataType.parse(typeName);
            } catch (IllegalArgumentException | PolyQueryException e) {
                throw corrupt("invalid column type '" + typeName + "'");
            }
            out.add(new ColumnSchema(name, type));
        }
        return out;
    }

    private static List<FileMeta.IndexMeta> parseIndexes(List<?> list, List<ColumnSchema> columns) {
        List<FileMeta.IndexMeta> out = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        for (Object o : list) {
            if (!(o instanceof Map<?, ?> idx) || !(idx.get("name") instanceof String name)
                    || !(idx.get("column") instanceof String column) || !(idx.get("kind") instanceof String kind)) {
                throw corrupt("invalid index entry");
            }
            if (name.isEmpty() || !seen.add(Names.key(name))) {
                throw corrupt("empty or duplicate index name");
            }
            int col = -1;
            for (int i = 0; i < columns.size(); i++) {
                if (Names.equal(columns.get(i).name(), column)) {
                    col = i;
                }
            }
            if (col < 0) {
                throw corrupt("index '" + name + "' references an unknown column");
            }
            IndexKind k = switch (kind) {
                case "HASH" -> IndexKind.HASH;
                case "BTREE" -> IndexKind.BTREE;
                default -> throw corrupt("unknown index kind '" + kind + "'");
            };
            out.add(new FileMeta.IndexMeta(name, col, k));
        }
        return out;
    }

    private static FileMeta.GroupMeta parseGroup(Object o, List<ColumnSchema> columns, long metaStart) {
        if (!(o instanceof Map<?, ?> group)) {
            throw corrupt("invalid row group entry");
        }
        int rows = (int) integer(group, "row_count", 0, Integer.MAX_VALUE);
        List<?> chunks = array(group, "chunks");
        if (chunks.size() != columns.size()) {
            throw corrupt("row group does not have one chunk per column");
        }
        List<FileMeta.ChunkMeta> out = new ArrayList<>();
        for (int c = 0; c < chunks.size(); c++) {
            if (!(chunks.get(c) instanceof Map<?, ?> chunk)) {
                throw corrupt("invalid chunk entry");
            }
            DataType type = columns.get(c).type();
            long offset = integer(chunk, "offset", 0, Long.MAX_VALUE);
            long length = integer(chunk, "length", 0, Integer.MAX_VALUE);
            if (offset < HEADER_SIZE || offset + length > metaStart) {
                throw corrupt("chunk byte range out of bounds");
            }
            long crc = integer(chunk, "crc32", 0, 0xFFFF_FFFFL);
            if (!(chunk.get("encoding") instanceof String encName)) {
                throw corrupt("missing chunk encoding");
            }
            Encoding encoding = Encoding.fromName(encName);
            if (encoding == null) {
                throw unsupported("unknown PQCF encoding '" + encName + "'");
            }
            if (!encoding.appliesTo(type)) {
                throw corrupt("encoding " + encName + " is not valid for " + type);
            }
            int nulls = (int) integer(chunk, "null_count", 0, rows);
            out.add(new FileMeta.ChunkMeta(offset, (int) length, crc, encoding, nulls,
                    statistic(chunk.get("min"), type), statistic(chunk.get("max"), type)));
        }
        return new FileMeta.GroupMeta(rows, out);
    }

    // ---------------------------------------------------------------- JSON helpers

    private static long integer(Map<?, ?> m, String key, long min, long max) {
        if (!(m.get(key) instanceof JsonNumber n) || !n.isIntegerLiteral()) {
            throw corrupt("missing or non-integer '" + key + "'");
        }
        long v;
        try {
            v = Long.parseLong(n.text());
        } catch (NumberFormatException e) {
            throw corrupt("'" + key + "' out of range");
        }
        if (v < min || v > max) {
            throw corrupt("'" + key + "' out of range");
        }
        return v;
    }

    private static List<?> array(Map<?, ?> m, String key) {
        if (!(m.get(key) instanceof List<?> list)) {
            throw corrupt("missing or invalid '" + key + "'");
        }
        return list;
    }

    /** A chunk min/max statistic as a runtime value; null if absent or not understood. */
    private static Object statistic(Object v, DataType type) {
        if (v == null) {
            return null;
        }
        try {
            return switch (type.kind()) {
                case BOOLEAN -> v instanceof Boolean b ? b : null;
                case INT64 -> v instanceof JsonNumber n && n.isIntegerLiteral() ? Long.parseLong(n.text()) : null;
                case FLOAT64 -> {
                    if (!(v instanceof JsonNumber n)) {
                        yield null;
                    }
                    double d = n.doubleValue();
                    yield Double.isFinite(d) ? (d == 0.0 ? 0.0 : d) : null;
                }
                case DECIMAL -> v instanceof String s
                        ? TextParsers.parseDecimal(s, type.precision(), type.scale(), false) : null;
                case DATE -> v instanceof String s ? DateTimes.parseDate(s) : null;
                case TIMESTAMP -> v instanceof String s ? DateTimes.parseTimestamp(s, false) : null;
                case STRING -> v instanceof String s ? s : null;
                case NULL -> null;
            };
        } catch (RuntimeException e) {
            return null;
        }
    }
}
