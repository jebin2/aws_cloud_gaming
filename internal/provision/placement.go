package provision

import (
	"math"
	"sort"
)

// Sized is a game and what it takes, in GB.
type Sized struct {
	ID string
	GB float64
}

// PlaceGames says where each game goes: on the machine's own drive when it still
// fits there, on the added disk when it does not. Largest first, so the drive,
// which is local and fast, is filled by the games that would otherwise need the
// biggest disk. driveGB is what the drive holds for games (its size less what is
// kept free); negative means it is not known, and then nothing is moved off it on
// a guess.
//
// The same rule is in the app (paintFit), so the disk priced before the build is
// the disk the build makes, and in the box's restore, which is told the list.
func PlaceGames(games []Sized, driveGB float64) (onDrive, onExtra []Sized) {
	sorted := append([]Sized(nil), games...)
	sort.SliceStable(sorted, func(i, j int) bool {
		if sorted[i].GB != sorted[j].GB {
			return sorted[i].GB > sorted[j].GB
		}
		return sorted[i].ID < sorted[j].ID
	})
	left := driveGB
	for _, g := range sorted {
		if driveGB < 0 || g.GB <= left {
			onDrive = append(onDrive, g)
			left -= g.GB
			continue
		}
		onExtra = append(onExtra, g)
	}
	return onDrive, onExtra
}

// ExtraDiskFor is the disk to add for the games that did not fit the drive: what
// they take plus what is kept free for Steam's downloads, rounded up; 0 when
// nothing overflowed.
func ExtraDiskFor(onExtra []Sized, reserveGB float64) int {
	if len(onExtra) == 0 {
		return 0
	}
	var need float64
	for _, g := range onExtra {
		need += g.GB
	}
	return int(math.Ceil((need+reserveGB)/ExtraDiskStepGB)) * ExtraDiskStepGB
}
