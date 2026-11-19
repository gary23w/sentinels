#!/bin/sh
# Turn this Linux machine into your own Sentinel service, in one line. Free: it runs on your machine, nothing is
# sent anywhere else, and there is no account.
#
#   curl -fsSL https://gary23w.github.io/sentinels/service.sh | sudo sh
#
# It downloads one file from the project's GitHub release, garrett-sentinels-linux-<processor>, checks it against
# the SHA-256 pinned here, and runs it. The service, its decision model (crivo-sentinel-v1) and the Sentinel agent
# for this machine are inside that file, so nothing else is fetched. The service and the agent run as daemons
# from then on, started at every boot. It prints the command that joins your other machines to it.
# Options:  --port <number, default 8443>  --address <name or address other machines reach this one by>
#           --memory neuron-db   remember operators' verdicts and show a new case the nearest ones (off by default)
#           --model off          without the decision model (on by default)
#           --wizard             a few questions first: the model that decides, or one of your own, and how much it may decide
# Remove it again:  curl -fsSL .../service.sh | sudo sh -s -- --remove
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
BASE=${GARRETT_BASE:-https://gary23w.github.io/sentinels}
RELEASE_VERSION='1.9.3'
RELEASE=${GARRETT_RELEASE:-https://github.com/gary23w/sentinels/releases/download/v$RELEASE_VERSION}
SENTINELS_SHA_x86_64='727a18608cee0f3b762802cebb241a6dfd7ce41e636e88469a86802997152c6e'
SENTINELS_SHA_aarch64='c68d3c5616c6912f350ef6107cafd47c9332910c041039b4b984ad41df70abe8'
[ "$(id -u)" = 0 ] || { echo "Run this as root (put sudo before sh)." >&2; exit 1; }
[ "$(uname -s)" = Linux ] || { echo "This installer covers Linux. On Windows use service.ps1; elsewhere see serve.mjs in the repository." >&2; exit 1; }
case "$(uname -m)" in
  x86_64|amd64) ARCH=x86_64; WANT=$SENTINELS_SHA_x86_64 ;;
  aarch64|arm64) ARCH=aarch64; WANT=$SENTINELS_SHA_aarch64 ;;
  *) echo "There is no Sentinel service build for $(uname -m). The service runs where Node.js does: see serve.mjs in the repository." >&2; exit 1 ;;
esac
fetch() { if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"; else wget -q "$1" -O "$2"; fi; }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
echo "Fetching garrett-sentinels-linux-$ARCH ..."
fetch "$RELEASE/garrett-sentinels-linux-$ARCH" "$WORK/garrett-sentinels"
HAVE=$(sha256sum "$WORK/garrett-sentinels" | cut -d' ' -f1)
[ "$WANT" = "$HAVE" ] || { echo "The download failed its pinned hash check. Nothing was installed." >&2; exit 1; }
chmod 0755 "$WORK/garrett-sentinels"
GARRETT_BASE=$BASE "$WORK/garrett-sentinels" "$@"
