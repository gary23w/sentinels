#!/bin/sh
# Pack a garrett release from the program files the release workflow built. Unsigned: sign-release.sh does that.
#
#   sh packaging/assemble-release.sh <folder the built program files were downloaded to> <output folder>
#
#   <output>/dist       for the GitHub release: Debian, pacman and rpm packages, the Windows Installer package,
#                       bundles, program files, SHA256SUMS
#   <output>/site       for the project's site: apt, pacman, rpm and apk repositories, the Scoop manifest, installers,
#                       update list, manual, the same downloads
#   <output>/packages   for the package managers that keep their own copy: the Homebrew formula, the winget
#                       manifests, the AUR's PKGBUILD and the Chocolatey package (packaging/build-packages.sh)
#
# Needs a Debian or Ubuntu machine with: build-essential debhelper apt-utils mandoc python3 npm curl docker rpm
# createrepo-c
# It fetches the official Node.js builds and the decision model's files, each checked against the SHA-256 here.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ $# -eq 2 ] || { echo "Usage: $0 <built program files> <output folder>" >&2; exit 1; }
BUILT=$(CDPATH= cd -- "$1" && pwd); OUT=$2
rm -rf "$OUT"; mkdir -p "$OUT/agents" "$OUT/dist" "$OUT/site"
OUT=$(CDPATH= cd -- "$OUT" && pwd)
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' "$HERE/rust/Cargo.toml" | head -1)
head -1 "$HERE/debian/changelog" | grep -q "($VERSION)" || { echo "debian/changelog does not start with version $VERSION." >&2; exit 1; }
NAMES="garrett-linux-x86_64 garrett-linux-aarch64 garrett-linux-armv7 garrett-macos garrett-windows.exe"
STUBS="garrett-installer-linux-x86_64 garrett-installer-linux-aarch64 garrett-installer-windows.exe"
mkdir -p "$OUT/installers" "$OUT/node" "$OUT/model"
for name in $NAMES $STUBS; do
  case "$name" in garrett-installer-*) INTO=$OUT/installers ;; *) INTO=$OUT/agents ;; esac
  # A download from the workflow puts each file in a folder of its own name.
  if [ -f "$BUILT/$name/$name" ]; then cp "$BUILT/$name/$name" "$INTO/$name"; else cp "$BUILT/$name" "$INTO/$name"; fi
done
# The Windows Installer package (packaging/windows/garrett.wxs) and the Chocolatey package that installs it, both
# made on the Windows build machine, where the package was built and tested.
cp "$BUILT/garrett-windows.msi/garrett-windows.msi" "$OUT/dist/garrett-windows.msi"
mkdir -p "$OUT/packages/chocolatey"
cp "$BUILT/garrett-chocolatey/garrett.$VERSION.nupkg" "$BUILT/garrett-chocolatey/sentinels.$VERSION.nupkg" "$OUT/packages/chocolatey/"
# The Node.js runtime the one-file installers carry: the official builds, checked against their published digests.
NODE_VERSION=v24.22.3
fetch_checked() { curl -fsSL "$1" -o "$2"; [ "$(sha256sum "$2" | cut -d' ' -f1)" = "$3" ] || { echo "$2 does not match its digest." >&2; exit 1; }; }
fetch_checked "https://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION-linux-x64.tar.gz" "$OUT/node/linux-x64.tar.gz" 061ec3e3062115705b56b51fa9cc330ab50d34b6969387d4e4b1a50c6809acc2
fetch_checked "https://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION-linux-arm64.tar.gz" "$OUT/node/linux-arm64.tar.gz" 261af2af250dfd7e9f25cf151d1b2713a0adf8f10a9ad116c4947f68627affe8
fetch_checked "https://nodejs.org/dist/$NODE_VERSION/win-x64/node.exe" "$OUT/node/node-win-x64.exe" 86fc4785327db5f5c7558dc6156c543b433c313e813a222e088086222ab4afa6
for arch in x64 arm64; do tar -xzf "$OUT/node/linux-$arch.tar.gz" -C "$OUT/node" "node-$NODE_VERSION-linux-$arch/bin/node"; mv "$OUT/node/node-$NODE_VERSION-linux-$arch/bin/node" "$OUT/node/node-linux-$arch"; rm -rf "$OUT/node/node-$NODE_VERSION-linux-$arch" "$OUT/node/linux-$arch.tar.gz"; done
# The decision model that comes with the service, from its repository, checked against the digests here.
MODEL_BASE=${GARRETT_MODEL_BASE:-https://huggingface.co/gary23w/crivo-sentinel-v1/resolve/main}
while read -r name sum; do fetch_checked "$MODEL_BASE/$name" "$OUT/model/$name" "$sum"; done <<MODEL
model.onnx 61f09b1d40bfbbbaf0e94c74f005f8ce05ce5e7861d1a89bfb8a397fbdf24ce6
tokenizer.json edeac9e7b2f170022cefd1c7b396ebca3ac9c57f2f93604844cb7fb16b1a71ca
tokenizer_config.json 83d71bb83ca42bac8aaa185256df0c5f5dcc36f5d7ebe42dbe7e93c842958ab7
config.json 254cc8a25ce50711656bb2696646be53a7065103605d304391dc7c08056cdfd5
MODEL
sh "$HERE/packaging/build-deb.sh" "$OUT/dist" amd64 "$OUT/agents/garrett-linux-x86_64"
sh "$HERE/packaging/build-deb.sh" "$OUT/dist" arm64 "$OUT/agents/garrett-linux-aarch64"
sh "$HERE/packaging/make-apt-repo.sh" "$OUT/dist" "$OUT/site"
# The program files by themselves: what an installed agent downloads when it updates itself.
for name in $NAMES; do cp "$OUT/agents/$name" "$OUT/dist/$name"; done
sed 's/\r$//' "$HERE/deploy/kubernetes-daemonset.yaml" > "$OUT/dist/kubernetes-daemonset.yaml"
# The service's optional memory engine: the newest neuron-db release, packed into the service bundles.
(cd "$HERE/server" && ONNXRUNTIME_NODE_INSTALL=skip npm install --omit=dev --no-audit --no-fund >/dev/null)
python3 -B "$HERE/packaging/build-release.py" "$OUT/dist" --agents "$OUT/agents" --installers "$OUT/installers" --node "$OUT/node" --model "$OUT/model" --all
# The pacman and rpm packages, built from the Linux bundles just made, and the other package managers' files;
# then SHA256SUMS again, so that it lists the new packages too.
sh "$HERE/packaging/build-packages.sh" "$OUT"
python3 -B "$HERE/packaging/build-release.py" "$OUT/dist" --sums-only
# The update list: the version, then the SHA-256 of each program file. An agent installs nothing this list
# does not name, and nothing at all unless the list carries the project's signature.
{ echo "garrett $VERSION"; for name in $NAMES; do grep "  $name\$" "$OUT/dist/SHA256SUMS"; done; } > "$OUT/site/update.txt"
[ "$(wc -l < "$OUT/site/update.txt")" = 6 ] || { echo "The update list is incomplete." >&2; exit 1; }
for name in $NAMES garrett-linux-x86_64.tar.gz garrett-linux-aarch64.tar.gz garrett-linux-armv7.tar.gz garrett-macos.tar.gz garrett-windows.zip garrett-service.tar.gz garrett-service-windows.zip SHA256SUMS; do cp "$OUT/dist/$name" "$OUT/site/$name"; done
for name in service.sh service.ps1; do sed 's/\r$//' "$HERE/packaging/$name" > "$OUT/site/$name"; done
# A checksum fetched beside a bundle cannot authenticate it. Give the first-install scripts the
# exact bundle hashes from this release before the site is signed and published.
python3 -B "$HERE/packaging/pin-release-installers.py" "$OUT/dist/SHA256SUMS" "$OUT/site"
# The site's front page, and the manual as a page.
sed "s/@VERSION@/$VERSION/g" "$HERE/packaging/site/index.html" > "$OUT/site/index.html"
# The site's other pages and the files that help it be found, as they are.
for name in "$HERE"/packaging/site/*; do case "${name##*/}" in index.html|manual.html) ;; *) cp "$name" "$OUT/site/";; esac; done
{ sed -n '1,/@MANUAL@/p' "$HERE/packaging/site/manual.html" | sed '$d'; mandoc -T html -O fragment "$HERE/debian/garrett.8"; sed -n '/@MANUAL@/,$p' "$HERE/packaging/site/manual.html" | sed '1d'; } > "$OUT/site/manual.html"
: > "$OUT/site/.nojekyll"
rm -rf "$OUT/agents" "$OUT/installers" "$OUT/node" "$OUT/model"
echo "garrett $VERSION, unsigned:"; (cd "$OUT" && find dist site packages -type f | sort)
