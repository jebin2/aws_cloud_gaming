// Package cg holds the files that run somewhere else - on the AWS box, on a
// user's own server, in Lambda - and ship inside the one binary. They are
// embedded unchanged. go:embed cannot reach a parent directory, which is why
// this package is at the repository root and the importers are below it.
package cg

import "embed"

// Files is the lambda, the box's bootstrap modules and the host scripts.
//
//go:embed lambda/cloud_watchdog.py lib/bootstrap.d host
var Files embed.FS
