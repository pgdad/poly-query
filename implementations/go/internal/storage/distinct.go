package storage

import (
	"math"
	"math/bits"
)

// exactDistinctLimit is the number of distinct values counted exactly;
// beyond it a HyperLogLog sketch takes over (protocol.md §5.8 allows an
// approximate distinct_count), which bounds the memory used for statistics
// of large tables.
const exactDistinctLimit = 1 << 17

// hllPrecision gives 2^14 registers (standard error ≈ 0.8%).
const hllPrecision = 14

// distinctCounter counts distinct 64-bit value keys: exactly while small,
// approximately afterwards. Keys must be well mixed (see mix64).
type distinctCounter struct {
	exact map[uint64]struct{}
	regs  []uint8
}

func newDistinctCounter() *distinctCounter {
	return &distinctCounter{exact: map[uint64]struct{}{}}
}

func (d *distinctCounter) add(h uint64) {
	if d.exact != nil {
		d.exact[h] = struct{}{}
		if len(d.exact) <= exactDistinctLimit {
			return
		}
		d.regs = make([]uint8, 1<<hllPrecision)
		for k := range d.exact {
			d.observe(k)
		}
		d.exact = nil
		return
	}
	d.observe(h)
}

func (d *distinctCounter) observe(h uint64) {
	idx := h >> (64 - hllPrecision)
	rank := uint8(bits.LeadingZeros64(h<<hllPrecision|1<<(hllPrecision-1)) + 1)
	if rank > d.regs[idx] {
		d.regs[idx] = rank
	}
}

func (d *distinctCounter) count() int {
	if d.exact != nil {
		return len(d.exact)
	}
	m := float64(len(d.regs))
	sum, zeros := 0.0, 0
	for _, r := range d.regs {
		sum += math.Ldexp(1, -int(r))
		if r == 0 {
			zeros++
		}
	}
	est := 0.7213 / (1 + 1.079/m) * m * m / sum
	if est <= 2.5*m && zeros > 0 {
		est = m * math.Log(m/float64(zeros))
	}
	return int(est + 0.5)
}

// mix64 is the SplitMix64 finalizer, used to spread integer keys.
func mix64(x uint64) uint64 {
	x ^= x >> 30
	x *= 0xbf58476d1ce4e5b9
	x ^= x >> 27
	x *= 0x94d049bb133111eb
	x ^= x >> 31
	return x
}

// hashString is FNV-1a followed by mix64 (deterministic across runs).
func hashString(s string) uint64 {
	h := uint64(14695981039346656037)
	for i := 0; i < len(s); i++ {
		h ^= uint64(s[i])
		h *= 1099511628211
	}
	return mix64(h)
}
