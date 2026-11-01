#!/usr/bin/env python3
"""Consumer policy regression tests; shared engine tests live in nbari/release."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("packages", ROOT / "tools/verify-packages.py")
packages = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packages)


def adapter(*args, **env):
    return subprocess.run(["bash", str(ROOT / "tools/adapter.sh"), *args], cwd=ROOT,
                          env={**os.environ, **env}, text=True, capture_output=True)


class ReleaseContract(unittest.TestCase):
    def test_bundle_and_every_reference_share_one_full_sha(self):
        bundle = json.loads((ROOT / ".release-flow-bundle.json").read_text())
        config = json.loads((ROOT / ".release-flow.json").read_text())
        sha = bundle["source_commit"]
        self.assertRegex(sha, r"^[0-9a-f]{40}$")
        self.assertEqual(config["pipeline"], {"repository": "nbari/release", "sha": sha})
        self.assertEqual(config["publishers"], {"github-release": {"required": True, "assets": ["*"]}})
        self.assertEqual(config["promotion"]["required_job"], "candidate / Candidate OK")
        for entry in bundle["files"]:
            with self.subTest(managed=entry["path"]):
                self.assertEqual(hashlib.sha256((ROOT / entry["path"]).read_bytes()).hexdigest(), entry["sha256"])
        self.assertIn("uses: nbari/release@" + sha, (ROOT / ".github/workflows/test.yml").read_text())
        for workflow in ("candidate", "release"):
            self.assertIn("uses: nbari/release/.github/workflows/" + workflow + ".yml@" + sha,
                          (ROOT / (".github/workflows/" + workflow + ".yml")).read_text())

    def test_targets_and_inventory_agree(self):
        targets = adapter("targets")
        self.assertEqual(targets.returncode, 0, targets.stderr)
        matrix = json.loads(targets.stdout)
        names = {row["target"] for row in matrix}
        self.assertEqual(len(matrix), 9)
        self.assertEqual(len(names), 9)
        self.assertIn("aarch64-unknown-linux-musl", names)
        self.assertIn("x86_64-apple-darwin", names)
        self.assertIn("aarch64-pc-windows-msvc", names)
        version = adapter("version").stdout.strip()
        inventory = adapter("inventory", version)
        self.assertEqual(inventory.returncode, 0, inventory.stderr)
        artifacts = json.loads(inventory.stdout)["artifacts"]
        self.assertEqual(len(artifacts), 19)
        self.assertEqual(len({a["name"] for a in artifacts}), 19)
        self.assertEqual({a["target"] for a in artifacts}, names)
        for target in names:
            actual = {a["name"] for a in artifacts if a["target"] == target}
            if target == "any":
                expected = {"release-flow-" + version + ".crate"}
            else:
                prefix = "release-flow-" + version + "-" + target
                extensions = [".tar.gz"]
                if "linux" in target:
                    extensions += [".deb", ".rpm"]
                if "windows" in target:
                    extensions += [".zip"]
                expected = {prefix + extension for extension in extensions}
            self.assertEqual(actual, expected)

    def test_invalid_or_missing_target_cannot_package_or_mutate_source(self):
        before = (ROOT / "Cargo.toml").read_bytes()
        with tempfile.TemporaryDirectory() as directory:
            for target in ("", "not-a-target"):
                result = adapter("package", "0.1.2", directory, RELEASE_FLOW_TARGET=target)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(list(Path(directory).iterdir()), [])
        self.assertEqual((ROOT / "Cargo.toml").read_bytes(), before)

    def test_binary_headers_reject_mislabeled_architectures(self):
        for cpu, elf, macho, pe in (("x86_64", 62, 0x1000007, 0x8664),
                                    ("aarch64", 183, 0x100000C, 0xAA64)):
            elf_data = bytearray(64)
            elf_data[:6] = b"\x7fELF\x02\x01"
            struct.pack_into("<H", elf_data, 18, elf)
            macho_data = bytearray(64)
            macho_data[:4] = b"\xcf\xfa\xed\xfe"
            struct.pack_into("<I", macho_data, 4, macho)
            pe_data = bytearray(128)
            pe_data[:2] = b"MZ"
            struct.pack_into("<I", pe_data, 0x3C, 64)
            pe_data[64:68] = b"PE\0\0"
            struct.pack_into("<H", pe_data, 68, pe)
            other = "aarch64" if cpu == "x86_64" else "x86_64"
            for data, suffix in ((elf_data, "unknown-linux-musl"),
                                 (macho_data, "apple-darwin"), (pe_data, "pc-windows-msvc")):
                with self.subTest(cpu=cpu, platform=suffix):
                    packages.verify_binary(data, cpu + "-" + suffix)
                    with self.assertRaises(ValueError):
                        packages.verify_binary(data, other + "-" + suffix)

    def test_glibc_binary_cannot_be_labeled_musl(self):
        data = bytearray(192)
        data[:6] = b"\x7fELF\x02\x01"
        struct.pack_into("<H", data, 18, 62)
        struct.pack_into("<Q", data, 32, 64)
        struct.pack_into("<HH", data, 54, 56, 1)
        struct.pack_into("<I", data, 64, 3)
        struct.pack_into("<Q", data, 72, 128)
        loader = b"/lib64/ld-linux-x86-64.so.2\0"
        struct.pack_into("<Q", data, 96, len(loader))
        data[128:128 + len(loader)] = loader
        packages.verify_binary(data, "x86_64-unknown-linux-gnu")
        with self.assertRaises(ValueError):
            packages.verify_binary(data, "x86_64-unknown-linux-musl")

    def test_missing_or_unexpected_artifact_fails_before_inspection(self):
        version = adapter("version").stdout.strip()
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            with self.assertRaisesRegex(ValueError, "Missing or unexpected"):
                packages.verify_packages("x86_64-unknown-linux-musl", version, out)
            (out / "unexpected.tar.gz").write_bytes(b"not a release artifact")
            with self.assertRaisesRegex(ValueError, "Missing or unexpected"):
                packages.verify_packages("x86_64-unknown-linux-musl", version, out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
