#!/bin/sh
# Install garrett on this machine. It works out what kind of machine this is and sets itself up.
#
#   curl -fsSL https://gary23w.github.io/sentinels/install.sh | sudo sh
#
# That alone protects the machine: garrett watches it and ends what is hostile. To join a fleet as well:
#
#   curl -fsSL https://gary23w.github.io/sentinels/install.sh | sudo sh -s -- --server https://your-service --key <enrolment key>
#
# Options:  --server <address>  --key <enrolment key>  --mode kill|decide|pause|report  --label <name>
#
#   Debian, Ubuntu and relatives   adds the signed apt repository and installs the package (64-bit Intel/AMD and ARM)
#   other Linux                    installs the same files from the release bundle, after checking its SHA-256: with
#                                  systemd or OpenRC it runs as a service; 32-bit ARM boards and devices included
#   macOS                          installs a LaunchDaemon from the release bundle, after checking its SHA-256
#
# Once installed, garrett keeps itself current: it installs each new version by itself, after checking that the
# project signed it. Turn that off with UPDATE=off in its configuration file.
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
BASE=${GARRETT_BASE:-https://gary23w.github.io/sentinels}
# The release build updates these bundle hashes before publishing install.sh. The apt key is
# pinned separately so a replacement signing key on the download site cannot authorize a package.
LINUX_X86_SHA='e2bc3f87f051e4a46c9ea163484f01ee8c7c737edda93a4a86783e0b3999d8b1'
LINUX_ARM64_SHA='3c9ae59dbedcbc1f4595cc2760f1e0bdf3a12888b73753a230881372f1e8454e'
LINUX_ARMV7_SHA='ff39140fb3a6d13f470a0f360fec1e9bcacd4b762440141bddc640950ba9e9ae'
MACOS_SHA='fff49cf9273c9eff1a33bf83f4603fcb6208f0cc4f495639a8de726996365f24'
APT_KEY_SHA='1f298d4106a58461a4a16d8976db87e8c5f581a20df180de1f69b73f1a69fa9d'
RELEASE_VERSION='1.9.1'
SERVER=""; KEY=""; MODE=""; LABEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --server) SERVER=$2; shift 2 ;;
    --key) KEY=$2; shift 2 ;;
    --mode) MODE=$2; shift 2 ;;
    --label) LABEL=$2; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done
[ "$(id -u)" = 0 ] || { echo "Run this as root (put sudo before sh)." >&2; exit 1; }
if [ -n "$SERVER" ] && [ -z "$KEY" ] || [ -z "$SERVER" ] && [ -n "$KEY" ]; then echo "Give --server and --key together, or neither." >&2; exit 1; fi
fetch() { if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"; else wget -q "$1" -O "$2"; fi; }
hash_file() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
SYSTEM=$(uname -s)
CONF=/etc/garrett/garrett.conf
[ "$SYSTEM" = Darwin ] && CONF='/Library/Application Support/Garrett/garrett.conf'
if [ "$SYSTEM" = Darwin ]; then
  # The bundle installer checks every root-run path. Check this one first because the
  # enrolment key is written before the bundle is downloaded.
  path=$CONF
  while :; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      [ ! -L "$path" ] || { echo "Unsafe garrett configuration path: $path" >&2; exit 1; }
      [ "$(stat -f %u "$path")" = 0 ] || { echo "Unsafe garrett configuration owner: $path" >&2; exit 1; }
      mode=$(stat -f %p "$path")
      [ $(( 0$mode & 0022 )) -eq 0 ] || { echo "Writable garrett configuration path: $path" >&2; exit 1; }
      acl=$(ls -lde "$path")
      case "$acl" in *' allow '*) echo "Unverified garrett configuration ACL: $path" >&2; exit 1 ;; esac
    fi
    [ "$path" = / ] && break
    path=${path%/*}
    [ -n "$path" ] || path=/
  done
fi

# The configuration goes down first, so the service finds it the moment it starts.
if [ -n "$SERVER$MODE$LABEL" ]; then
  mkdir -p "$(dirname "$CONF")"
  [ ! -L "$CONF" ] || { echo "The garrett configuration path is a symbolic link." >&2; exit 1; }
  # Tighten an existing file before writing the key; create a new one under a private umask.
  [ ! -e "$CONF" ] || chmod 0600 "$CONF"
  previous_umask=$(umask)
  umask 077
  : > "$CONF"
  chmod 0600 "$CONF"
  [ -z "$SERVER" ] || printf 'SERVER=%s\nENROLL_KEY=%s\n' "$SERVER" "$KEY" >> "$CONF"
  [ -z "$MODE" ] || printf 'MODE=%s\n' "$MODE" >> "$CONF"
  [ -z "$LABEL" ] || printf 'LABEL=%s\n' "$LABEL" >> "$CONF"
  chmod 0600 "$CONF"
  umask "$previous_umask"
fi

bundle() {
  # $1 = bundle name, $2 = this script's pinned hash.
  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT
  fetch "$BASE/$1" "$WORK/$1"
  [ "$(hash_file "$WORK/$1")" = "$2" ] || { echo "The bundle failed its pinned hash check. Nothing was installed." >&2; exit 1; }
  tar -xzf "$WORK/$1" -C "$WORK"
  sh "$WORK/garrett/install.sh"
}

# The apt repository carries packages for 64-bit Intel/AMD and 64-bit ARM. Anything else takes the bundle.
PACKAGED=no
if [ "$SYSTEM" = Linux ] && command -v apt-get >/dev/null 2>&1 && command -v dpkg >/dev/null 2>&1; then
  case "$(dpkg --print-architecture 2>/dev/null)" in amd64|arm64) PACKAGED=yes ;; esac
fi
if [ "$PACKAGED" = yes ]; then
  mkdir -p /usr/share/keyrings
  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT
  fetch "$BASE/garrett.gpg" "$WORK/garrett.gpg"
  [ "$(hash_file "$WORK/garrett.gpg")" = "$APT_KEY_SHA" ] || { echo "The apt signing key failed its pinned hash check. Nothing was installed." >&2; exit 1; }
  install -m 0644 "$WORK/garrett.gpg" /usr/share/keyrings/garrett.gpg
  echo "deb [signed-by=/usr/share/keyrings/garrett.gpg] $BASE stable main" > /etc/apt/sources.list.d/garrett.list
  chmod 0644 /usr/share/keyrings/garrett.gpg /etc/apt/sources.list.d/garrett.list
  apt-get update -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/garrett.list -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0 >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y "garrett=$RELEASE_VERSION"
elif [ "$SYSTEM" = Linux ]; then
  case "$(uname -m)" in
    x86_64|amd64) bundle garrett-linux-x86_64.tar.gz "$LINUX_X86_SHA" ;;
    aarch64|arm64) bundle garrett-linux-aarch64.tar.gz "$LINUX_ARM64_SHA" ;;
    armv7l|armv8l) bundle garrett-linux-armv7.tar.gz "$LINUX_ARMV7_SHA" ;;
    *) echo "garrett is built for 64-bit Intel/AMD, 64-bit ARM and 32-bit ARMv7 machines. This one is $(uname -m)." >&2; exit 1 ;;
  esac
elif [ "$SYSTEM" = Darwin ]; then
  bundle garrett-macos.tar.gz "$MACOS_SHA"
else
  echo "This installer covers Linux and macOS. For Windows, download garrett-windows.zip from the releases page." >&2
  exit 1
fi
if [ "$SYSTEM" = Darwin ]; then
  if [ -n "$SERVER" ]; then echo "garrett is installed and is enrolling with $SERVER."; else echo 'garrett is installed and protecting this machine. See what it finds: sudo "/Library/Application Support/Garrett/garrett" cases'; fi
elif [ -n "$SERVER" ]; then echo "garrett is installed and is enrolling with $SERVER."; else echo "garrett is installed and protecting this machine. See what it finds: garrett cases"; fi
