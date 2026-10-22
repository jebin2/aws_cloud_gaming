# --- Which Ubuntu a machine is ------------------------------------------------
# ubuntu_release - the Ubuntu release number underneath, for Ubuntu itself and a
# derivative alike: Linux Mint 22.2 is Ubuntu 24.04, and Sunshine publishes its
# packages by the Ubuntu number. Read from the system - Mint keeps the upstream
# release, distro-info maps a codename - never from a table written here.
# Empty when it cannot be told. Expects /etc/os-release already read.
#
# The one copy: the build picks Sunshine's package with it (95-sunshine.sh), and
# cg reads it over ssh with the rest of a machine's facts (lib/host.sh includes
# this file's text). Two copies drifted into facts saying "supported" while the
# package lookup asked for a name that does not exist. POSIX sh: the facts run
# under sh, whatever the login shell is.
ubuntu_release() {
  uv=""
  [ -r /etc/upstream-release/lsb-release ] && uv=$(sed -n 's/^DISTRIB_RELEASE=//p' /etc/upstream-release/lsb-release)
  [ -z "$uv" ] && [ "${ID:-}" = ubuntu ] && uv=${VERSION_ID:-}
  [ -z "$uv" ] && [ -n "${UBUNTU_CODENAME:-}" ] && [ -r /usr/share/distro-info/ubuntu.csv ] \
    && uv=$(awk -F, -v c="$UBUNTU_CODENAME" '$3 == c {v = $1} END {print v}' /usr/share/distro-info/ubuntu.csv | sed 's/ LTS//')
  printf '%s\n' "$uv"
}
