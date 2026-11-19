#!/bin/sh
# Build garrett's Alpine Linux packages, unsigned, from the release's Linux bundles. packaging/build-packages.sh runs
# it in Alpine's official image, with abuild, GNU tar and gzip installed:
#
#   SOURCE_DATE_EPOCH=<build time> sh build.sh <folder with the bundles> <version> <output folder>
#
#   <output>/<x86_64|aarch64|armv7>/garrett-<version>-r0.apk     garrett and its OpenRC service
#   <output>/<x86_64|aarch64|armv7>/sentinels-<version>-r0.apk   the alias that installs garrett, the same file in each
#
# A package is made the way abuild makes one (create_apks in abuild): a gzip stream with the control section, which
# is .PKGINFO and the scripts apk runs around installing, upgrading and removing it, then a gzip stream with the
# data, a tar archive of the files with each one's checksum in its header (abuild-tar --hash). .PKGINFO names the
# SHA-256 of the data stream, so a signature over the control stream covers the whole package.
# packaging/sign-alpine.sh puts that signature in front, as a third stream, and writes each processor's index.
set -eu
umask 022
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ $# -eq 3 ] || { echo "Usage: $0 <folder with the bundles> <version> <output folder>" >&2; exit 1; }
BUNDLES=$1; VERSION=$2; OUT=$3
: "${SOURCE_DATE_EPOCH:?Set SOURCE_DATE_EPOCH to the build time written into the packages}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# tar as abuild runs it (apk_tar in abuild's functions.sh): POSIX format, the entries in the order given, no access
# or change times, the build time as every entry's time, and root as every entry's owner.
apk_tar() {
  tar --format=posix --pax-option=exthdr.name=%d/PaxHeaders/%f,atime:=0,ctime:=0 --mtime="@$SOURCE_DATE_EPOCH" \
    --owner=root:0 --group=root:0 --no-recursion -f - -c "$@"
}

# package <name> <arch> <folder with its files> <package file> <dependency> [script...]
# The scripts are files in this folder named <name>.<script>, as abuild names them.
package() {
  name=$1; arch=$2; root=$3; target=$4; depend=$5; shift 5
  control=$WORK/control-$name-$arch
  mkdir -p "$control"
  # Every file and folder, sorted, so that the same files make the same package.
  (cd "$root" && find . | sed -n 's#^\./##p' | LC_ALL=C sort > "$control/files")
  (cd "$root" && apk_tar -T "$control/files" | abuild-tar --hash | gzip -n -9 > "$control/data.tar.gz")
  size=$(find "$root" -type f -exec stat -c %s {} + | awk '{ total += $1 } END { print total + 0 }')
  {
    echo "pkgname = $name"
    echo "pkgver = $VERSION-r0"
    case "$name" in
      garrett) echo "pkgdesc = sentinels agent: host intrusion sentinel that stops what it catches" ;;
      *) echo "pkgdesc = sentinels host intrusion detection and response (installs garrett, its agent)" ;;
    esac
    echo "url = https://github.com/gary23w/sentinels"
    echo "builddate = $SOURCE_DATE_EPOCH"
    echo "packager = sentinels <noreply@sentinels.invalid>"
    echo "size = $size"
    echo "arch = $arch"
    echo "origin = garrett"
    echo "license = MIT"
    echo "depend = $depend"
    echo "datahash = $(sha256sum "$control/data.tar.gz" | cut -d' ' -f1)"
  } > "$control/.PKGINFO"
  metafiles=.PKGINFO
  for script in "$@"; do
    sed 's/\r$//' "$HERE/$name.$script" > "$control/.$script"
    chmod 0755 "$control/.$script"
    metafiles="$metafiles .$script"
  done
  # .PKGINFO first: it is what marks the stream as the control section.
  (cd "$control" && apk_tar $metafiles | abuild-tar --cut | gzip -n -9 > control.tar.gz)
  mkdir -p "$(dirname "$target")"
  cat "$control/control.tar.gz" "$control/data.tar.gz" > "$target"
}

for processor in x86_64 aarch64 armv7; do
  mkdir -p "$WORK/$processor/root"
  tar -xzf "$BUNDLES/garrett-linux-$processor.tar.gz" -C "$WORK/$processor"
  bundle=$WORK/$processor/garrett; root=$WORK/$processor/root
  install -Dm0755 "$bundle/garrett-agent" "$root/usr/lib/garrett/garrett-agent"
  install -Dm0755 "$bundle/unblock" "$root/usr/lib/garrett/unblock"
  install -Dm0755 "$bundle/garrett" "$root/usr/bin/garrett"
  install -Dm0755 "$bundle/garrett.openrc" "$root/etc/init.d/garrett"
  if [ -f "$bundle/garrett.8" ]; then install -Dm0644 "$bundle/garrett.8" "$root/usr/share/man/man8/garrett.8"; fi
  install -Dm0644 "$bundle/LICENSE" "$root/usr/share/licenses/garrett/LICENSE"
  install -Dm0644 "$bundle/NOTICES.md" "$root/usr/share/doc/garrett/NOTICES.md"
  # The scripts start with #!/bin/sh, so the package needs a /bin/sh (abuild adds the same dependency).
  package garrett "$processor" "$root" "$OUT/$processor/garrett-$VERSION-r0.apk" /bin/sh \
    post-install post-upgrade pre-deinstall post-deinstall
done

# The alias: no files of its own, only garrett. It is for every processor ("noarch"): the one package, in each
# processor's folder, where the index lists it under that processor (sign-alpine.sh).
mkdir -p "$WORK/sentinels"
package sentinels noarch "$WORK/sentinels" "$WORK/sentinels-$VERSION-r0.apk" "garrett>=$VERSION-r0"
for processor in x86_64 aarch64 armv7; do cp "$WORK/sentinels-$VERSION-r0.apk" "$OUT/$processor/"; done
