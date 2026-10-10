//go:build !(goexperiment.simd && amd64)

package exec

import "polyquery/internal/plan"

// Without GOEXPERIMENT=simd (or on other architectures) there are no
// explicit SIMD kernels; the portable loops of vexpr.go are used.

// SIMDEnabled reports whether explicit SIMD kernels are in use.
func SIMDEnabled() bool { return false }

func simdCmpVCInt(plan.BinaryOp, []int64, int64, []int64) bool         { return false }
func simdCmpVVInt(plan.BinaryOp, []int64, []int64, []int64) bool       { return false }
func simdCmpVCFloat(plan.BinaryOp, []float64, float64, []int64) bool   { return false }
func simdCmpVVFloat(plan.BinaryOp, []float64, []float64, []int64) bool { return false }
func simdFloatOp(plan.BinaryOp, []float64, []float64, []float64) bool  { return false }
