package format

import "testing"

func TestIEC(t *testing.T) {
	for n, want := range map[int64]string{
		500: "500B", 1024: "1.0KB", 22458: "22KB", 22645: "23KB", 9_999: "9.8KB",
		171986001052: "161GB", 1 << 30: "1.0GB", 10 * 1024: "10KB",
	} {
		if got := IEC(n); got != want {
			t.Errorf("%d: got %s want %s", n, got, want)
		}
	}
}

func TestDuration(t *testing.T) {
	for n, want := range map[int64]string{0: "0s", 59: "59s", 60: "1m 00s", 125: "2m 05s"} {
		if got := Duration(n); got != want {
			t.Errorf("%d: got %s want %s", n, got, want)
		}
	}
}
