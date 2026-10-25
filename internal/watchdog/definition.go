package watchdog

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"hash/crc32"
	"reflect"
)

// What the cloud watchdog is made of. Everything here is what the deployed
// function is compared against: a function that is not exactly this is "not
// current", and `cg watchdog check` says which piece drifted.
const (
	RuntimeName = "python3.13"
	Handler     = "cloud_watchdog.handler"
	PolicyName  = "idle-guard"
	EveryMin    = 5 // how often the schedule runs it; the rule and the app read this one number
	TimeoutSec  = 300
	MemoryMB    = 128
	BootGrace   = 20
)

// StateRule is EC2's own events: state changes, so the watchdog can confirm a
// box is gone, and spot interruption warnings. One rule for both - a detail
// filter would have to exclude the warning - and the function ignores every
// state that is not an end.
func StateRule(host string) string { return Name(host) + "-state" }

// Settings are the figures the function is configured with.
type Settings struct {
	Host         string
	Account      string
	Bucket       string // the archive bucket, as cg names it
	IdleMinutes  int
	StuckMinutes int
	ExpiryDays   int
	NtfyURL      string // "" leaves it absent
	S3GBMonth    string // the price as cg has it ("0.025"); "" when unknown
	INRPerUSD    string // "" when unknown
}

// Env is the function's environment, in the form `aws lambda` takes it, and
// the form the fingerprint is made of: the exact text matters, because it was
// hashed into the description of every watchdog already deployed.
func (s Settings) Env() string {
	opt := func(k, v string) string {
		if v == "" {
			return ""
		}
		return "," + k + "=" + v
	}
	return fmt.Sprintf("Variables={CG_TS_HOST=%s,CG_IDLE_MINUTES=%d,CG_BOOT_GRACE_MINUTES=%d,CG_STUCK_MINUTES=%d,CG_BUCKET=%s,CG_ACCOUNT=%s,CG_ARCHIVE_EXPIRY_DAYS=%d%s%s%s}",
		s.Host, s.IdleMinutes, BootGrace, s.StuckMinutes, s.Bucket, s.Account, s.ExpiryDays,
		opt("CG_S3_USD_GB_MONTH", s.S3GBMonth), opt("CG_INR_PER_USD", s.INRPerUSD), opt("CG_NTFY_URL", s.NtfyURL))
}

// EnvMap is the same environment as a map, for the API: the text form above is
// what the fingerprint hashes, this is what Lambda is given.
func (s Settings) EnvMap() map[string]string {
	m := map[string]string{
		"CG_TS_HOST": s.Host, "CG_IDLE_MINUTES": fmt.Sprint(s.IdleMinutes), "CG_BOOT_GRACE_MINUTES": fmt.Sprint(BootGrace),
		"CG_STUCK_MINUTES": fmt.Sprint(s.StuckMinutes), "CG_BUCKET": s.Bucket, "CG_ACCOUNT": s.Account,
		"CG_ARCHIVE_EXPIRY_DAYS": fmt.Sprint(s.ExpiryDays),
	}
	if s.S3GBMonth != "" {
		m["CG_S3_USD_GB_MONTH"] = s.S3GBMonth
	}
	if s.INRPerUSD != "" {
		m["CG_INR_PER_USD"] = s.INRPerUSD
	}
	if s.NtfyURL != "" {
		m["CG_NTFY_URL"] = s.NtfyURL
	}
	return m
}

// Fingerprint is everything about the function that is not its code, as one
// short hash kept in its description - so drift in any of it reads as "not
// current".
func (s Settings) Fingerprint(roleARN string) string {
	sum := sha256.Sum256([]byte(fmt.Sprintf("%s|%s|%s|%d|%d|%s\n", RuntimeName, Handler, roleARN, TimeoutSec, MemoryMB, s.Env())))
	return hex.EncodeToString(sum[:])[:12]
}

// Policy is the role's policy. The watchdog may describe and read metrics
// anywhere; stop, terminate and tag ONLY the instance tagged with this host
// name, and tag it only with the keys it uses; write only its own log group. It
// cannot launch anything, read the game archive beyond expiring it, or touch
// IAM. Archive expiry adds CloudTrail lookups, its own free SSM marks, and
// list/read/delete on cg's archive buckets - and only while expiry is on. With
// expiry 0 the role cannot delete a single game.
//
// The SSM resource's region is a wildcard, deliberately: an IAM role is GLOBAL,
// so a policy pinned to one region was revoked by the watchdog installed last
// in another. What scopes it is the account and the parameter path.
func (s Settings) Policy(region string) map[string]any {
	stmts := []any{
		map[string]any{"Sid": "Look", "Effect": "Allow", "Action": []string{"ec2:DescribeInstances", "cloudwatch:GetMetricStatistics"}, "Resource": "*"},
		map[string]any{"Sid": "EndOnlyTheTaggedBox", "Effect": "Allow", "Action": []string{"ec2:StopInstances", "ec2:TerminateInstances"},
			"Resource":  fmt.Sprintf("arn:aws:ec2:%s:%s:instance/*", region, s.Account),
			"Condition": map[string]any{"StringEquals": map[string]any{"ec2:ResourceTag/Name": s.Host}}},
		map[string]any{"Sid": "MarkWhenFirstSeenGoingDown", "Effect": "Allow", "Action": "ec2:CreateTags",
			"Resource": fmt.Sprintf("arn:aws:ec2:%s:%s:instance/*", region, s.Account),
			"Condition": map[string]any{
				"StringEquals": map[string]any{"ec2:ResourceTag/Name": s.Host},
				"ForAllValues:StringEquals": map[string]any{"aws:TagKeys": []string{
					"cg-going-down-since", "cg-slow-noted", "cg-forced", "cg-stopped-since", "cg-stopped-warned"}}}},
		map[string]any{"Sid": "OwnLogs", "Effect": "Allow", "Action": []string{"logs:CreateLogStream", "logs:PutLogEvents"},
			"Resource": fmt.Sprintf("arn:aws:logs:%s:%s:log-group:%s:*", region, s.Account, LogGroup(s.Host))},
	}
	if s.ExpiryDays > 0 {
		stmts = append(stmts,
			map[string]any{"Sid": "ArchiveExpiryLookups", "Effect": "Allow", "Action": "cloudtrail:LookupEvents", "Resource": "*"},
			map[string]any{"Sid": "ArchiveExpiryFindBuckets", "Effect": "Allow", "Action": "s3:ListAllMyBuckets", "Resource": "*"},
			map[string]any{"Sid": "ArchiveExpiryBucket", "Effect": "Allow",
				"Action":   []string{"s3:ListBucket", "s3:ListBucketMultipartUploads", "s3:DeleteBucket", "s3:GetBucketLocation"},
				"Resource": "arn:aws:s3:::cg-library-*"},
			map[string]any{"Sid": "ArchiveExpiryObjects", "Effect": "Allow",
				"Action":   []string{"s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"},
				"Resource": "arn:aws:s3:::cg-library-*/*"},
			map[string]any{"Sid": "ArchiveExpiryMarks", "Effect": "Allow",
				"Action":   []string{"ssm:GetParameter", "ssm:PutParameter", "ssm:GetParametersByPath", "ssm:DeleteParameter"},
				"Resource": fmt.Sprintf("arn:aws:ssm:*:%s:parameter/cloud-gaming/%s/*", s.Account, s.Host)})
	}
	return map[string]any{"Version": "2012-10-17", "Statement": stmts}
}

// PolicyMatches reports whether the deployed policy document is this one.
// Both are compared as data, not as text: IAM hands the document back
// reformatted.
func PolicyMatches(deployed []byte, want map[string]any) bool {
	var got any
	if json.Unmarshal(deployed, &got) != nil {
		return false
	}
	wb, _ := json.Marshal(want)
	var w any
	_ = json.Unmarshal(wb, &w)
	return reflect.DeepEqual(got, w)
}

// Zip is the deployment package, byte-identical on every run: a fixed
// timestamp, the file stored rather than deflated (zlib versions compress
// differently), the entry named cloud_watchdog.py with mode 0644. That is what
// lets "is the deployed code current" be one comparison against Lambda's
// CodeSha256, and it reproduces the package the Bash cg has always built so a
// function it deployed reads as current here. It returns the zip and the
// base64 SHA-256 Lambda reports.
func Zip(source []byte) (zip []byte, codeSHA256 string) {
	const name = "cloud_watchdog.py"
	crc := crc32.ChecksumIEEE(source)
	size := uint32(len(source))
	const dosTime, dosDate = 0, 0x21 // 1980-01-01 00:00:00
	le := binary.LittleEndian
	var b bytes.Buffer
	w := func(v any) { _ = binary.Write(&b, le, v) }

	// Local file header.
	w(uint32(0x04034b50))
	w(uint16(20)) // version needed
	w(uint16(0))  // flags
	w(uint16(0))  // stored
	w(uint16(dosTime))
	w(uint16(dosDate))
	w(crc)
	w(size)
	w(size)
	w(uint16(len(name)))
	w(uint16(0))
	b.WriteString(name)
	b.Write(source)
	centralAt := uint32(b.Len())

	// Central directory.
	w(uint32(0x02014b50))
	w(uint16(3<<8 | 20)) // made by: unix, 2.0
	w(uint16(20))
	w(uint16(0))
	w(uint16(0))
	w(uint16(dosTime))
	w(uint16(dosDate))
	w(crc)
	w(size)
	w(size)
	w(uint16(len(name)))
	w(uint16(0)) // extra
	w(uint16(0)) // comment
	w(uint16(0)) // disk
	w(uint16(0)) // internal attributes
	w(uint32(0o644 << 16))
	w(uint32(0)) // offset of the local header
	b.WriteString(name)
	centralSize := uint32(b.Len()) - centralAt

	// End of central directory.
	w(uint32(0x06054b50))
	w(uint16(0))
	w(uint16(0))
	w(uint16(1))
	w(uint16(1))
	w(centralSize)
	w(centralAt)
	w(uint16(0))

	sum := sha256.Sum256(b.Bytes())
	return b.Bytes(), base64.StdEncoding.EncodeToString(sum[:])
}

func sha256b64(b []byte) string {
	sum := sha256.Sum256(b)
	return base64.StdEncoding.EncodeToString(sum[:])
}
