package provision

import "testing"

func TestExtraDiskIsAddedOnlyWhenTheGamesDoNotFit(t *testing.T) {
	for _, c := range []struct {
		need, reserve, store float64
		want                 int
		why                  string
	}{
		{121, 20, 232, 0, "fits with the reserve to spare"},
		{212, 20, 232, 0, "fills the drive exactly: still fits"},
		{213, 20, 232, 240, "one GB over: rounded up to the next ten"},
		{140, 20, 115, 160, "a small drive"},
		{170, 20, 115, 190, "the example on the Build page"},
		{50, 20, 0, 70, "a machine with no drive of its own"},
		{0, 20, 115, 0, "no games: nothing to add"},
		{140, 20, -1, 0, "drive size not known: nothing added on a guess"},
	} {
		if got := ExtraDiskGB(c.need, c.reserve, c.store); got != c.want {
			t.Errorf("%s: need %.0f reserve %.0f store %.0f: %d, want %d", c.why, c.need, c.reserve, c.store, got, c.want)
		}
	}
}

func TestTheGamesDiskIsASecondDiskDeletedWithTheBox(t *testing.T) {
	one := blockDevices(Params{DiskGB: 50})
	if len(one) != 1 || *one[0].DeviceName != "/dev/sda1" || *one[0].Ebs.VolumeSize != 50 {
		t.Errorf("root only: %+v", one)
	}
	two := blockDevices(Params{DiskGB: 50, DataGB: 190})
	if len(two) != 2 || *two[1].DeviceName != "/dev/sdf" || *two[1].Ebs.VolumeSize != 190 || !*two[1].Ebs.DeleteOnTermination {
		t.Errorf("with a games disk: %+v", two)
	}
}

func TestADiskAskedForIsRoundedUpToTheStep(t *testing.T) {
	for in, want := range map[int]int{-5: 0, 0: 0, 1: 10, 10: 10, 95: 100, 100: 100, 101: 110} {
		if got := RoundExtraDiskGB(in); got != want {
			t.Errorf("%d: %d, want %d", in, got, want)
		}
	}
}
