#!/bin/sh
# Sign the Alpine Linux (apk) repository of a garrett release that assemble-release.sh packed. Run it where the apk
# signing key is kept, on a Linux machine with docker: Alpine's own tools run in its official image. The release
# workflow runs it in "publish", after sign-release.sh.
#
#   GARRETT_ALPINE_KEY=<RSA private key, PEM> sh packaging/sign-alpine.sh <release folder>
#
# apk cannot use the OpenPGP key that signs the other repositories: it checks RSA signatures, and finds the public
# key for one in /etc/apk/keys by the file name the signature gives, garrett.rsa.pub. It takes a repository's index
# only with a signature it trusts, and a package from that index only when the package's control section has the
# checksum the index lists for it. The packages carry a signature too, as abuild signs them, so that one fetched by
# itself can be checked as well.
#
# build-packages.sh leaves the packages unsigned in site/alpine/<processor>/. This puts the signature in front of each
# package (replacing one already there), writes each processor's APKINDEX.tar.gz and signs it, checks all of it
# against the public key, and puts that key on the site as garrett.rsa.pub.
set -eu
[ $# -eq 1 ] || { echo "Usage: $0 <release folder>" >&2; exit 1; }
REL=$(CDPATH= cd -- "$1" && pwd)
: "${GARRETT_ALPINE_KEY:?Set GARRETT_ALPINE_KEY to the apk signing key file}"
KEY=$(CDPATH= cd -- "$(dirname -- "$GARRETT_ALPINE_KEY")" && pwd)/$(basename -- "$GARRETT_ALPINE_KEY")
ALPINE_IMAGE=alpine:3.24.4
command -v docker >/dev/null || { echo "docker is required." >&2; exit 1; }
[ -d "$REL/site/alpine/x86_64" ] || { echo "$REL/site/alpine has no packages: build them first (packaging/build-packages.sh)." >&2; exit 1; }
VERSION=$(sed -n '1s/^garrett //p' "$REL/site/update.txt")
docker run --rm -e VERSION="$VERSION" -e OWNER="$(id -u):$(id -g)" -v "$REL/site:/site" -v "$KEY:/key.rsa:ro" "$ALPINE_IMAGE" sh -ec '
  apk add --quiet abuild
  mkdir /keys
  openssl rsa -in /key.rsa -pubout -out /keys/garrett.rsa.pub 2>/dev/null
  for dir in /site/alpine/*/; do
    for package in "$dir"*.apk; do
      # A package is gzip streams one after the other: the signatures, the control section, the data (abuild-gzsplit
      # names them). The signature covers the control stream, which names the SHA-256 of the data stream, so signing
      # again replaces the first stream and leaves the other two as they are.
      work=$(mktemp -d)
      (cd "$work" && abuild-gzsplit < "$package")
      abuild-sign -q -t RSA256 -k /key.rsa -p garrett.rsa.pub "$work/control.tar.gz"
      cat "$work/control.tar.gz" "$work/data.tar.gz" > "$package"
      rm -rf "$work"
    done
    # The index, as abuild writes one: the alias, a package for every processor, is listed under this processor,
    # which is the folder apk fetches it from.
    rm -f "$dir/APKINDEX.tar.gz"
    apk index --quiet --no-warnings --keys-dir /keys --rewrite-arch "$(basename "$dir")" --description "garrett $VERSION" \
      -o "$dir/APKINDEX.tar.gz" "$dir"*.apk
    abuild-sign -q -t RSA256 -k /key.rsa -p garrett.rsa.pub "$dir/APKINDEX.tar.gz"
    apk verify --quiet --keys-dir /keys "$dir"*.apk "$dir/APKINDEX.tar.gz"
  done
  cp /keys/garrett.rsa.pub /site/garrett.rsa.pub
  chown -R "$OWNER" /site/alpine /site/garrett.rsa.pub'
echo "Signed the apk repository for garrett $VERSION; its public key is site/garrett.rsa.pub:"
(cd "$REL/site" && ls alpine/*/APKINDEX.tar.gz)
