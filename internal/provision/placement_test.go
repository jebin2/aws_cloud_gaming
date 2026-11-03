package provision

import (
	"strings"
	"testing"
)

func ids(g []Sized) string {
	var s []string
	for _, x := range g {
		s = append(s, x.ID)
	}
	return strings.Join(s, ",")
}

func TestLargestFirstOnTheDriveAndTheRestOnTheExtraDisk(t *testing.T) {
	games := []Sized{{"small", 10}, {"big", 80}, {"huge", 175}, {"mid", 30}}
	drive, extra := PlaceGames(games, 96)
	if ids(drive) != "big,small" || ids(extra) != "huge,mid" {
		t.Errorf("drive %s extra %s", ids(drive), ids(extra))
	}
	if got := ExtraDiskFor(extra, 20); got != 230 {
		t.Errorf("205 GB of games and 20 kept free is 230: %d", got)
	}
}

func TestEverythingThatFitsNeedsNoDisk(t *testing.T) {
	drive, extra := PlaceGames([]Sized{{"a", 40}, {"b", 50}}, 96)
	if len(extra) != 0 || len(drive) != 2 || ExtraDiskFor(extra, 20) != 0 {
		t.Errorf("%v %v", drive, extra)
	}
}

func TestADriveThatIsNotKnownMovesNothing(t *testing.T) {
	drive, extra := PlaceGames([]Sized{{"a", 900}}, -1)
	if len(extra) != 0 || len(drive) != 1 {
		t.Errorf("nothing is sized on a guess: %v %v", drive, extra)
	}
}

func TestNoDriveAtAllPutsEverythingOnTheDisk(t *testing.T) {
	_, extra := PlaceGames([]Sized{{"a", 40}}, 0)
	if len(extra) != 1 {
		t.Errorf("a type with no drive of its own: %v", extra)
	}
}

func TestSameSizeIsOrderedByIDSoTheListIsStable(t *testing.T) {
	_, extra := PlaceGames([]Sized{{"b", 50}, {"a", 50}, {"c", 50}}, 49)
	if ids(extra) != "a,b,c" {
		t.Error(ids(extra))
	}
}
