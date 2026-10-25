// Package format is how cg writes sizes and durations.
package format

import (
	"fmt"
	"math"
)

// IEC is numfmt --to=iec --suffix=B: 1024-based, rounded up, one decimal under
// 10 ("23KB", "161GB", "9.9KB").
func IEC(n int64) string {
	v := float64(n)
	units := []string{"", "K", "M", "G", "T", "P"}
	i := 0
	for v >= 1024 && i < len(units)-1 {
		v /= 1024
		i++
	}
	if i == 0 {
		return fmt.Sprintf("%dB", n)
	}
	if v < 10 {
		return fmt.Sprintf("%.1f%sB", math.Ceil(v*10)/10, units[i])
	}
	return fmt.Sprintf("%.0f%sB", math.Ceil(v), units[i])
}

// Duration is how long a stream has been up: "42s" under a minute, then
// "7m 05s".
func Duration(seconds int64) string {
	if seconds < 60 {
		return fmt.Sprintf("%ds", seconds)
	}
	return fmt.Sprintf("%dm %02ds", seconds/60, seconds%60)
}
