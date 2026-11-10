package boxcmd

import (
	"strings"
	"testing"
)

func TestSaveSizesAreReadWithSpacesInTheFolder(t *testing.T) {
	games, total := parseSaveSizes("A 730 CS2 2000\nA 1057090 Ori DE 11811160064\nnoise\nA 9 x notanumber\n")
	if len(games) != 2 || games[1].dir != "Ori DE" || games[1].id != "1057090" || total != 11811162064 {
		t.Errorf("%v %d", games, total)
	}
}

func TestSoFarScriptAsksForEveryPartOfEveryGame(t *testing.T) {
	s := saveSoFarScript([]saveGame{{"730", "CS2"}, {"1", "Ori DE"}})
	for _, want := range []string{"du1 'common/Ori DE'", "du1 compatdata/730", "du1 shadercache/1", `echo "R $t"`, "/etc/ayis-library.conf"} {
		if !strings.Contains(s, want) {
			t.Errorf("lacks %q in\n%s", want, s)
		}
	}
	if n, ok := parseSoFar("noise\nR 42\n"); !ok || n != 42 {
		t.Error("so far")
	}
}

// The bar counts only what is copied: not the games unticked, not Steam's tools.
func TestTheSaveBarCountsOnlyWhatIsCopied(t *testing.T) {
	out := "A 2863680 ZERO PARADES 12000\nA 1057090 Ori 13000\nA 1493710 Proton - Experimental 1500\nA 1628350 SteamLinuxRuntime_sniper 700\n"
	games, total := parseSaveSizes(out)
	d := Deps{Skip: "1057090"}
	keep, n := d.toSave(games, total, out)
	if len(keep) != 1 || keep[0].id != "2863680" || n != 12000 {
		t.Errorf("%v %d", keep, n)
	}
	d = Deps{Skip: "2863680,1057090"}
	if keep, n := d.toSave(games, total, out); len(keep) != 0 || n != 0 {
		t.Errorf("all unticked: %v %d", keep, n)
	}
}
