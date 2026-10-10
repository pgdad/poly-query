package types

import (
	"strconv"
)

// Date range: 0001-01-01 … 9999-12-31 as days since 1970-01-01.
const (
	MinDate = int64(-719162)
	MaxDate = int64(2932896)
	// MicrosPerDay is the number of microseconds in a day.
	MicrosPerDay = int64(86400000000)
)

// DaysFromCivil converts a proleptic Gregorian date to days since 1970-01-01.
func DaysFromCivil(y, m, d int64) int64 {
	if m <= 2 {
		y--
	}
	era := y / 400
	if y < 0 && y%400 != 0 {
		era = (y - 399) / 400
	}
	yoe := y - era*400
	mp := (m + 9) % 12
	doy := (153*mp+2)/5 + d - 1
	doe := yoe*365 + yoe/4 - yoe/100 + doy
	return era*146097 + doe - 719468
}

// CivilFromDays converts days since 1970-01-01 to (year, month, day).
func CivilFromDays(z int64) (int64, int64, int64) {
	z += 719468
	era := z / 146097
	if z < 0 && z%146097 != 0 {
		era = (z - 146096) / 146097
	}
	doe := z - era*146097
	yoe := (doe - doe/1460 + doe/36524 - doe/146096) / 365
	y := yoe + era*400
	doy := doe - (365*yoe + yoe/4 - yoe/100)
	mp := (5*doy + 2) / 153
	d := doy - (153*mp+2)/5 + 1
	m := mp + 3
	if m > 12 {
		m -= 12
	}
	if m <= 2 {
		y++
	}
	return y, m, d
}

func isLeap(y int64) bool { return y%4 == 0 && (y%100 != 0 || y%400 == 0) }

var monthDays = [13]int64{0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}

// ValidDate reports whether y-m-d is a valid calendar date in 0001…9999.
func ValidDate(y, m, d int64) bool {
	if y < 1 || y > 9999 || m < 1 || m > 12 || d < 1 {
		return false
	}
	md := monthDays[m]
	if m == 2 && isLeap(y) {
		md = 29
	}
	return d <= md
}

func digitsAt(s string, start, n int) (int64, bool) {
	if start+n > len(s) {
		return 0, false
	}
	var v int64
	for i := start; i < start+n; i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		v = v*10 + int64(c-'0')
	}
	return v, true
}

// IsDateSyntax reports whether s matches ^[0-9]{4}-[0-9]{2}-[0-9]{2}$.
func IsDateSyntax(s string) bool {
	if len(s) != 10 || s[4] != '-' || s[7] != '-' {
		return false
	}
	_, ok1 := digitsAt(s, 0, 4)
	_, ok2 := digitsAt(s, 5, 2)
	_, ok3 := digitsAt(s, 8, 2)
	return ok1 && ok2 && ok3
}

// ParseDate parses "YYYY-MM-DD" into days since epoch.
func ParseDate(s string) (int64, bool) {
	if !IsDateSyntax(s) {
		return 0, false
	}
	y, _ := digitsAt(s, 0, 4)
	m, _ := digitsAt(s, 5, 2)
	d, _ := digitsAt(s, 8, 2)
	if !ValidDate(y, m, d) {
		return 0, false
	}
	return DaysFromCivil(y, m, d), true
}

// ParseTimestamp parses "YYYY-MM-DD[ T]HH:MM:SS[.f{1,6}]" into microseconds
// since epoch.
func ParseTimestamp(s string) (int64, bool) {
	if len(s) < 19 || (s[10] != ' ' && s[10] != 'T') || s[13] != ':' || s[16] != ':' {
		return 0, false
	}
	days, ok := ParseDate(s[:10])
	if !ok {
		return 0, false
	}
	hh, ok1 := digitsAt(s, 11, 2)
	mm, ok2 := digitsAt(s, 14, 2)
	ss, ok3 := digitsAt(s, 17, 2)
	if !ok1 || !ok2 || !ok3 || hh > 23 || mm > 59 || ss > 59 {
		return 0, false
	}
	var frac int64
	if len(s) > 19 {
		n := len(s) - 20
		if s[19] != '.' || n < 1 || n > 6 {
			return 0, false
		}
		f, ok := digitsAt(s, 20, n)
		if !ok {
			return 0, false
		}
		frac = f * Pow10[6-n]
	}
	return days*MicrosPerDay + ((hh*60+mm)*60+ss)*1000000 + frac, true
}

// ParseDateOrTimestamp accepts DATE or TIMESTAMP text and returns micros.
func ParseDateOrTimestamp(s string) (int64, bool) {
	if d, ok := ParseDate(s); ok {
		return d * MicrosPerDay, true
	}
	return ParseTimestamp(s)
}

// FloorDiv divides rounding toward negative infinity.
func FloorDiv(a, b int64) int64 {
	q := a / b
	if (a%b != 0) && ((a < 0) != (b < 0)) {
		q--
	}
	return q
}

// TimestampToDate truncates a timestamp to its date (days since epoch).
func TimestampToDate(micros int64) int64 { return FloorDiv(micros, MicrosPerDay) }

func pad(b []byte, v int64, n int) []byte {
	s := strconv.FormatInt(v, 10)
	for i := len(s); i < n; i++ {
		b = append(b, '0')
	}
	return append(b, s...)
}

// AppendDate appends "YYYY-MM-DD".
func AppendDate(b []byte, days int64) []byte {
	y, m, d := CivilFromDays(days)
	b = pad(b, y, 4)
	b = append(b, '-')
	b = pad(b, m, 2)
	b = append(b, '-')
	return pad(b, d, 2)
}

// FormatDate renders "YYYY-MM-DD".
func FormatDate(days int64) string { return string(AppendDate(nil, days)) }

// AppendTimestamp appends "YYYY-MM-DD HH:MM:SS[.ffffff]".
func AppendTimestamp(b []byte, micros int64) []byte {
	days := TimestampToDate(micros)
	rem := micros - days*MicrosPerDay
	b = AppendDate(b, days)
	secs := rem / 1000000
	frac := rem % 1000000
	b = append(b, ' ')
	b = pad(b, secs/3600, 2)
	b = append(b, ':')
	b = pad(b, secs/60%60, 2)
	b = append(b, ':')
	b = pad(b, secs%60, 2)
	if frac != 0 {
		b = append(b, '.')
		b = pad(b, frac, 6)
	}
	return b
}

// FormatTimestamp renders a timestamp per types.md §9.
func FormatTimestamp(micros int64) string { return string(AppendTimestamp(nil, micros)) }
