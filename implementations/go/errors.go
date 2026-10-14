package polyquery

import (
	"errors"
	"fmt"
	"maps"
	"runtime/debug"

	"polyquery/internal/errs"
)

// Code is a stable PolyQuery error code (spec/errors/error-codes.json).
type Code string

// The error codes an operation of this package can report.
const (
	CodeParseError          Code = "PARSE_ERROR"
	CodeSemanticError       Code = "SEMANTIC_ERROR"
	CodeTypeError           Code = "TYPE_ERROR"
	CodeNumericOverflow     Code = "NUMERIC_OVERFLOW"
	CodeDivisionByZero      Code = "DIVISION_BY_ZERO"
	CodeConversionError     Code = "CONVERSION_ERROR"
	CodeInvalidArgument     Code = "INVALID_ARGUMENT"
	CodeSubqueryCardinality Code = "SUBQUERY_CARDINALITY"
	CodeInvalidRequest      Code = "INVALID_REQUEST"
	CodeIngestError         Code = "INGEST_ERROR"
	CodeUnsupported         Code = "UNSUPPORTED"
	CodeAccessDenied        Code = "ACCESS_DENIED"
	CodeNotFound            Code = "NOT_FOUND"
	CodeAlreadyExists       Code = "ALREADY_EXISTS"
	CodeCancelled           Code = "CANCELLED"
	CodeResourceLimit       Code = "RESOURCE_LIMIT"
	CodeIOError             Code = "IO_ERROR"
	CodeStorageCorrupt      Code = "STORAGE_CORRUPT"
	CodeStorageVersion      Code = "STORAGE_VERSION_UNSUPPORTED"
	CodeInternalError       Code = "INTERNAL_ERROR"
	CodeTimeout             Code = "TIMEOUT"
)

// Error is the error type of every operation of this package. Use
// errors.As (or ErrorCode) to inspect it.
type Error struct {
	// Code is the specification's error code.
	Code Code
	// Message is a human-readable description.
	Message string
	// Details holds optional structured details, e.g. "line" and
	// "column" of a PARSE_ERROR or "record" of an INGEST_ERROR.
	Details map[string]any
}

// Error returns "CODE: message".
func (e *Error) Error() string { return string(e.Code) + ": " + e.Message }

// ErrorCode returns the code of a PolyQuery error, or "" if err is nil or
// not a *Error.
func ErrorCode(err error) Code {
	var pe *Error
	if errors.As(err, &pe) {
		return pe.Code
	}
	return ""
}

func newError(code Code, format string, args ...any) *Error {
	return &Error{Code: code, Message: fmt.Sprintf(format, args...)}
}

// wrapError converts an engine error into an *Error.
func wrapError(err error) error {
	if err == nil {
		return nil
	}
	var pe *Error
	if errors.As(err, &pe) {
		return pe
	}
	e := errs.From(err)
	return &Error{Code: Code(e.Code), Message: e.Message, Details: maps.Clone(e.Details)}
}

// guard turns a panic inside the engine into an INTERNAL_ERROR so that the
// instance stays usable. Use as: defer guard(&err).
func guard(err *error) {
	if r := recover(); r != nil {
		*err = &Error{Code: CodeInternalError, Message: fmt.Sprintf("internal error: %v", r),
			Details: map[string]any{"stack": string(debug.Stack())}}
	}
}
