# Layout and tests

Where things are, and how the test suites prove the risky paths without spending money.

## Layout

    cg                 the front door - every command
    lib/setup, lib/game  what cg dispatches into
    lib/               provisioning and cloud-init internals
    host/              units deployed to the instance (watchdog, disk monitor, S3 mirror)
    lambda/            the cloud watchdog, deployed as a zip to AWS Lambda
    tests/             offline tests for the fiddly host-side logic
    docs/              everything linked from the README

`./tests/run-all.sh` runs every suite and **exits non-zero if any fails** - which the obvious
`for t in tests/*.sh; do ... && echo PASS || echo FAIL; done` does not, because the last command
in the loop is the `echo`. That returned 0 on a red suite and a `&& git commit` chained after it
committed anyway.

`./tests/steam-library.sh` checks the Steam library registration - the part that has broken
most often - against a faked Steam install, so it can be verified without spending a build.
`tests/library-guards.sh` and `tests/library-perapp.sh` do the same for the S3 mirror's refusals, which is the code whose failure
mode is losing every game rather than an error message. `./tests/destroy-all.sh` covers
`cg destroy --all`, the one command that can delete the archive - proving that path with stubs
rather than by performing it, which is a lesson learned the hard way.
