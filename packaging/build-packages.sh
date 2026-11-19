#!/bin/sh
# Build garrett's packages for pacman and rpm, and fill in the files for the other package managers, in a release
# that assemble-release.sh packed. Unsigned: sign-release.sh signs the pacman packages and databases and the rpm
# repository's list.
#
#   sh packaging/build-packages.sh <release folder>
#
#   dist/garrett-<version>-1-<x86_64|aarch64|armv7h>.pkg.tar.zst   pacman: Arch Linux and its relatives
#   dist/sentinels-<version>-1-any.pkg.tar.zst, sentinels-<version>-1.noarch.rpm
#                                                                   the alias that installs garrett
#   dist/garrett-<version>-1.<x86_64|aarch64|armv7hl>.rpm          dnf, yum and zypper: Fedora, RHEL, openSUSE
#   site/arch/<processor>/                                          the pacman repository "sentinels"
#   site/rpm/, site/garrett.repo                                    the rpm repository and its definition
#   site/garrett.json                                               the Scoop manifest
#   packages/                                                       Homebrew, winget and the AUR (with .SRCINFO)
#   packages/rpm/garrett-<version>-1.src.rpm, garrett.spec          the source package COPR builds, and the spec the
#                                                                   openSUSE Build Service builds with the bundles
#
# The packages carry the program files of the release's Linux bundles, so it runs after build-release.py.
# Needs a Linux machine with docker (Arch Linux's own tools run in its official image), rpmbuild (package rpm)
# and createrepo_c (package createrepo-c).
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ $# -eq 1 ] || { echo "Usage: $0 <release folder>" >&2; exit 1; }
REL=$(CDPATH= cd -- "$1" && pwd)
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' "$HERE/rust/Cargo.toml" | head -1)
ARCH_IMAGE=archlinux:base-devel-20261108.0.623074
# Build times written into the packages: the same fixed time as the bundles.
WHEN=1793491200
for tool in docker rpmbuild createrepo_c; do command -v "$tool" >/dev/null || { echo "$tool is required." >&2; exit 1; }; done
python3 -B "$HERE/packaging/package-managers.py" render "$REL"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/arch" "$WORK/aur" "$WORK/out" "$WORK/rpm/SOURCES"
for processor in x86_64 aarch64 armv7; do
  cp "$REL/dist/garrett-linux-$processor.tar.gz" "$WORK/arch/garrett-linux-$processor-$VERSION.tar.gz"
  cp "$REL/dist/garrett-linux-$processor.tar.gz" "$WORK/rpm/SOURCES/"
done
cp "$REL/packages/arch/PKGBUILD" "$REL/packages/arch/garrett.install" "$WORK/arch/"
cp "$REL/packages/aur/PKGBUILD" "$REL/packages/aur/garrett.install" "$WORK/aur/"

# pacman: one package for each processor (makepkg checks each bundle against the PKGBUILD's SHA-256), then the
# repository's database beside them. pacman asks for sentinels.db and sentinels.files: real files, not the links
# repo-add makes, because the site serves no links.
docker run --rm -e SOURCE_DATE_EPOCH="$WHEN" -e OWNER="$(id -u):$(id -g)" -v "$WORK:/work" "$ARCH_IMAGE" sh -ec '
  useradd -m builder
  cp -r /work/arch /work/aur /home/builder/ && chown -R builder /home/builder/arch /home/builder/aur
  for carch in x86_64 aarch64 armv7h; do
    sed "s/^CARCH=.*/CARCH=\"$carch\"/" /etc/makepkg.conf > /home/builder/makepkg-$carch.conf
    su builder -c "cd ~/arch && PACKAGER=\"sentinels <noreply@sentinels.invalid>\" makepkg --config ~/makepkg-$carch.conf --nodeps --noconfirm --force >/dev/null"
    mkdir -p /work/out/arch/$carch
    cp /home/builder/arch/garrett-*-$carch.pkg.tar.zst /work/out/arch/$carch/
  done
  # The alias sentinels is the same for every processor ("any"): the one package, in each repository.
  for carch in x86_64 aarch64 armv7h; do
    cp /home/builder/arch/sentinels-*-any.pkg.tar.zst /work/out/arch/$carch/
    cd /work/out/arch/$carch
    repo-add --quiet sentinels.db.tar.gz *.pkg.tar.zst
    rm sentinels.db sentinels.files
    mv sentinels.db.tar.gz sentinels.db
    mv sentinels.files.tar.gz sentinels.files
  done
  su builder -c "cd ~/aur && makepkg --printsrcinfo" > /work/out/aur.SRCINFO
  chown -R "$OWNER" /work/out
'
mkdir -p "$REL/site/arch"
cp -R "$WORK/out/arch/." "$REL/site/arch/"
# garrett once for each processor, and the alias (the same file in every repository) once.
cp "$WORK"/out/arch/*/garrett-*.pkg.tar.zst "$WORK"/out/arch/x86_64/sentinels-*-any.pkg.tar.zst "$REL/dist/"
# Kept without its leading dot as well: the workflow's artifacts leave out files whose names start with one.
cp "$WORK/out/aur.SRCINFO" "$REL/packages/aur/.SRCINFO"
cp "$WORK/out/aur.SRCINFO" "$REL/packages/aur/SRCINFO"

# rpm: one package for each processor (the spec takes each one's bundle), and the repository's metadata. gzip, which
# every dnf, yum and zypper reads.
sed 's/\r$//' "$HERE/packaging/rpm/garrett.spec" > "$WORK/garrett.spec"
for target in x86_64 aarch64 armv7hl; do
  SOURCE_DATE_EPOCH=$WHEN rpmbuild -bb --quiet --target "$target" --define "_topdir $WORK/rpm" \
    --define "garrett_version $VERSION" \
    --define "_buildhost garrett" --define "use_source_date_epoch_as_buildtime 1" --define "clamp_mtime_to_source_date_epoch 1" \
    "$WORK/garrett.spec"
done
mkdir -p "$REL/site/rpm"
cp "$WORK"/rpm/RPMS/*/*.rpm "$REL/site/rpm/"
cp "$WORK"/rpm/RPMS/*/*.rpm "$REL/dist/"
createrepo_c --quiet --general-compress-type=gz "$REL/site/rpm"

# The source package COPR builds garrett from (submit-packages.sh copr), and its spec, which the openSUSE Build
# Service builds with the three bundles (submit-packages.sh obs). They build it with no --define, so the version is
# written into the spec.
mkdir -p "$REL/packages/rpm"
{ echo "%global garrett_version $VERSION"; cat "$WORK/garrett.spec"; } > "$REL/packages/rpm/garrett.spec"
SOURCE_DATE_EPOCH=$WHEN rpmbuild -bs --quiet --define "_topdir $WORK/rpm" \
  --define "_buildhost garrett" --define "use_source_date_epoch_as_buildtime 1" --define "clamp_mtime_to_source_date_epoch 1" \
  "$REL/packages/rpm/garrett.spec"
cp "$WORK/rpm/SRPMS/garrett-$VERSION-1.src.rpm" "$REL/packages/rpm/"
echo "garrett $VERSION for pacman and rpm:"
(cd "$REL" && ls dist/*.pkg.tar.zst dist/*.rpm site/arch/*/sentinels.db site/rpm/repodata/repomd.xml packages/rpm/*)
