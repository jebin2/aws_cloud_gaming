package watchdog

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatchlogs"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatchlogs/types"
	"github.com/aws/smithy-go"
)

type logs struct {
	events []types.FilteredLogEvent
	err    error
}

func (l logs) FilterLogEvents(context.Context, *cloudwatchlogs.FilterLogEventsInput, ...func(*cloudwatchlogs.Options)) (*cloudwatchlogs.FilterLogEventsOutput, error) {
	return &cloudwatchlogs.FilterLogEventsOutput{Events: l.events}, l.err
}

type apiErr string

func (e apiErr) Error() string                 { return string(e) }
func (e apiErr) ErrorCode() string             { return string(e) }
func (e apiErr) ErrorMessage() string          { return string(e) }
func (e apiErr) ErrorFault() smithy.ErrorFault { return smithy.FaultClient }

var now = time.Date(2026, 10, 25, 12, 0, 0, 0, time.UTC)

func ev(msg string, ago time.Duration) types.FilteredLogEvent {
	return types.FilteredLogEvent{Message: aws.String(msg), Timestamp: aws.Int64(now.Add(-ago).UnixMilli())}
}

func TestDecisionIsTheLatestEventAndItsAge(t *testing.T) {
	l := logs{events: []types.FilteredLogEvent{
		ev("cg-watchdog: archive: kept - old", 50*time.Minute),
		ev("cg-watchdog: archive: kept - last used 16h ago; deleted in 6d 7h unless a box is launched", 6*time.Minute),
	}}
	got := ArchiveDecision(context.Background(), l, "gamevps", 14, now)
	want := "kept - last used 16h ago; deleted in 6d 7h unless a box is launched  (checked 6 min ago)"
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestAgeUnits(t *testing.T) {
	for d, want := range map[time.Duration]string{30 * time.Second: "30s", 89 * time.Second: "89s", 90 * time.Second: "1 min", 7 * time.Minute: "7 min"} {
		if got := Age(now.Add(-d).UnixMilli(), now); got != want {
			t.Errorf("%v: got %s want %s", d, got, want)
		}
	}
}

func TestOffNeverCheckedAndUnreadable(t *testing.T) {
	ctx := context.Background()
	if got := ArchiveDecision(ctx, logs{}, "h", 0, now); got != "kept forever (GAME_ARCHIVE_EXPIRY_DAYS=0)" {
		t.Errorf("off: %q", got)
	}
	if got := ArchiveDecision(ctx, logs{}, "h", 14, now); got != "deleted after 14 days with no box - not checked yet (hourly)" {
		t.Errorf("never: %q", got)
	}
	if got := ArchiveDecision(ctx, logs{err: apiErr("ResourceNotFoundException")}, "h", 14, now); !strings.Contains(got, "not checked yet") {
		t.Errorf("no log group: %q", got)
	}
	got := ArchiveDecision(ctx, logs{err: errors.New("denied")}, "h", 14, now)
	if strings.Contains(got, "not checked yet") || !strings.Contains(got, "could not be read") {
		t.Errorf("an unreadable log must not read as unchecked: %q", got)
	}
}

func TestOtherLinesAreIgnored(t *testing.T) {
	l := logs{events: []types.FilteredLogEvent{ev("cg-watchdog: archive-ish noise", time.Minute)}}
	if got := ArchiveDecision(context.Background(), l, "h", 14, now); !strings.Contains(got, "not checked yet") {
		t.Errorf("got %q", got)
	}
}
