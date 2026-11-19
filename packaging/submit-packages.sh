#!/bin/sh
# Send a published garrett release to the package registries that keep their own copy of it. Each one needs an
# account there; run this after publish-release.sh, once the release's downloads are live.
#
#   sh packaging/submit-packages.sh <release folder> winget
#       A pull request to microsoft/winget-pkgs with the release's manifests (packages/winget), from a fork of it in
#       the GitHub account gh is signed in to. Its commits are made as sentinels, not as that account's name.
#   sh packaging/submit-packages.sh <release folder> aur
#       Pushes PKGBUILD, garrett.install and .SRCINFO (packages/aur) to the AUR's garrett-bin, with the SSH key the
#       AUR account holds: ssh aur@aur.archlinux.org must work (GIT_SSH_COMMAND="ssh -i <key>" picks the key).
#   sh packaging/submit-packages.sh <release folder> chocolatey
#       Pushes garrett and its alias sentinels (packages/chocolatey) to community.chocolatey.org, where they wait for
#       moderation. It takes the account's API key from CHOCOLATEY_API_KEY (the release workflow's secret), or asks
#       for it without showing it.
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
    # The title the repository asks for: a package it does not have yet is new, otherwise it is an update.
    if gh api "repos/$UPSTREAM/contents/manifests/s/Sentinels/Garrett" >/dev/null 2>&1; then TITLE="Update: Sentinels.Garrett to $VERSION"; else TITLE="New package: Sentinels.Garrett version $VERSION"; fi
    cat > "$WORK/body.md" <<BODY
## 📖 Description

Sentinels.Garrett $VERSION: garrett, the Sentinel agent (MIT, https://github.com/gary23w/sentinels), from its GitHub release https://github.com/gary23w/sentinels/releases/tag/v$VERSION. The installer is garrett-windows.msi (WiX, per-machine, silent with /qn).

## ✅ Checklist

- [ ] Signed the [Contributor License Agreement](https://cla.opensource.microsoft.com)
- [ ] Linked to an issue (if applicable)

## 📦 Manifest Checklist

- [x] Checked that there aren't other open [pull requests](https://github.com/microsoft/winget-pkgs/pulls) for the same manifest update/change
- [x] This PR only modifies one (1) manifest
- [x] Validated manifest locally with \`winget validate --manifest <path>\`
- [ ] Tested manifest locally with \`winget install --manifest <path>\` (the MSI's install, upgrade and removal are tested on Windows in the project's release workflow)
- [x] Manifest conforms to the [1.28 schema](https://github.com/microsoft/winget-pkgs/tree/master/doc/manifest/schema/1.28.0)
BODY
    gh pr create --repo "$UPSTREAM" --head "$ME:$BRANCH" --base master --title "$TITLE" --body-file "$WORK/body.md"
    ;;
  aur)
    git clone --quiet ssh://aur@aur.archlinux.org/garrett-bin.git "$WORK/aur" 2>/dev/null
    [ -s "$REL/packages/aur/SRCINFO" ] || { echo "No $REL/packages/aur/SRCINFO (build-packages.sh writes it)." >&2; exit 1; }
    cp "$REL/packages/aur/PKGBUILD" "$REL/packages/aur/garrett.install" "$WORK/aur/"
    cp "$REL/packages/aur/SRCINFO" "$WORK/aur/.SRCINFO"
    git -C "$WORK/aur" add PKGBUILD garrett.install .SRCINFO
    git -C "$WORK/aur" -c user.name="$NAME" -c user.email="$EMAIL" commit --quiet -m "garrett $VERSION"
    git -C "$WORK/aur" push --quiet origin HEAD:master
    echo "The AUR's garrett-bin carries garrett $VERSION."
    ;;
  chocolatey)
    # garrett first, then sentinels, the alias that depends on it.
    for name in garrett sentinels; do
      [ -s "$REL/packages/chocolatey/$name.$VERSION.nupkg" ] || { echo "No $REL/packages/chocolatey/$name.$VERSION.nupkg." >&2; exit 1; }
    done
    # The key comes from the environment or is asked for and not shown, and goes to curl on standard input, never on
    # a command line.
    KEY=${CHOCOLATEY_API_KEY:-}
    if [ -z "$KEY" ]; then
      printf 'API key of the community.chocolatey.org account (not shown): ' >&2
      stty -echo 2>/dev/null || true; read -r KEY; stty echo 2>/dev/null || true; echo >&2
    fi
    [ -n "$KEY" ] || { echo "No key given; nothing was pushed." >&2; exit 1; }
    for name in garrett sentinels; do
      # The same request choco push makes, so this runs where Chocolatey is not installed.
      printf 'X-NuGet-ApiKey: %s\n' "$KEY" | curl -fsS -X PUT -H @- -H "X-NuGet-Protocol-Version: 4.1.0" \
        -F "package=@$REL/packages/chocolatey/$name.$VERSION.nupkg" https://push.chocolatey.org/api/v2/package/
      echo " $name $VERSION is with community.chocolatey.org, waiting for moderation."
    done
    KEY=
    ;;
  *) echo "Usage: $0 <release folder> winget|aur|chocolatey" >&2; exit 1 ;;
esac
