#!/usr/bin/env bash
# The build, assembled: lib/bootstrap.d's modules as one script, for any machine
# cg sets up. The AWS box gets it as user-data (lib/provision.sh); a machine of
# yours gets it over ssh (lib/host.sh). One assembly, so both run the same steps
# - the modules themselves decide what each kind of machine needs (aws_box).
#
# render_bootstrap > file - reads its placeholders from the environment:
#   CG_TARGET  aws | host        CG_USER    whose desktop it is
#   CG_FAMILY  ubuntu | debian | arch | fedora
#   TS_AUTHKEY TS_HOST           joining the tailnet (empty: already on it)
#   HOST_TGZ_URL S3_BUCKET CG_APPS CG_LOGIN CG_RESERVE_GB   the AWS box's own
# Every __PLACEHOLDER__ in the modules must have a value, or nothing is written:
# a placeholder left in the script is a build that fails on the machine, late.
render_bootstrap() {
  local parts=() f
  shopt -s nullglob
  parts=(lib/bootstrap.d/*.sh)
  shopt -u nullglob
  (( ${#parts[@]} )) || { echo "no bootstrap modules found in lib/bootstrap.d/" >&2; return 1; }
  # Comments are ~47% of the module source and the single most valuable thing
  # in this repo - every one of them records a failure that cost a build. The
  # machine does not need them, so whole-line comments are stripped here and
  # kept in git. Shebangs are exempt: `#!` lines matter inside the heredocs that
  # write the on-host scripts. On AWS this is what keeps user-data inside its
  # 16 KB.
  #
  # Substituted in python, not sed. A presigned URL is full of `&`, and in a sed
  # replacement an unescaped `&` means "the entire matched text" - so every
  # separator in the URL once came out as the literal placeholder, curl got a
  # 400, and the build died before tailscale existed. These are literal
  # replacements, so a tool that does literal replacement does them.
  cat "${parts[@]}" | grep -vE '^[[:space:]]*#([^!]|$)' | render_placeholders
}

# render_placeholders - stdin to stdout, every __NAME__ replaced by $NAME from
# the environment; refuses, writing nothing, when any has no value.
render_placeholders() {
  python3 -c 'import os, re, sys
s = sys.stdin.read()
toks = sorted(set(re.findall(r"__([A-Z0-9_]+)__", s)))
unknown = [t for t in toks if t not in os.environ]
if unknown:
    sys.exit("no value for placeholder(s): %s" % ", ".join(unknown))
for t in toks:
    s = s.replace("__%s__" % t, os.environ[t])
sys.stdout.write(s)'
}
