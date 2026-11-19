#!/usr/bin/env python3
"""Put the signed Windows agent into everything in a packed release that carries or names it.

    python3 packaging/signed-windows.py <release folder>

sign-windows.ps1 runs it after signing dist/garrett-windows.exe. The signature is part of the program file, so
the zip, the one-file installer, SHA256SUMS, the update list, the site's copies and the first-install scripts'
pins are made again from the signed file, the way assemble-release.sh made them from the unsigned one. It refuses
a program file that carries no signature, and a release that sign-release.sh has already signed.
"""
import importlib.util
import struct
import subprocess
import sys
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent


def signed(program):
    """Whether a Windows program file carries an Authenticode signature: its security directory is not empty."""
    header = struct.unpack_from("<I", program, 0x3C)[0]
    if program[header:header + 4] != b"PE\0\0":
        raise SystemExit("garrett-windows.exe is not a Windows program file.")
    optional = header + 24
    directories = optional + (112 if struct.unpack_from("<H", program, optional)[0] == 0x20B else 96)
    offset, size = struct.unpack_from("<II", program, directories + 4 * 8)
    return offset > 0 and size > 0


def main(arguments):
    if len(arguments) != 1:
        raise SystemExit("Usage: signed-windows.py <release folder>")
    release = Path(arguments[0]).resolve()
    dist, site = release / "dist", release / "site"
    for name in ("dist/SHA256SUMS.asc", "site/update.txt.sig"):
        if (release / name).exists():
            raise SystemExit("sign-release.sh has signed this release already: sign the Windows agent before it, from a fresh release.")
    program = (dist / "garrett-windows.exe").read_bytes()
    if not signed(program):
        raise SystemExit("dist/garrett-windows.exe carries no signature: sign-windows.ps1 signs it first.")
    spec = importlib.util.spec_from_file_location("build_release", HERE / "build-release.py")
    build = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(build)

    # The zip: the same members, with the signed program file.
    archive = dist / "garrett-windows.zip"
    with zipfile.ZipFile(archive) as old:
        members = [(entry, old.read(entry)) for entry in old.infolist()]
    if "garrett/garrett.exe" not in [entry.filename for entry, _ in members]:
        raise SystemExit("garrett-windows.zip does not carry garrett.exe the way build-release.py packs it.")
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as new:
        for entry, data in members:
            info = zipfile.ZipInfo(entry.filename, entry.date_time)
            info.compress_type, info.external_attr = entry.compress_type, entry.external_attr
            new.writestr(info, program if entry.filename == "garrett/garrett.exe" else data)

    # The one-file installer: the same records behind the same stub, with the signed agent.
    onefile = dist / "garrett-sentinels-windows.exe"
    packed = memoryview(onefile.read_bytes())
    if packed[-24:] != build.MAGIC:
        raise SystemExit("garrett-sentinels-windows.exe is not a one-file installer.")
    start = struct.unpack("<Q", packed[-32:-24])[0]
    records, position, end = [], start, len(packed) - 32
    while position < end:
        length = struct.unpack_from("<I", packed, position)[0]
        position += 4
        path = bytes(packed[position:position + length]).decode("utf-8")
        position += length
        mode, size = struct.unpack_from("<IQ", packed, position)
        position += 12
        records.append((path, packed[position:position + size], mode))
        position += size
    if position != end or "garrett-service/agent/garrett.exe" not in [path for path, _, _ in records]:
        raise SystemExit("garrett-sentinels-windows.exe does not carry the agent the way build-release.py packs it.")
    build.installer(onefile, packed[:start], [(path, program if path == "garrett-service/agent/garrett.exe" else data, mode) for path, data, mode in records])

    # The digests, the update list, the site's copies and the pins, as assemble-release.sh makes them.
    build.sums(dist)
    digests = {line.split("  ", 1)[1]: line.split("  ", 1)[0] for line in (dist / "SHA256SUMS").read_bytes().decode().splitlines()}
    lines = (site / "update.txt").read_bytes().decode().split("\n")
    changed = [index for index, line in enumerate(lines) if line.endswith("  garrett-windows.exe")]
    if len(changed) != 1:
        raise SystemExit("The update list does not name garrett-windows.exe once.")
    lines[changed[0]] = digests["garrett-windows.exe"] + "  garrett-windows.exe"
    (site / "update.txt").write_bytes("\n".join(lines).encode())
    for name in ("garrett-windows.exe", "garrett-windows.zip", "SHA256SUMS"):
        (site / name).write_bytes((dist / name).read_bytes())
    subprocess.run([sys.executable, "-B", str(HERE / "pin-release-installers.py"), str(dist / "SHA256SUMS"), str(site)], check=True)
    print("The signed garrett-windows.exe is in the release, in garrett-windows.zip and in garrett-sentinels-windows.exe.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
