package watchdog

import (
	"encoding/json"
	"strings"
	"testing"
)

// After an idle stop the watchdog may delete the games disk - this host's tagged
// disk only - and read the one marker that says the games are saved.
func TestThePolicyMayDropOnlyThisHostsGamesDisk(t *testing.T) {
	s := Settings{Host: "ayis", Account: "123456789012", Bucket: "ayis-library-abc"}
	b, _ := json.Marshal(s.Policy("ap-south-1"))
	doc := string(b)
	for _, want := range []string{
		`"Sid":"DropTheGamesDiskAfterAnIdleStop"`, `"ec2:DetachVolume","ec2:DeleteVolume"`,
		`"arn:aws:ec2:ap-south-1:123456789012:volume/*"`, `"ec2:ResourceTag/Name":"ayis"`,
		`"Sid":"ReadTheSavedMarker"`, `"Resource":"arn:aws:s3:::ayis-library-abc/*pushed.json"`, `"ec2:DescribeVolumes"`,
	} {
		if !strings.Contains(doc, want) {
			t.Errorf("lacks %s in %s", want, doc)
		}
	}
}
