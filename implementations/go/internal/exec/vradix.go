package exec

import (
	"math/bits"
	"slices"
	"sync"
	"sync/atomic"
)

// Radix sorting of sort items. Full sorts order their items by the
// normalized first key with a stable radix sort — one parallel MSD pass on
// the most significant byte that varies, then an LSD sort of every bucket
// (buckets are distributed over the workers) on the lower bytes that vary —
// and finally sort every run of equal normalized keys with the full
// comparator (remaining keys, string suffixes, NULLs, input position). The
// radix passes touch every item a few times sequentially instead of
// running O(n log n) comparisons through the comparator.

// minRadixParallel is the input size from which radix passes use several
// goroutines.
const minRadixParallel = 1 << 14

// smallBucket is the bucket size up to which the LSD phase uses insertion
// sort.
const smallBucket = 48

// radixSortItems sorts items by key, stably (items with equal keys keep
// their order). It returns the sorted items, which may be a new slice.
func radixSortItems(ec *Context, a []sortItem, threads int) ([]sortItem, error) {
	n := len(a)
	if n < 2 {
		return a, nil
	}
	var diff uint64
	k0 := a[0].key
	for i := range a {
		diff |= a[i].key ^ k0
	}
	if diff == 0 {
		return a, nil
	}
	top := uint((63 - bits.LeadingZeros64(diff)) / 8 * 8)
	workers := 1
	if threads > 1 && n >= minRadixParallel {
		workers = min(threads, n/(minRadixParallel/4))
	}

	// MSD pass: per-worker histograms of contiguous chunks, then a stable
	// scatter into tmp.
	tmp := make([]sortItem, n)
	bounds := make([]int, workers+1)
	for w := range bounds {
		bounds[w] = n * w / workers
	}
	hists := make([][256]int, workers)
	parallelDo(workers, func(w int) {
		h := &hists[w]
		for _, it := range a[bounds[w]:bounds[w+1]] {
			h[byte(it.key>>top)]++
		}
	})
	var starts [257]int
	pos := 0
	for b := 0; b < 256; b++ {
		starts[b] = pos
		for w := range hists {
			c := hists[w][b]
			hists[w][b] = pos
			pos += c
		}
	}
	starts[256] = n
	parallelDo(workers, func(w int) {
		off := &hists[w]
		for _, it := range a[bounds[w]:bounds[w+1]] {
			b := byte(it.key >> top)
			tmp[off[b]] = it
			off[b]++
		}
	})
	if top == 0 {
		return tmp, nil
	}

	// LSD passes per bucket over the lower bytes that vary anywhere.
	var shifts []uint
	for s := uint(0); s < top; s += 8 {
		if byte(diff>>s) != 0 {
			shifts = append(shifts, s)
		}
	}
	var next atomic.Int32
	var failed atomic.Bool
	errs := make([]error, workers)
	parallelDo(workers, func(w int) {
		var hists [8][256]int
		for {
			b := int(next.Add(1)) - 1
			if b >= 256 || failed.Load() {
				return
			}
			lo, hi := starts[b], starts[b+1]
			if hi-lo < 2 {
				continue
			}
			if err := ec.Check(); err != nil {
				errs[w] = err
				failed.Store(true)
				return
			}
			lsdSort(tmp[lo:hi], a[lo:hi], shifts, &hists)
		}
	})
	for _, err := range errs {
		if err != nil {
			return nil, err
		}
	}
	return tmp, nil
}

// lsdSort sorts src stably by the key bytes at shifts (ascending), using
// buf (same length) as scratch; the result is in src. The histograms of
// all bytes are counted in one pass (a permutation does not change them).
func lsdSort(src, buf []sortItem, shifts []uint, hists *[8][256]int) {
	n := len(src)
	if n <= smallBucket {
		insertionSortItems(src)
		return
	}
	for p := range shifts {
		clear(hists[p][:])
	}
	for _, it := range src {
		for p, s := range shifts {
			hists[p][byte(it.key>>s)]++
		}
	}
	in, out := src, buf
	for p, s := range shifts {
		hist := &hists[p]
		if hist[byte(in[0].key>>s)] == n {
			continue // byte constant within this bucket
		}
		pos := 0
		for b := range hist {
			c := hist[b]
			hist[b] = pos
			pos += c
		}
		for _, it := range in {
			b := byte(it.key >> s)
			out[hist[b]] = it
			hist[b]++
		}
		in, out = out, in
	}
	if &in[0] != &src[0] {
		copy(src, in)
	}
}

// insertionSortItems sorts a few items stably by key.
func insertionSortItems(a []sortItem) {
	for i := 1; i < len(a); i++ {
		it := a[i]
		j := i
		for j > 0 && a[j-1].key > it.key {
			a[j] = a[j-1]
			j--
		}
		a[j] = it
	}
}

// parallelDo runs f(0..workers-1) concurrently and waits for all.
func parallelDo(workers int, f func(w int)) {
	if workers == 1 {
		f(0)
		return
	}
	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			f(w)
		}()
	}
	wg.Wait()
}

// parallelChunks calls f for contiguous chunks of 0..n-1, with up to
// threads goroutines for large n.
func parallelChunks(n, threads int, f func(lo, hi int)) {
	workers := 1
	if threads > 1 && n >= minRadixParallel {
		workers = min(threads, n/(minRadixParallel/4))
	}
	parallelDo(workers, func(w int) { f(n*w/workers, n*(w+1)/workers) })
}

// sortTies orders every run of items with equal normalized first keys
// (sorted by the radix sort, equal ones in input order) by the remaining
// sort keys; runs are distributed over the workers.
func sortTies(ec *Context, a []sortItem, c *colComparator, threads int) error {
	n := len(a)
	workers := 1
	if threads > 1 && n >= minRadixParallel {
		workers = min(threads, n/(minRadixParallel/4))
	}
	// Chunk boundaries are moved forward to run boundaries.
	bounds := make([]int, workers+1)
	for w := 1; w < workers; w++ {
		b := max(n*w/workers, bounds[w-1])
		for b > 0 && b < n && a[b].key == a[b-1].key {
			b++
		}
		bounds[w] = b
	}
	bounds[workers] = n
	errs := make([]error, workers)
	parallelDo(workers, func(w int) {
		errs[w] = sortRuns(ec, a[bounds[w]:bounds[w+1]], c, 0)
	})
	for _, err := range errs {
		if err != nil {
			return err
		}
	}
	return nil
}

// sortRuns orders the runs of equal normalized keys of sort key k in a,
// whose items are ordered by (normalized key k, row). A run whose rows
// all have the same value of key k is ordered by the next key in the same
// way (re-keyed with its normalized values, sorted by (key, row), runs
// resolved recursively); other runs (strings sharing their first 8 bytes,
// NULLs next to extreme values, …) are sorted by the full comparator.
func sortRuns(ec *Context, a []sortItem, c *colComparator, k int) error {
	for i := 0; i < len(a); {
		j := i + 1
		for j < len(a) && a[j].key == a[i].key {
			j++
		}
		if j-i > 1 {
			if err := sortRun1(ec, a[i:j], c, k); err != nil {
				return err
			}
		}
		i = j
	}
	return nil
}

// sortRun1 orders a run of items with equal normalized keys of sort key k
// (in row order).
func sortRun1(ec *Context, run []sortItem, c *colComparator, k int) error {
	first := run[0].row
	for _, it := range run[1:] {
		if !c.equal(k, first, it.row) {
			return sortRun(ec, run, c)
		}
	}
	if k+1 == len(c.keys) {
		return nil // equal on all keys: input order
	}
	for i := range run {
		run[i].key = c.norm(k+1, run[i].row)
	}
	if len(run) <= smallBucket {
		insertionSortItems(run)
	} else {
		slices.SortFunc(run, func(x, y sortItem) int {
			if x.key != y.key {
				if x.key < y.key {
					return -1
				}
				return 1
			}
			return int(x.row) - int(y.row)
		})
	}
	return sortRuns(ec, run, c, k+1)
}
