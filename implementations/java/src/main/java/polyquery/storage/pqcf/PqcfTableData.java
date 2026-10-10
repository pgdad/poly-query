package polyquery.storage.pqcf;

import java.lang.foreign.MemorySegment;
import java.util.List;
import java.util.concurrent.atomic.AtomicReferenceArray;
import polyquery.storage.ColumnSchema;
import polyquery.storage.ColumnVector;
import polyquery.storage.Layout;
import polyquery.storage.TableData;

/**
 * Column-oriented table data backed by a PQCF file. Row groups and chunk statistics are kept
 * from the file so scans can skip row groups. Chunks are decoded (and their CRC verified) on
 * first access when the file is memory-mapped, or all at open time otherwise.
 */
final class PqcfTableData implements TableData {
    private final FileMeta meta;
    private final List<ColumnSchema> schema;
    private final int[] starts;
    private final AtomicReferenceArray<ColumnVector> chunks;
    private final int width;
    private volatile MemorySegment file;

    PqcfTableData(FileMeta meta, MemorySegment file) {
        this.meta = meta;
        this.schema = meta.columns();
        this.width = schema.size();
        this.file = file;
        this.starts = new int[meta.groups().size()];
        int row = 0;
        for (int g = 0; g < starts.length; g++) {
            starts[g] = row;
            row += meta.groups().get(g).rowCount();
        }
        this.chunks = new AtomicReferenceArray<>(starts.length * width);
    }

    /** Decodes every chunk now and drops the reference to the file bytes. */
    void decodeAll() {
        for (int g = 0; g < starts.length; g++) {
            for (int c = 0; c < width; c++) {
                chunk(g, c);
            }
        }
        file = null;
    }

    @Override
    public Layout layout() {
        return Layout.COLUMN;
    }

    @Override
    public int rowCount() {
        return meta.rowCount();
    }

    @Override
    public int groupCount() {
        return starts.length;
    }

    @Override
    public int groupStart(int group) {
        return starts[group];
    }

    @Override
    public int groupSize(int group) {
        return meta.groups().get(group).rowCount();
    }

    @Override
    public ColumnVector chunk(int group, int column) {
        int slot = group * width + column;
        ColumnVector v = chunks.get(slot);
        if (v == null) {
            v = ChunkDecoder.decode(file, meta.groups().get(group).chunks().get(column), schema.get(column).type(),
                    groupSize(group));
            chunks.compareAndSet(slot, null, v);
        }
        return v;
    }

    @Override
    public Object[] chunkBounds(int group, int column) {
        FileMeta.ChunkMeta c = meta.groups().get(group).chunks().get(column);
        return c.min() == null || c.max() == null ? null : new Object[] {c.min(), c.max()};
    }

    @Override
    public long estimatedBytes() {
        long total = 0;
        for (int i = 0; i < chunks.length(); i++) {
            ColumnVector v = chunks.get(i);
            if (v != null) {
                total += v.estimatedBytes();
            }
        }
        return total;
    }
}
