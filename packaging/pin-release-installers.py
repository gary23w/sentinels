"""Put this release's bundle hashes in the first-install scripts before they are published."""

import re
import sys
from pathlib import Path


if len(sys.argv) != 3:
    raise SystemExit("Usage: pin-release-installers.py <SHA256SUMS> <site folder>")

root = Path(__file__).resolve().parent.parent
sums_file, site = Path(sys.argv[1]), Path(sys.argv[2])
raw = sums_file.read_bytes()
if len(raw) > 65536:
    raise SystemExit("The release checksum list is too large.")

sums = {}
for line in raw.decode("ascii").splitlines():
    match = re.fullmatch(r"([0-9a-f]{64})  ([a-z0-9._-]+)", line)
    if not match or match[2] in sums:
        raise SystemExit("The release checksum list has an invalid or duplicate entry.")
    sums[match[2]] = match[1]


def pinned(source, assignments, separator):
    text = (root / source).read_text(encoding="utf-8").replace("\r\n", "\n")
    for variable, filename in assignments.items():
        digest = sums.get(filename)
        if digest is None:
            raise SystemExit("The release checksum list is missing " + filename)
        pattern = rf"(?m)^{re.escape(variable)}{separator}'[0-9a-f]{{64}}'$"
        text, count = re.subn(pattern, lambda _: f"{variable}{separator}'{digest}'", text)
        if count != 1:
            raise SystemExit("The installer has no single pin for " + filename)
    return text


windows = pinned("packaging/install.ps1", {"$pinnedWindowsZip": "garrett-windows.zip"}, " = ")
unix = pinned("packaging/install.sh", {
    "LINUX_X86_SHA": "garrett-linux-x86_64.tar.gz",
    "LINUX_ARM64_SHA": "garrett-linux-aarch64.tar.gz",
    "LINUX_ARMV7_SHA": "garrett-linux-armv7.tar.gz",
    "MACOS_SHA": "garrett-macos.tar.gz",
}, "=")
if len(re.findall(r"(?m)^APT_KEY_SHA='[0-9a-f]{64}'$", unix)) != 1:
    raise SystemExit("The installer has no single apt key pin.")
version = re.search(r'(?m)^version = "([0-9]+(?:\.[0-9]+){1,3})"$',
                    (root / "rust/Cargo.toml").read_text(encoding="utf-8"))
if not version:
    raise SystemExit("The release version is missing.")
unix, count = re.subn(r"(?m)^RELEASE_VERSION='[0-9]+(?:\.[0-9]+){1,3}'$",
                      lambda _: "RELEASE_VERSION='" + version[1] + "'", unix)
if count != 1:
    raise SystemExit("The installer has no single release version pin.")

(site / "install.ps1").write_bytes(windows.encode("utf-8"))
(site / "install.sh").write_bytes(unix.encode("utf-8"))
print("Pinned Windows, Linux and macOS release bundles in first-install scripts.")
