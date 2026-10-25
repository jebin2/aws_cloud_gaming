package output

import (
	"regexp"
	"strings"
)

// What a detail line means, from its words. Whole words only: a substring test
// reads "broken" as "ok" and "token" as "ok" too. Failure is checked first, and
// "not <participle>" before the success words, so "NOT registered" is a warning
// rather than a tick - but a bare "not" is not: "it guards the account, not the
// box" is information, and flagging it put a warning sign on a routine message.
var (
	reFail = regexp.MustCompile(`(^|[^a-z])(error|errors|failed|failure|could not|cannot|refused|refusing|incomplete|timeout|rejected|denied|unreachable|not paired)([^a-z]|$)`)
	reSkip = regexp.MustCompile(`(^|[^a-z])(not archiving|nothing to|skipped \(|no games installed)([^a-z]|$)`)
	reWarn = regexp.MustCompile(`(^|[^a-z])(warning|skipping|still billing|expired|stale|relayed|not answering|not up yet|not [a-z]+ed)([^a-z]|$)`)
	reWait = regexp.MustCompile(`^(still|waiting|retrying|reconnecting|shutting-down|stopping|pending|host rebooting)([^a-z]|$)|(^|[^a-z])(trying once more)([^a-z]|$)`)
	reKept = regexp.MustCompile(`^(keeping|kept|reusing|already)([^a-z]|$)|(^|[^a-z])(kept)([^a-z]|$)`)
	reOK   = regexp.MustCompile(`(^|[^a-z])(ok|done|complete|completed|archived|pushed|restored|joined|paired|terminated|stopped|running|created|deleted|pruned|armed|disarmed|installed|ready|saved|updated|forgot|available|recorded|registered|succeeded|found|mounted|shipped|present|written|configured|disabled|enabled)([^a-z]|$)`)
)

// Kind classifies a detail line: fail, skip, wait, kept, warn, ok, info, or
// cont for an indented continuation. The first match wins, in that order.
func Kind(text string) string {
	t := strings.ToLower(text)
	switch {
	case strings.HasPrefix(text, "  "):
		return "cont"
	case reFail.MatchString(t):
		return "fail"
	case reSkip.MatchString(t):
		return "skip"
	case reWait.MatchString(t):
		return "wait"
	case reKept.MatchString(t):
		return "kept"
	case reWarn.MatchString(t):
		return "warn"
	case reOK.MatchString(t):
		return "ok"
	}
	return "info"
}
