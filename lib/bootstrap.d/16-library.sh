# --- The game library, mirrored to S3 -----------------------------------------
# The games live on the instance store (see 12-scratch.sh), which is wiped on
# every stop. This is what makes that survivable: the library is mirrored to an
# S3 bucket and restored at boot.
#
# The push runs in `cg stop`, in `cg destroy`, and from a unit that fires as the
# machine shuts down - which is what covers the three ways this box stops itself
# without being asked (idle watchdog, CloudWatch alarm, off-site watchdog); all
# three end in a graceful shutdown. There is no periodic timer, so nothing
# uploads while you are playing.
#
# Started with `--no-block` on purpose. The restore of a ~140 GB library takes
# about 10 minutes at the 235 MB/s measured on this instance type, and the rest
# of this build - the NVIDIA driver alone is ~10 minutes - does not need the
# library to exist. So the download runs alongside the build instead of after
# it, and the readiness marker waits for it (see 99-finish.sh). A first-ever run
# finds an empty bucket and returns immediately.
#
# The box reads S3 through an EC2 instance ROLE attached by provision.sh, not an
# access key: there is no secret here to leak or rotate.
progress "installing the S3 game library mirror"
( cd /opt/cloud-gaming-host && bash ./install-library.sh '__S3_BUCKET__' steam ) \
  || echo ">>> FAILED: library mirror install - games will not persist a stop"

# The restore needs credentials from the instance profile. IMDSv2 needs a token,
# and a missing role is worth naming here rather than discovering it as a
# confusing s5cmd permission error 10 minutes into a download.
tok=$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || echo "")
role=$(curl -fsS -H "X-aws-ec2-metadata-token: $tok" \
        "http://169.254.169.254/latest/meta-data/iam/security-credentials/" 2>/dev/null || echo "")
if [[ -z $role ]]; then
  echo ">>> FAILED: no instance role attached - the library cannot reach S3"
else
  echo ">>> ok: instance role $role available"
fi

# --no-block: start the download and carry on with the build.
systemctl start --no-block cg-library-restore.service || true

verify "library mirror installed" test -x /usr/local/bin/cg-library
verify "library restore started" bash -c 'systemctl show -p ActiveState --value cg-library-restore.service | grep -qE "^(active|activating)$"'
verify "mirror on shutdown armed" systemctl is-enabled cg-library-shutdown.service
verify "no background push timer exists" bash -c '! systemctl list-unit-files cg-library-push.timer 2>/dev/null | grep -q enabled'

