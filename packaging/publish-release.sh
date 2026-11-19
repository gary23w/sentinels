#!/bin/sh
# Publish a signed garrett release: the site first (the apt, pacman, rpm and apk repositories, the Scoop manifest,
# the installers, the update list), then the GitHub release, then the Homebrew tap and the Scoop bucket. Run it from
# a checkout of this repository, with git and gh signed in; the release workflow runs it for every tag.
#
#   sh packaging/publish-release.sh <release folder>
#
# The site is the gh-pages branch. Each release is one ordinary commit on top of it. Installed agents find the
# new version through the site's update list within a few hours and install it by themselves.
set -eu
[ $# -eq 1 ] || { echo "Usage: $0 <release folder>" >&2; exit 1; }
REL=$(CDPATH= cd -- "$1" && pwd)
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=$(sed -n '1s/^garrett //p' "$REL/site/update.txt")
for need in site/update.txt.sig site/dists/stable/InRelease site/garrett.gpg dist/SHA256SUMS.asc site/arch/x86_64/sentinels.db.sig site/rpm/repodata/repomd.xml.asc; do
  [ -s "$REL/$need" ] || { echo "$need is missing: sign the release first (packaging/sign-release.sh)." >&2; exit 1; }
done
# The apk repository's indexes and its key are written when it is signed (sign-alpine.sh, which needs docker):
# without them its packages are unsigned, and they do not go out.
if [ -d "$REL/site/alpine" ]; then
  for need in site/garrett.rsa.pub site/alpine/x86_64/APKINDEX.tar.gz site/alpine/aarch64/APKINDEX.tar.gz site/alpine/armv7/APKINDEX.tar.gz; do
    [ -s "$REL/$need" ] || { echo "$need is missing: sign the apk repository first (packaging/sign-alpine.sh), or leave site/alpine out of this release." >&2; exit 1; }
  done
fi
ORIGIN=$(git -C "$HERE" remote get-url origin)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
if git ls-remote --exit-code --heads "$ORIGIN" gh-pages >/dev/null 2>&1; then
  git clone --quiet --depth 1 --branch gh-pages "$ORIGIN" "$WORK/site"
else
  git init --quiet "$WORK/site" && git -C "$WORK/site" checkout --quiet --orphan gh-pages && git -C "$WORK/site" remote add origin "$ORIGIN"
fi
cd "$WORK/site"
git config user.name "$(git -C "$HERE" config user.name)"; git config user.email "$(git -C "$HERE" config user.email)"
# Earlier packages stay in the pool; everything else is replaced by this release.
find . -mindepth 1 -maxdepth 1 ! -name .git ! -name pool -exec rm -rf {} +
cp -R "$REL/site/." .
git add -A
git commit --quiet -m "garrett $VERSION"
git push --quiet origin gh-pages
echo "The site carries garrett $VERSION."
cd "$HERE"
NOTES="$REL/notes.md"
[ -s "$NOTES" ] || sed -n '/^garrett ('"$VERSION"')/,/^ -- /p' debian/changelog | sed '1d;$d' | sed 's/^  //' > "$NOTES"
gh release create "v$VERSION" --title "garrett $VERSION" --notes-file "$NOTES" "$REL"/dist/*
echo "Released: v$VERSION"
# The Homebrew tap, a repository of its own beside this one (brew install <owner>/sentinels/garrett), takes the
# formula for this release. It downloads the files just released, so it goes last. It has no alias: Homebrew 6 loads
# a third-party tap's formula only by its full name or once it is trusted, and trust does not follow an alias.
TAP=$(printf '%s\n' "$ORIGIN" | sed -n 's#.*github\.com[:/]\([^/]*\)/.*#\1#p')/homebrew-sentinels
if [ -s "$REL/packages/homebrew/garrett.rb" ] && gh repo view "$TAP" >/dev/null 2>&1; then
  git clone --quiet "https://github.com/$TAP.git" "$WORK/tap" 2>/dev/null
  mkdir -p "$WORK/tap/Formula"
  cp "$REL/packages/homebrew/garrett.rb" "$WORK/tap/Formula/garrett.rb"
  git -C "$WORK/tap" config user.name "$(git -C "$HERE" config user.name)"; git -C "$WORK/tap" config user.email "$(git -C "$HERE" config user.email)"
  git -C "$WORK/tap" add Formula/garrett.rb
  git -C "$WORK/tap" commit --quiet -m "garrett $VERSION"
  git -C "$WORK/tap" push --quiet origin HEAD:refs/heads/main
  echo "The Homebrew tap $TAP carries garrett $VERSION."
else
  echo "No Homebrew tap at $TAP: the formula is in $REL/packages/homebrew." >&2
fi
# The Scoop bucket, a repository of its own as well (scoop bucket add sentinels https://github.com/<owner>/scoop-sentinels,
# then scoop install garrett), takes the manifest the site carries.
BUCKET=$(printf '%s\n' "$ORIGIN" | sed -n 's#.*github\.com[:/]\([^/]*\)/.*#\1#p')/scoop-sentinels
if [ -s "$REL/site/garrett.json" ] && gh repo view "$BUCKET" >/dev/null 2>&1; then
  git clone --quiet "https://github.com/$BUCKET.git" "$WORK/bucket" 2>/dev/null
  mkdir -p "$WORK/bucket/bucket"
  cp "$REL/site/garrett.json" "$WORK/bucket/bucket/garrett.json"
  git -C "$WORK/bucket" config user.name "$(git -C "$HERE" config user.name)"; git -C "$WORK/bucket" config user.email "$(git -C "$HERE" config user.email)"
  git -C "$WORK/bucket" add bucket/garrett.json
  git -C "$WORK/bucket" commit --quiet -m "garrett $VERSION"
  git -C "$WORK/bucket" push --quiet origin HEAD:refs/heads/main
  echo "The Scoop bucket $BUCKET carries garrett $VERSION."
else
  echo "No Scoop bucket at $BUCKET: the manifest is $REL/site/garrett.json." >&2
fi
echo "winget, the AUR and Chocolatey keep their own copies: sh packaging/submit-packages.sh $REL winget|aur|chocolatey"
