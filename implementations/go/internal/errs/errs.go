// Package errs defines the structured error model shared by all engine layers
// (spec/errors/errors.md). Every failure that reaches the protocol layer is an
// *Error carrying one of the stable error codes.
package errs

import (
	"errors"
	"fmt"
)

// Code is a stable PolyQuery error code.
type Code string

// Error codes from spec/errors/error-codes.json.
const (
	ParseError          Code = "PARSE_ERROR"
	SemanticError       Code = "SEMANTIC_ERROR"
	TypeError           Code = "TYPE_ERROR"
	NumericOverflow     Code = "NUMERIC_OVERFLOW"
	DivisionByZero      Code = "DIVISION_BY_ZERO"
	ConversionError     Code = "CONVERSION_ERROR"
	InvalidArgument     Code = "INVALID_ARGUMENT"
	SubqueryCardinality Code = "SUBQUERY_CARDINALITY"
	InvalidRequest      Code = "INVALID_REQUEST"
	IngestError         Code = "INGEST_ERROR"
	Unsupported         Code = "UNSUPPORTED"
	AccessDenied        Code = "ACCESS_DENIED"
	NotFound            Code = "NOT_FOUND"
	AlreadyExists       Code = "ALREADY_EXISTS"
	Cancelled           Code = "CANCELLED"
	ResourceLimit       Code = "RESOURCE_LIMIT"
	IOError             Code = "IO_ERROR"
	StorageCorrupt      Code = "STORAGE_CORRUPT"
	StorageVersion      Code = "STORAGE_VERSION_UNSUPPORTED"
	InternalError       Code = "INTERNAL_ERROR"
	Overloaded          Code = "OVERLOADED"
	ShuttingDown        Code = "SHUTTING_DOWN"
	Timeout             Code = "TIMEOUT"
)

// Error is a PolyQuery error with a code, a human readable message and
// optional structured details (e.g. SQL line/column, input record).
type Error struct {
	Code    Code
	Message string
	Details map[string]any
}

func (e *Error) Error() string { return string(e.Code) + ": " + e.Message }

// New creates an error with a formatted message.
func New(code Code, format string, args ...any) *Error {
	return &Error{Code: code, Message: fmt.Sprintf(format, args...)}
}

// At creates an error carrying a 1-based SQL source position.
func At(code Code, line, col int, format string, args ...any) *Error {
	e := New(code, format, args...)
	if line > 0 {
		e.Details = map[string]any{"line": line, "column": col}
	}
	return e
}

// With returns the error with an additional detail key set.
func (e *Error) With(key string, value any) *Error {
	if e.Details == nil {
		e.Details = map[string]any{}
	}
	e.Details[key] = value
	return e
}

// From converts any error into an *Error; non-PolyQuery errors become
// INTERNAL_ERROR.
func From(err error) *Error {
	if err == nil {
		return nil
	}
	var pe *Error
	if errors.As(err, &pe) {
		return pe
	}
	return &Error{Code: InternalError, Message: err.Error()}
}

// Is reports whether err is a PolyQuery error with the given code.
func Is(err error, code Code) bool {
	var pe *Error
	return errors.As(err, &pe) && pe.Code == code
}
