// Package watchdog is the cloud watchdog: the Lambda that ends an idle box and,
// with no box, deletes the game archive after a while. This is the read side -
// what it last decided - which `cg status`, `cg cost` and `cg watcher` print.
package watchdog

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatchlogs"
	"github.com/aws/smithy-go"
)

// Name is the Lambda's name for a host, and LogGroup its log group.
func Name(host string) string     { return host + "-cloud-watchdog" }
func LogGroup(host string) string { return "/aws/lambda/" + Name(host) }

// LogsAPI is the part of CloudWatch Logs the read side uses.
type LogsAPI interface {
	FilterLogEvents(context.Context, *cloudwatchlogs.FilterLogEventsInput, ...func(*cloudwatchlogs.Options)) (*cloudwatchlogs.FilterLogEventsOutput, error)
}

// Age is how long ago an event was, as the watchdog's lines say it: seconds
// under a minute and a half, then minutes.
func Age(eventMS int64, now time.Time) string {
	age := now.Unix() - eventMS/1000
	if age < 90 {
		return fmt.Sprintf("%ds", age)
	}
	return fmt.Sprintf("%d min", age/60)
}

// ArchiveDecision is the one line saying what the watchdog last decided about
// the game archive: off, its latest decision and how old that is, or not
// checked yet. Unlike the Bash, a log that could not be read says so instead of
// "not checked yet", which would be a guess.
func ArchiveDecision(ctx context.Context, logs LogsAPI, host string, expiryDays int, now time.Time) string {
	if expiryDays == 0 {
		return "kept forever (GAME_ARCHIVE_EXPIRY_DAYS=0)"
	}
	var lastMS int64
	var lastMsg string
	in := &cloudwatchlogs.FilterLogEventsInput{
		LogGroupName:  aws.String(LogGroup(host)),
		StartTime:     aws.Int64(now.Add(-2 * time.Hour).UnixMilli()),
		FilterPattern: aws.String(`"cg-watchdog: archive"`),
	}
	for {
		out, err := logs.FilterLogEvents(ctx, in)
		if err != nil {
			var ae smithy.APIError
			if errors.As(err, &ae) && ae.ErrorCode() == "ResourceNotFoundException" {
				break // no log group: it has never run
			}
			return fmt.Sprintf("deleted after %d days with no box - the watchdog's log could not be read", expiryDays)
		}
		for _, e := range out.Events {
			if m := aws.ToString(e.Message); strings.HasPrefix(m, "cg-watchdog: archive:") {
				lastMS, lastMsg = aws.ToInt64(e.Timestamp), strings.TrimSpace(strings.TrimPrefix(m, "cg-watchdog: archive: "))
			}
		}
		if out.NextToken == nil || *out.NextToken == "" {
			break
		}
		in.NextToken = out.NextToken
	}
	if lastMS > 0 {
		return fmt.Sprintf("%s  (checked %s ago)", lastMsg, Age(lastMS, now))
	}
	return fmt.Sprintf("deleted after %d days with no box - not checked yet (hourly)", expiryDays)
}
