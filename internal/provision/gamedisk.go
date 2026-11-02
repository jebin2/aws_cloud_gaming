package provision

import "math"

const (
	// ExtraDiskStepGB is what an added games disk is rounded up to.
	ExtraDiskStepGB = 10
	// MaxExtraDiskGB is the most cg adds on its own. A bigger library is a
	// decision for a person, not an arithmetic result.
	MaxExtraDiskGB = 1000
)

// ExtraDiskGB is the size of the disk to add for the games, or 0 when the
// machine's own drive holds them. needGB is what the chosen games take, reserveGB
// what is kept free for Steam's downloads and shader caches, storeGB the
// machine's own drive as the box will see it (negative: not known, and nothing is
// added on a guess). The same rule is in the app (paintFit), so the price shown
// before the build is the disk the build makes.
func ExtraDiskGB(needGB, reserveGB, storeGB float64) int {
	if storeGB < 0 || needGB <= 0 || needGB+reserveGB <= storeGB {
		return 0
	}
	return int(math.Ceil((needGB+reserveGB)/ExtraDiskStepGB)) * ExtraDiskStepGB
}

// RoundExtraDiskGB is a size asked for, rounded up to the step; anything under 1
// is no disk.
func RoundExtraDiskGB(gb int) int {
	if gb < 1 {
		return 0
	}
	return (gb + ExtraDiskStepGB - 1) / ExtraDiskStepGB * ExtraDiskStepGB
}
