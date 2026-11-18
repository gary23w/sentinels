#!/usr/bin/env python3
"""Build the release bundles into an output folder. Runs on any system with Python 3.9 or newer.

    python3 packaging/build-release.py dist --agents <folder> [--all]

  garrett-linux-x86_64.tar.gz     for Linux without apt, 64-bit Intel/AMD: unpack, sudo sh garrett/install.sh
  garrett-linux-aarch64.tar.gz    the same for 64-bit ARM
  garrett-linux-armv7.tar.gz      the same for 32-bit ARM (ARMv7 with hardware floating point: small boards and devices)
  garrett-macos.tar.gz            for macOS (Apple silicon and Intel): unpack, double-click "Install garrett.command"
  garrett-windows.zip             for Windows: unpack, double-click "Install garrett.cmd"
  garrett-service.tar.gz          the Sentinel service for your own Linux machine, from the bundle
  garrett-service-windows.zip     the same for Windows
  garrett-sentinels-linux-x86_64  one file that installs the service, its decision model and the agent on a Linux
  garrett-sentinels-linux-aarch64 machine (packaging/service.sh fetches and runs it); the same for 64-bit ARM
  garrett-sentinels-windows.exe   the same for Windows (packaging/service.ps1 fetches and runs it)
  SHA256SUMS              release file digests; the first-install scripts pin the hashes at build time

The one-file installers need, besides the agents:
  --installers <folder>   garrett-installer-linux-x86_64, garrett-installer-linux-aarch64, garrett-installer-windows.exe,
                          the stub built from packaging/installer by the release workflow
  --node <folder>         node-linux-x64, node-linux-arm64, node-win-x64.exe: the official Node.js builds
  --model <folder>        model.onnx, tokenizer.json, tokenizer_config.json, config.json from the model repository
One is built for each platform whose stub and Node.js are there; the model and the agent go in when they are.

The agent is one program file for each system. They are built and tested on hosted machines by
.github/workflows/release.yml; --agents names the folder they were downloaded to:

  garrett-linux-x86_64  garrett-linux-aarch64  garrett-linux-armv7  garrett-macos  garrett-windows.exe

A bundle is built for each agent that is there; --all fails unless all five are (a release uses it).

SHA256SUMS lists every file already in the output folder, so the Debian packages (packaging/build-deb.sh) and
anything else that belongs to the release go there first. packaging/assemble-release.sh does all of it in order.
The archives are reproducible: fixed times, fixed owners, sorted names.
"""
import gzip
import hashlib
import io
import json
import struct
import sys
import tarfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WHEN = 1793491200  # 2026-11-01, the same in every build


def unix(path):
    return (ROOT / path).read_bytes().replace(b"\r\n", b"\n")


def windows(path):
    return unix(path).replace(b"\n", b"\r\n")


def tarball(target, files, folder="garrett"):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.PAX_FORMAT) as archive:
        for name, data, mode in sorted(files):
            info = tarfile.TarInfo(folder + "/" + name)
            info.size, info.mode, info.mtime, info.uid, info.gid, info.uname, info.gname = len(data), mode, WHEN, 0, 0, "root", "root"
            archive.addfile(info, io.BytesIO(data))
    with open(target, "wb") as handle, gzip.GzipFile(fileobj=handle, mode="wb", mtime=WHEN, filename="") as packed:
        packed.write(raw.getvalue())


MAGIC = b"GARRETT-SENTINELS-PAYL01"


def payload(records):
    """The records a one-file installer carries: u32 path length, path, u32 mode, u64 size, bytes."""
    out = io.BytesIO()
    for path, data, mode in sorted(records):
        encoded = path.encode("utf-8")
        out.write(struct.pack("<I", len(encoded)) + encoded + struct.pack("<I", mode) + struct.pack("<Q", len(data)) + data)
    return out.getvalue()


def installer(target, stub, records):
    """The stub, the payload, then the trailer: where the payload starts, and the magic the stub looks for."""
    body = payload(records)
    with open(target, "wb") as handle:
        handle.write(stub)
        handle.write(body)
        handle.write(struct.pack("<Q", len(stub)) + MAGIC)
    target.chmod(0o755)


def package_files(platforms):
    """The packages the service carries, as "npm install" in server/ left them: the optional memory engine, and
    what runs the decision model inside the service (the pure-JS tokenizer, and onnxruntime for the platforms named,
    "linux/x64", "linux/arm64" or "win32/x64")."""
    modules = ROOT / "server" / "node_modules"
    files = []

    def tree(package, keep):
        root = modules / package
        for path in sorted(root.rglob("*")):
            if path.is_file():
                rel = path.relative_to(root).as_posix()
                if keep(rel):
                    files.append(("node_modules/%s/%s" % (package, rel), path.read_bytes(), 0o644))
    memory = modules / "@gary23w" / "neuron-db"
    if (memory / "neuron_core.wasm").is_file():
        files += [("node_modules/@gary23w/neuron-db/" + name, (memory / name).read_bytes(), 0o644) for name in ("LICENSE", "index.mjs", "neuron_core.wasm", "package.json")]
    if (modules / "onnxruntime-node" / "package.json").is_file() and (modules / "@huggingface" / "tokenizers" / "package.json").is_file():
        tree("@huggingface/tokenizers", lambda rel: rel in ("package.json", "LICENSE") or rel.startswith("dist/"))
        tree("onnxruntime-common", lambda rel: rel in ("package.json", "LICENSE") or rel.startswith("dist/"))
        # Only the CPU build: the package's install step may have fetched the CUDA and TensorRT providers (hundreds
        # of MB) into the same folders, and the service never uses them.
        tree("onnxruntime-node", lambda rel: rel in ("package.json", "LICENSE", "README.md") or rel.startswith("dist/")
             or (any(rel.startswith("bin/napi-v6/%s/" % platform) for platform in platforms) and not any(word in rel.lower() for word in ("cuda", "tensorrt", "cudnn", "cublas", "nvrtc"))))
    return files


def sums(out):
    names = sorted(path.name for path in out.iterdir() if path.is_file() and path.name != "SHA256SUMS" and not path.name.startswith("."))
    (out / "SHA256SUMS").write_bytes("".join("%s  %s\n" % (hashlib.sha256((out / name).read_bytes()).hexdigest(), name) for name in names).encode())


def main(arguments):
    out = Path(arguments[0] if arguments and not arguments[0].startswith("--") else "dist").resolve()
    out.mkdir(parents=True, exist_ok=True)
    if "--sums-only" in arguments:
        sums(out)
        return 0
    if "--agents" not in arguments:
        raise SystemExit("Give --agents <folder with the built agents>.")
    agents = Path(arguments[arguments.index("--agents") + 1]).resolve()
    names = ("garrett-linux-x86_64", "garrett-linux-aarch64", "garrett-linux-armv7", "garrett-macos", "garrett-windows.exe")
    built = {name: (agents / name).read_bytes() for name in names if (agents / name).is_file()}
    if "--all" in arguments and len(built) != len(names):
        raise SystemExit("Not every agent is in %s: missing %s" % (agents, ", ".join(name for name in names if name not in built)))
    notices = [("LICENSE", unix("LICENSE"), 0o644), ("NOTICES.md", unix("rust/NOTICES.md"), 0o644)]
    launcher = ("garrett", unix("packaging/garrett"), 0o755)

    def linux_agent(processor):
        return notices + [("garrett-agent", built["garrett-linux-" + processor], 0o755), launcher, ("unblock", unix("packaging/unblock"), 0o755),
                          ("garrett.service", unix("debian/garrett.service"), 0o644), ("garrett.openrc", unix("packaging/linux/garrett.openrc"), 0o755),
                          ("install.sh", unix("packaging/linux/install.sh"), 0o755),
                          # The manual page, for the pacman and rpm packages built from this bundle (build-packages.sh).
                          ("garrett.8", unix("debian/garrett.8"), 0o644)]
    for processor in (item for item in ("x86_64", "aarch64", "armv7") if "garrett-linux-" + item in built):
        tarball(out / ("garrett-linux-%s.tar.gz" % processor), linux_agent(processor))
    if "garrett-macos" in built:
        tarball(out / "garrett-macos.tar.gz", notices + [("garrett-agent", built["garrett-macos"], 0o755), launcher, ("install.sh", unix("packaging/macos/install.sh"), 0o755),
                ("Install garrett.command", unix("packaging/macos/Install garrett.command"), 0o755)])
    with zipfile.ZipFile(out / "garrett-windows.zip" if "garrett-windows.exe" in built else io.BytesIO(), "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        def add(name, data):
            info = zipfile.ZipInfo("garrett/" + name, (2026, 11, 1, 0, 0, 0))
            info.compress_type, info.external_attr = zipfile.ZIP_DEFLATED, 0o644 << 16
            archive.writestr(info, data)
        add("Install garrett.cmd", windows("packaging/windows/Install garrett.cmd"))
        add("Uninstall garrett.cmd", windows("packaging/windows/Uninstall garrett.cmd"))
        add("deploy/install-windows.ps1", windows("deploy/install-windows.ps1"))
        add("deploy/uninstall-windows.ps1", windows("deploy/uninstall-windows.ps1"))
        add("garrett.exe", built.get("garrett-windows.exe", b""))
        add("LICENSE", windows("LICENSE"))
        add("NOTICES.md", windows("rust/NOTICES.md"))
    def option(flag):
        return Path(arguments[arguments.index(flag) + 1]).resolve() if flag in arguments else None
    installers, node, model = option("--installers"), option("--node"), option("--model")
    if "--all" in arguments:
        for folder, names in ((installers, ("garrett-installer-linux-x86_64", "garrett-installer-linux-aarch64", "garrett-installer-windows.exe")),
                              (node, ("node-linux-x64", "node-linux-arm64", "node-win-x64.exe")), (model, ("model.onnx", "tokenizer.json", "tokenizer_config.json", "config.json"))):
            if folder is None or any(not (folder / name).is_file() for name in names):
                raise SystemExit("--all needs --installers, --node and --model folders with every file in them: " + ", ".join(names))
    service = [(name, unix("server/" + name), 0o644) for name in ("serve.mjs", "sqlite.mjs", "ask.mjs", "setup.mjs", "schema.sql")]
    service += [("src/" + path.name, unix("server/src/" + path.name), 0o644) for path in sorted((ROOT / "server" / "src").glob("*.mjs"))]
    # The packages the service carries, as "npm install" in server/ left them (assemble-release.sh runs it): the
    # optional memory engine, and what runs the decision model inside the service.
    if not (ROOT / "server" / "node_modules" / "onnxruntime-node" / "package.json").is_file():
        if "--all" in arguments:
            raise SystemExit("The service's packages are not in server/node_modules. Run npm install in server/ first (assemble-release.sh does).")
        print("server/node_modules has no onnxruntime-node: the bundles carry no model runtime")
    else:
        print("the service bundles carry the model runtime (onnxruntime-node, @huggingface/tokenizers)")
    unix_extras = [("LICENSE", unix("LICENSE"), 0o644), ("install.sh", unix("packaging/service/install.sh"), 0o755),
                   ("garrett-service", unix("packaging/service/garrett-service"), 0o755), ("garrett-service.service", unix("packaging/service/garrett-service.service"), 0o644)]
    windows_extras = [("LICENSE", windows("LICENSE"), 0o644), ("garrett-service.ps1", windows("packaging/service/garrett-service.ps1"), 0o644)]
    tarball(out / "garrett-service.tar.gz", service + unix_extras + package_files(("linux/x64", "linux/arm64")), "garrett-service")
    with zipfile.ZipFile(out / "garrett-service-windows.zip", "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data, _ in sorted(service + windows_extras + package_files(("win32/x64",))):
            info = zipfile.ZipInfo("garrett-service/" + name, (2026, 11, 1, 0, 0, 0))
            info.compress_type, info.external_attr = zipfile.ZIP_DEFLATED, 0o644 << 16
            archive.writestr(info, data)
    # The one-file installers: the service bundle, the Node.js runtime, the model and the agent, behind the stub.
    model_files = [("model/" + name, (model / name).read_bytes(), 0o644) for name in ("model.onnx", "tokenizer.json", "tokenizer_config.json", "config.json")] if model and (model / "model.onnx").is_file() else []
    for processor, arch in (("x86_64", "x64"), ("aarch64", "arm64")):
        stub, runtime = (installers / ("garrett-installer-linux-" + processor)) if installers else None, (node / ("node-linux-" + arch)) if node else None
        if not (stub and stub.is_file() and runtime and runtime.is_file()):
            continue
        records = service + unix_extras + package_files(("linux/" + arch,)) + [("node", runtime.read_bytes(), 0o755)] + model_files
        if "garrett-linux-" + processor in built:
            records += [("agent/" + name, data, mode) for name, data, mode in linux_agent(processor)]
        installer(out / ("garrett-sentinels-linux-" + processor), stub.read_bytes(), [("garrett-service/" + name, data, mode) for name, data, mode in records])
        print("garrett-sentinels-linux-%s: %s model, %s agent" % (processor, "with" if model_files else "no", "with" if "garrett-linux-" + processor in built else "no"))
    stub, runtime = (installers / "garrett-installer-windows.exe") if installers else None, (node / "node-win-x64.exe") if node else None
    if stub and stub.is_file() and runtime and runtime.is_file():
        records = service + windows_extras + package_files(("win32/x64",)) + [("node.exe", runtime.read_bytes(), 0o755)] + model_files
        if "garrett-windows.exe" in built:
            records += [("agent/garrett.exe", built["garrett-windows.exe"], 0o755), ("agent/deploy/install-windows.ps1", windows("deploy/install-windows.ps1"), 0o644),
                        ("agent/deploy/uninstall-windows.ps1", windows("deploy/uninstall-windows.ps1"), 0o644), ("agent/LICENSE", windows("LICENSE"), 0o644), ("agent/NOTICES.md", windows("rust/NOTICES.md"), 0o644)]
        installer(out / "garrett-sentinels-windows.exe", stub.read_bytes(), [("garrett-service/" + name, data, mode) for name, data, mode in records])
        print("garrett-sentinels-windows.exe: %s model, %s agent" % ("with" if model_files else "no", "with" if "garrett-windows.exe" in built else "no"))
    sums(out)
    for path in sorted(out.iterdir()):
        if path.is_file() and not path.name.startswith("."):
            print("%10d  %s" % (path.stat().st_size, path.name))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
