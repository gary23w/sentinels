#!/bin/sh
# Send a published garrett release to the package registries that keep their own copy of it. Each one needs an
# account there; run this after publish-release.sh, once the release's downloads are live.
#
#   sh packaging/submit-packages.sh <release folder> winget
#       A pull request to microsoft/winget-pkgs with the release's manifests (packages/winget), from a fork of it in
#       the GitHub account gh is signed in to. Its commits are made as sentinels, not as that account's name.
#   sh packaging/submit-packages.sh <release folder> aur
#       Pushes PKGBUILD, garrett.install and .SRCINFO (packages/aur) to the AUR's garrett-bin, with the SSH key the
#       AUR account holds: ssh aur@aur.archlinux.org must work.
#   CHOCOLATEY_API_KEY=<key> sh packaging/submit-packages.sh <release folder> chocolatey
#       Pushes the package (packages/chocolatey) to community.chocolatey.org, where it waits for moderation.
set -eu
[ $# -eq 2 ] || { echo "Usage: $0 <release folder> winget|aur|chocolatey" >&2; exit 1; }
REL=$(CDPATH= cd -- "$1" && pwd)
VERSION=$(sed -n '1s/^garrett //p' "$REL/site/update.txt")
NAME=sentinels; EMAIL=noreply@sentinels.invalid
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
case "$2" in
  winget)
    UPSTREAM=microsoft/winget-pkgs
    FOLDER=manifests/s/Sentinels/Garrett/$VERSION
    [ -d "$REL/packages/winget/$FOLDER" ] || { echo "No winget manifests for $VERSION in $REL/packages/winget." >&2; exit 1; }
    ME=$(gh api user -q .login)
    gh repo fork "$UPSTREAM" --clone=false >/dev/null 2>&1 || true
    gh repo sync "$ME/winget-pkgs" --branch master >/dev/null
    BRANCH=sentinels-garrett-$VERSION
    gh api "repos/$ME/winget-pkgs/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$(gh api "repos/$ME/winget-pkgs/git/ref/heads/master" -q .object.sha)" >/dev/null
    for file in "$REL/packages/winget/$FOLDER"/*.yaml; do
      base64 < "$file" | tr -d '\n' > "$WORK/content"
      gh api -X PUT "repos/$ME/winget-pkgs/contents/$FOLDER/$(basename "$file")" -f branch="$BRANCH" \
        -f message="Sentinels.Garrett $VERSION" -F content=@"$WORK/content" \
        -f "author[name]=$NAME" -f "author[email]=$EMAIL" -f "committer[name]=$NAME" -f "committer[email]=$EMAIL" >/dev/null
    done
    gh pr create --repo "$UPSTREAM" --head "$ME:$BRANCH" --base master --title "New version: Sentinels.Garrett version $VERSION" \
      --body "garrett $VERSION, from its GitHub release: https://github.com/gary23w/sentinels/releases/tag/v$VERSION"
    ;;
  aur)
    git clone --quiet ssh://aur@aur.archlinux.org/garrett-bin.git "$WORK/aur" 2>/dev/null
    cp "$REL/packages/aur/PKGBUILD" "$REL/packages/aur/garrett.install" "$REL/packages/aur/.SRCINFO" "$WORK/aur/"
    git -C "$WORK/aur" add PKGBUILD garrett.install .SRCINFO
    git -C "$WORK/aur" -c user.name="$NAME" -c user.email="$EMAIL" commit --quiet -m "garrett $VERSION"
    git -C "$WORK/aur" push --quiet origin HEAD:master
    echo "The AUR's garrett-bin carries garrett $VERSION."
    ;;
  chocolatey)
    : "${CHOCOLATEY_API_KEY:?Set CHOCOLATEY_API_KEY to the API key of the community.chocolatey.org account}"
    PACKAGE=$REL/packages/chocolatey/garrett.$VERSION.nupkg
    [ -s "$PACKAGE" ] || { echo "No $PACKAGE." >&2; exit 1; }
    # The same request choco push makes, so this runs where Chocolatey is not installed.
    curl -fsS -X PUT -H "X-NuGet-ApiKey: $CHOCOLATEY_API_KEY" -H "X-NuGet-Protocol-Version: 4.1.0" \
      -F "package=@$PACKAGE" https://push.chocolatey.org/api/v2/package/
    echo "garrett $VERSION is with community.chocolatey.org, waiting for moderation."
    ;;
  *) echo "Usage: $0 <release folder> winget|aur|chocolatey" >&2; exit 1 ;;
esac
