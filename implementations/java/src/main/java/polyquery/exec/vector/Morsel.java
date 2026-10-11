package polyquery.exec.vector;

import java.util.ArrayList;
import java.util.List;
import polyquery.index.KeyDomain;
import polyquery.physical.PhysicalPlan;
import polyquery.storage.Table;
import polyquery.storage.TableData;
import polyquery.types.DataType;

/**
 * A contiguous range of rows {@code [from, to)} within row group {@code group} of a table: the
 * unit of work of parallel scans. {@code index} is the morsel's position in scan order.
 */
record Morsel(int index, int group, int from, int to) {

    /**
     * The morsels of a table scan in scan order: every row group not excluded by the scan's
     * row-group filters, cut into pieces of at most {@code rows} rows.
     */
    static List<Morsel> of(PhysicalPlan.TableScan scan, int rows) {
        Table table = scan.table();
        TableData data = table.data();
        List<Morsel> out = new ArrayList<>();
        for (int g = 0; g < data.groupCount(); g++) {
            int size = data.groupSize(g);
            if (size == 0 || skip(scan, g)) {
                continue;
            }
            for (int from = 0; from < size; from += rows) {
                out.add(new Morsel(out.size(), g, from, Math.min(size, from + rows)));
            }
        }
        return out;
    }

    /** True if the chunk statistics prove that no row of group {@code g} satisfies a filter. */
    private static boolean skip(PhysicalPlan.TableScan scan, int g) {
        TableData data = scan.table().data();
        for (PhysicalPlan.ColumnFilter f : scan.skipFilters()) {
            Object[] bounds = data.chunkBounds(g, f.column());
            if (bounds == null) {
                continue;
            }
            DataType type = scan.table().columnType(f.column());
            if (!f.predicate().overlaps(KeyDomain.key(bounds[0], type), KeyDomain.key(bounds[1], type))) {
                return true;
            }
        }
        return false;
    }
}
