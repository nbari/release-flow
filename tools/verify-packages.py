#!/usr/bin/env python3
"""Verify release-flow package names, native machine types and Linux metadata."""
import io
import json
from pathlib import Path, PurePosixPath
import struct
import subprocess
import sys
import tarfile
import zipfile


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify_binary(data, target):
    cpu = target.split("-")[0]
    if "linux" in target:
        require(data[:6] == b"\x7fELF\x02\x01", "Expected a 64-bit little-endian ELF binary")
        machine = struct.unpack_from("<H", data, 18)[0]
        expected = {"x86_64": 62, "aarch64": 183}[cpu]
        program_offset = struct.unpack_from("<Q", data, 32)[0]
        entry_size, count = struct.unpack_from("<HH", data, 54)
        for index in range(count):
            offset = program_offset + index * entry_size
            if struct.unpack_from("<I", data, offset)[0] == 3:
                start = struct.unpack_from("<Q", data, offset + 8)[0]
                size = struct.unpack_from("<Q", data, offset + 32)[0]
                interpreter = data[start:start + size].rstrip(b"\0")
                require(b"musl" in interpreter if "musl" in target else b"ld-linux" in interpreter,
                        "ELF loader differs from the declared libc target")
    elif "apple" in target:
        require(data[:4] == b"\xcf\xfa\xed\xfe", "Expected a 64-bit Mach-O binary")
        machine = struct.unpack_from("<I", data, 4)[0]
        expected = {"x86_64": 0x1000007, "aarch64": 0x100000C}[cpu]
    elif "windows" in target:
        require(data[:2] == b"MZ", "Expected a Windows executable")
        offset = struct.unpack_from("<I", data, 0x3C)[0]
        require(data[offset:offset + 4] == b"PE\0\0", "Invalid PE header")
        machine = struct.unpack_from("<H", data, offset + 4)[0]
        expected = {"x86_64": 0x8664, "aarch64": 0xAA64}[cpu]
    else:
        raise ValueError("Unsupported binary target: " + target)
    require(machine == expected, "Binary architecture differs from target " + target)


def tar_binary(archive, executable):
    binaries = []
    for member in archive.getmembers():
        path = PurePosixPath(member.name)
        require(not path.is_absolute() and ".." not in path.parts, "Unsafe archive path")
        require(member.isdir() or member.isfile(), "Archive contains a link or special file")
        if member.isfile() and path.name == executable:
            require(member.mode & 0o111 or executable.endswith(".exe"), "Binary is not executable")
            binaries.append(archive.extractfile(member).read())
    require(len(binaries) == 1, "Expected exactly one application binary")
    return binaries[0]


def rpm_binary(data):
    position = 0
    binaries = []
    while position < len(data):
        header = data[position:position + 110]
        require(header[:6] in (b"070701", b"070702"), "Invalid RPM cpio payload")
        fields = [int(header[i:i + 8], 16) for i in range(6, 110, 8)]
        size, name_size = fields[6], fields[11]
        start = position + 110
        name = data[start:start + name_size].rstrip(b"\0").decode("utf-8")
        position = (start + name_size + 3) & ~3
        if name == "TRAILER!!!":
            break
        path = PurePosixPath(name)
        require(".." not in path.parts, "Unsafe RPM path")
        if str(path).lstrip("/") == "usr/bin/release-flow":
            require(fields[1] & 0o111, "RPM binary is not executable")
            binaries.append(data[position:position + size])
        position = (position + size + 3) & ~3
    require(len(binaries) == 1, "Expected exactly one RPM application binary")
    return binaries[0]


def verify_packages(target, version, directory):
    root = Path(__file__).resolve().parents[1]
    inventory = json.loads(subprocess.check_output(
        ["bash", str(root / "tools/adapter.sh"), "inventory", version], cwd=root, text=True))
    expected = {a["name"] for a in inventory["artifacts"] if a["target"] == target}
    observed = {p.name for p in directory.iterdir()}
    require(expected and observed == expected, "Missing or unexpected package files")
    cpu = target.split("-")[0]
    executable = "release-flow.exe" if "windows" in target else "release-flow"
    for name in sorted(expected):
        path = directory / name
        require(path.is_file() and not path.is_symlink(), "Package must be a regular file")
        if name.endswith(".tar.gz"):
            with tarfile.open(path) as archive:
                binary = tar_binary(archive, executable)
        elif name.endswith(".zip"):
            with zipfile.ZipFile(path) as archive:
                entries = [n for n in archive.namelist() if n == executable]
                require(len(entries) == 1, "Expected one Windows executable in ZIP")
                binary = archive.read(entries[0])
        elif name.endswith(".deb"):
            arch = subprocess.check_output(["dpkg-deb", "--field", str(path), "Architecture"], text=True).strip()
            require(arch == {"x86_64": "amd64", "aarch64": "arm64"}[cpu], "Incorrect Debian architecture")
            payload = subprocess.check_output(["dpkg-deb", "--fsys-tarfile", str(path)])
            with tarfile.open(fileobj=io.BytesIO(payload)) as archive:
                binary = tar_binary(archive, executable)
        elif name.endswith(".rpm"):
            arch = subprocess.check_output(["rpm", "-qp", "--queryformat", "%{ARCH}", str(path)], text=True).strip()
            require(arch == {"x86_64": "x86_64", "aarch64": "aarch64"}[cpu], "Incorrect RPM architecture")
            binary = rpm_binary(subprocess.check_output(["rpm2cpio", str(path)]))
        else:
            raise ValueError("Unexpected package format: " + name)
        verify_binary(binary, target)
        print("VERIFIED", name, target)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("Usage: verify-packages.py TARGET VERSION DIRECTORY")
    verify_packages(sys.argv[1], sys.argv[2], Path(sys.argv[3]))
