#!/usr/bin/env python3
"""Fill in garrett's package-manager files for a release: the version, the SHA-256 of each file they download,
and the Windows Installer package's product code. Runs on any system with Python 3.9 or newer.

    python3 packaging/package-managers.py render <release folder> [--base-url <url>]
    python3 packaging/package-managers.py chocolatey <output folder> <garrett-windows.msi> [--base-url <url>]
    python3 packaging/package-managers.py product-code <version>

render reads <release folder>/dist/SHA256SUMS and writes:

  packages/arch/PKGBUILD, garrett.install    the project's pacman repository (packaging/build-packages.sh builds it)
  packages/aur/PKGBUILD, garrett.install     the same as garrett-bin, for the AUR
  packages/homebrew/garrett.rb               the formula for the project's Homebrew tap
  packages/winget/manifests/...              the manifests for a pull request to microsoft/winget-pkgs
  site/garrett.json                          the Scoop manifest:  scoop install <site>/garrett.json
  site/garrett.repo                          the rpm repository's definition, for dnf, yum and zypper

chocolatey writes the Chocolatey package's files for one Windows Installer package; the release workflow packs
them with choco pack on the machine that built it.

The files download from the GitHub release of their version. --base-url points them somewhere else instead, for
a test before the release exists (a file:// or http:// folder holding the same files).

The Windows Installer package's product code is derived from the version, so the package (built on Windows) and
the winget manifest (written here) agree without either reading the other.
"""
import hashlib
import re
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPOSITORY = "https://github.com/gary23w/sentinels"
# The namespace the product codes are derived in. Never change it: a new code for an old version breaks upgrades.
PRODUCT_NAMESPACE = uuid.UUID("b23fcb85-6847-4914-b5bc-8fb20739f26e")
PLACEHOLDER = re.compile(r"@(?:VERSION|PRODUCT_CODE|RELEASE_URL|MSI_URL|SHA_[^@\s]+)@")


def version_of_checkout():
    match = re.search(r'^version = "([^"]+)"', (ROOT / "rust" / "Cargo.toml").read_text(), re.M)
    return match.group(1)


def product_code(version):
    return str(uuid.uuid5(PRODUCT_NAMESPACE, "garrett " + version)).upper()


def read_sums(path):
    sums = {}
    for line in path.read_text().splitlines():
        digest, name = line.split("  ", 1)
        sums[name] = digest
    return sums


def fill(template, version, sums, base_url):
    text = (ROOT / template).read_text().replace("\r\n", "\n")
    release_url = base_url or "%s/releases/download/v%s" % (REPOSITORY, version)
    # The templates name their release downloads in full; --base-url swaps that address for another.
    text = text.replace("%s/releases/download/v@VERSION@" % REPOSITORY, release_url)
    text = text.replace("@RELEASE_URL@", release_url).replace("@MSI_URL@", release_url + "/garrett-windows.msi")
    text = text.replace("@VERSION@", version).replace("@PRODUCT_CODE@", product_code(version))

    def digest(match):
        name = match.group(1)
        if name not in sums:
            raise SystemExit("%s needs the SHA-256 of %s, which this release does not have." % (template, name))
        return sums[name]
    text = re.sub(r"@SHA_([^@\s]+)@", digest, text)
    left = PLACEHOLDER.search(text)
    if left:
        raise SystemExit("%s still has %s after filling it in." % (template, left.group(0)))
    return text


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(text.encode("utf-8"))


def aur(pkgbuild):
    """The AUR names a package built from released program files with -bin, beside one built from source. It is the
    one package, garrett-bin, without the repository's alias: the AUR finds it by "sentinels" in its description."""
    body = pkgbuild.split("pkgname=('garrett' 'sentinels')\n", 1)[1].split("\n# The alias:", 1)[0] + "\n"
    head = ("# Maintainer: sentinels <noreply at sentinels dot invalid>\n"
            "# garrett, the agent of sentinels, from the program files of its signed GitHub release.\n"
            "# After installing: systemctl enable --now garrett\n"
            "pkgname=garrett-bin\n")
    body = body.replace("options=('!strip' '!debug')\n", "options=('!strip' '!debug')\nprovides=('garrett')\nconflicts=('garrett')\n", 1)
    return head + body.replace("package_garrett() {", "package() {", 1)


def render(release, base_url):
    sums = read_sums(release / "dist" / "SHA256SUMS")
    version = version_of_checkout()
    packages, site = release / "packages", release / "site"

    def make(template, target):
        write(target, fill(template, version, sums, base_url))
    pkgbuild = fill("packaging/arch/PKGBUILD", version, sums, base_url)
    write(packages / "arch" / "PKGBUILD", pkgbuild)
    write(packages / "aur" / "PKGBUILD", aur(pkgbuild))
    for folder in ("arch", "aur"):
        make("packaging/arch/garrett.install", packages / folder / "garrett.install")
    make("packaging/homebrew/garrett.rb", packages / "homebrew" / "garrett.rb")
    winget = packages / "winget" / "manifests" / "s" / "Sentinels" / "Garrett" / version
    for name in ("Sentinels.Garrett.yaml", "Sentinels.Garrett.installer.yaml", "Sentinels.Garrett.locale.en-US.yaml"):
        make("packaging/winget/" + name, winget / name)
    make("packaging/scoop/garrett.json", site / "garrett.json")
    make("packaging/rpm/garrett.repo", site / "garrett.repo")
    for path in sorted(packages.rglob("*")):
        if path.is_file():
            print(path.relative_to(release).as_posix())
    print("site/garrett.json\nsite/garrett.repo")


def chocolatey(out, msi, base_url):
    version = version_of_checkout()
    sums = {"garrett-windows.msi": hashlib.sha256(msi.read_bytes()).hexdigest()}
    write(out / "garrett.nuspec", fill("packaging/chocolatey/garrett.nuspec", version, sums, base_url))
    for name in ("chocolateyinstall.ps1", "chocolateyuninstall.ps1"):
        write(out / "tools" / name, fill("packaging/chocolatey/tools/" + name, version, sums, base_url))
    # The alias sentinels: a package of its own, beside garrett's files, that installs garrett.
    write(out.parent / (out.name + "-sentinels") / "sentinels.nuspec", fill("packaging/chocolatey/sentinels.nuspec", version, sums, base_url))
    print("Chocolatey package files for garrett %s in %s, and for its alias sentinels in %s-sentinels" % (version, out, out))


def main(arguments):
    base_url = None
    if "--base-url" in arguments:
        at = arguments.index("--base-url")
        base_url = arguments[at + 1].rstrip("/")
        del arguments[at:at + 2]
    if len(arguments) == 2 and arguments[0] == "product-code":
        print(product_code(arguments[1]))
    elif len(arguments) == 2 and arguments[0] == "render":
        render(Path(arguments[1]).resolve(), base_url)
    elif len(arguments) == 3 and arguments[0] == "chocolatey":
        chocolatey(Path(arguments[1]).resolve(), Path(arguments[2]).resolve(), base_url)
    else:
        raise SystemExit(__doc__)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
