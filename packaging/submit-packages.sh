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
#   sh packaging/submit-packages.sh <release folder> copr
#       Builds garrett and its alias sentinels from the release's source package (packages/rpm) in the COPR project
#       garrett of the account copr-cli works as, and waits for the builds: for every Fedora release COPR builds for
#       and EPEL 9 and later, on x86_64 and aarch64. It creates the project the first time, and sets its
#       description, its instructions and those chroots each time. It needs copr-cli, and takes the account's
#       copr-cli configuration from COPR_CONFIG (the release workflow's secret: the file copr.fedorainfracloud.org/api
#       gives), or uses copr-cli's own (~/.config/copr).
#   sh packaging/submit-packages.sh <release folder> obs
#       Commits the release's spec (packages/rpm) and Linux bundles to the package garrett in the home project of the
#       openSUSE Build Service account OBS_USER, which builds it for the repositories that project has. It creates
#       the package the first time. It takes the account's password from OBS_PASSWORD (the release workflow's
#       secret), or asks for both without showing the password.
set -eu
[ $# -eq 2 ] || { echo "Usage: $0 <release folder> winget|aur|chocolatey|copr|obs" >&2; exit 1; }
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
  copr)
    SRPM=$REL/packages/rpm/garrett-$VERSION-1.src.rpm
    [ -s "$SRPM" ] || { echo "No $SRPM (build-packages.sh builds it)." >&2; exit 1; }
    command -v copr-cli >/dev/null || { echo "copr-cli is required (pipx install copr-cli)." >&2; exit 1; }
    # The configuration holds the account's API token: from the environment into a file only this user can read.
    if [ -n "${COPR_CONFIG:-}" ]; then
      (umask 077 && printf '%s\n' "$COPR_CONFIG" > "$WORK/copr")
      copr() { copr-cli --config "$WORK/copr" "$@"; }
    else
      copr() { copr-cli "$@"; }
    fi
    OWNER=$(copr whoami)
    # The chroots: each Fedora release COPR builds for (not rawhide) and EPEL 9 and later, on the two processors
    # COPR builds for that garrett has a program for. COPR drops a release's chroots once it no longer builds for it.
    OFFERED=$(copr list-chroots)
    set --
    for chroot in $(printf '%s\n' "$OFFERED" | awk -F- '/^(fedora|epel)-[0-9]+-(x86_64|aarch64)$/ && ($1 == "fedora" || $2 >= 9)'); do
      set -- "$@" --chroot "$chroot"
    done
    [ $# -gt 0 ] || { echo "COPR lists no Fedora or EPEL chroots for x86_64 or aarch64." >&2; exit 1; }
    # Markdown, as COPR shows them on the project's page.
    DESCRIPTION=$(printf '%s\n' \
      "garrett, the agent of [sentinels](https://github.com/gary23w/sentinels), watches the machine's running programs and their connections, scores them on the machine, and pauses or ends a program it judges hostile." \
      "" \
      "These packages carry the program files of the project's GitHub releases. MIT license." \
      "" \
      "- Source, releases and documentation: https://github.com/gary23w/sentinels" \
      "- https://garrettstimpson.ca/")
    INSTRUCTIONS=$(printf '%s\n' \
      "Fedora, and RHEL 9 and later and its relatives:" \
      "" \
      "    sudo dnf copr enable $OWNER/garrett" \
      "    sudo dnf install garrett" \
      "    sudo systemctl enable --now garrett" \
      "" \
      "The name sentinels installs garrett as well.")
    if copr get "$OWNER/garrett" >/dev/null 2>&1; then
      copr modify "$@" --description "$DESCRIPTION" --instructions "$INSTRUCTIONS" garrett
    else
      copr create "$@" --description "$DESCRIPTION" --instructions "$INSTRUCTIONS" garrett
    fi
    copr build garrett "$SRPM"
    echo "COPR's $OWNER/garrett carries garrett $VERSION: https://copr.fedorainfracloud.org/coprs/$OWNER/garrett/"
    ;;
  obs)
    SPEC=$REL/packages/rpm/garrett.spec
    [ -s "$SPEC" ] || { echo "No $SPEC (build-packages.sh writes it)." >&2; exit 1; }
    grep -qx "%global garrett_version $VERSION" "$SPEC" || { echo "$SPEC is not for garrett $VERSION." >&2; exit 1; }
    for processor in x86_64 aarch64 armv7; do
      [ -s "$REL/dist/garrett-linux-$processor.tar.gz" ] || { echo "No $REL/dist/garrett-linux-$processor.tar.gz." >&2; exit 1; }
    done
    ACCOUNT=${OBS_USER:-}
    [ -n "$ACCOUNT" ] || { printf 'openSUSE Build Service account: ' >&2; read -r ACCOUNT; }
    PASSWORD=${OBS_PASSWORD:-}
    if [ -z "$PASSWORD" ]; then
      printf 'Password of the openSUSE Build Service account %s (not shown): ' "$ACCOUNT" >&2
      stty -echo 2>/dev/null || true; read -r PASSWORD; stty echo 2>/dev/null || true; echo >&2
    fi
    [ -n "$ACCOUNT" ] && [ -n "$PASSWORD" ] || { echo "No account given; nothing was sent." >&2; exit 1; }
    # The API takes the account's name and password (HTTP basic authentication): they go to curl on standard input,
    # never on a command line.
    AUTH=$(printf '%s:%s' "$ACCOUNT" "$PASSWORD" | base64 | tr -d '\n')
    PASSWORD=
    obs() { printf 'Authorization: Basic %s\n' "$AUTH" | curl -fsS -H @- "$@"; }
    PROJECT=home:$ACCOUNT
    PACKAGE=https://api.opensuse.org/source/$PROJECT/garrett
    # The package, the first time: its description and its link to the project.
    CODE=$(printf 'Authorization: Basic %s\n' "$AUTH" | curl -sS -o /dev/null -w '%{http_code}' -H @- "$PACKAGE/_meta")
    case $CODE in
      200) ;;
      404)
        cat > "$WORK/meta.xml" <<META
<package name="garrett" project="$PROJECT">
  <title>garrett, the agent of sentinels</title>
  <description>garrett, the agent of sentinels, watches the machine's running programs and their connections, scores them on the machine, and pauses or ends a program it judges hostile.

These packages carry the program files of the project's GitHub releases. MIT license.

Source, releases and documentation: https://github.com/gary23w/sentinels
https://garrettstimpson.ca/</description>
  <url>https://github.com/gary23w/sentinels</url>
</package>
META
        obs -X PUT -H "Content-Type: application/xml" -T "$WORK/meta.xml" "$PACKAGE/_meta" >/dev/null
        ;;
      *) echo "The openSUSE Build Service answered $CODE for $PROJECT/garrett." >&2; exit 1 ;;
    esac
    # The spec and the three bundles, in one commit: each file uploaded (rev=upload), then the upload committed (a
    # POST with cmd=commit).
    for file in "$SPEC" "$REL/dist/garrett-linux-x86_64.tar.gz" "$REL/dist/garrett-linux-aarch64.tar.gz" "$REL/dist/garrett-linux-armv7.tar.gz"; do
      obs -X PUT -T "$file" "$PACKAGE/$(basename "$file")?rev=upload" >/dev/null
    done
    obs -d '' "$PACKAGE?cmd=commit&comment=garrett%20$VERSION" >/dev/null
    AUTH=
    echo "$PROJECT/garrett on the openSUSE Build Service carries garrett $VERSION: https://build.opensuse.org/package/show/$PROJECT/garrett"
    ;;
  *) echo "Usage: $0 <release folder> winget|aur|chocolatey|copr|obs" >&2; exit 1 ;;
esac
