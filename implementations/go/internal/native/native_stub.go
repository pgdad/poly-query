//go:build !(cgo && unix)

package native

import "errors"

// Without cgo (or on non-Unix platforms) the library cannot be loaded; the
// engine then always uses its own code paths. The methods exist only so
// that callers compile: no Lib value can be obtained.

// Supported reports whether this build can load the native library.
func Supported() bool { return false }

// Lib is a loaded kernel library (never instantiated in this build).
type Lib struct{}

// Load always fails in this build.
func Load(path string) (*Lib, error) {
	return nil, errors.New("native kernels need a cgo-enabled build on a Unix platform")
}

func unavailable() { panic("native: library not available in this build") }

func (lib *Lib) Path() string              { unavailable(); return "" }
func (lib *Lib) Variant() string           { unavailable(); return "" }
func (lib *Lib) AvailableVariants() string { unavailable(); return "" }
func (lib *Lib) FilterI64([]int64, []byte, Op, int64, int64, []uint32) int {
	unavailable()
	return 0
}
func (lib *Lib) FilterI64Bitmap([]int64, []byte, Op, int64, int64, []byte) int {
	unavailable()
	return 0
}
func (lib *Lib) SumI64([]int64, []byte) (int64, bool) { unavailable(); return 0, false }
func (lib *Lib) SumF64([]float64, []byte) float64     { unavailable(); return 0 }
func (lib *Lib) MinMaxI64([]int64, []byte) (int, int64, int64) {
	unavailable()
	return 0, 0, 0
}
func (lib *Lib) MinMaxF64([]float64, []byte) (int, float64, float64) {
	unavailable()
	return 0, 0, 0
}
func (lib *Lib) CountI64([]int64, []byte, Op, int64, int64) int { unavailable(); return 0 }
func (lib *Lib) BitmapAnd(a, b, out []byte)                     { unavailable() }
func (lib *Lib) BitmapOr(a, b, out []byte)                      { unavailable() }
func (lib *Lib) BitmapAndNot(a, b, out []byte)                  { unavailable() }
func (lib *Lib) Popcount([]byte, int) int                       { unavailable(); return 0 }
func (lib *Lib) HashI64([]int64, uint64, []uint64)              { unavailable() }
func (lib *Lib) CompareI64(a, b []int64, op Op, out []byte) int {
	unavailable()
	return 0
}
func (lib *Lib) CompareFixed(a, b []byte, width int, out []int8) { unavailable() }
func (lib *Lib) GroupSumI64([]uint32, []int64, []byte, []int64, []int64) Status {
	unavailable()
	return Invalid
}
func (lib *Lib) GatherI64([]int64, []uint32, []int64) { unavailable() }
