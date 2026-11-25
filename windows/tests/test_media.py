import argparse
import hashlib
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1] / "cache-iso.py"
SPEC = importlib.util.spec_from_file_location("windows_iso_cache", MODULE)
media = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(media)


class MediaCache(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.payload = b"offline ISO cache fixture"
        self.source = self.root / "supplied.iso"
        self.source.write_bytes(self.payload)
        self.args = argparse.Namespace(cache=self.root / "nfs", sha256=hashlib.sha256(self.payload).hexdigest(),
                                       source=self.source, url_file=None, require_nfs=False)

    def test_atomic_admission_and_offline_reuse(self):
        destination = media.admit(self.args)
        self.assertEqual(destination.read_bytes(), self.payload)
        self.assertEqual(destination.stat().st_mode & 0o222, 0)
        self.assertFalse(destination.with_name("windows11.iso.part").exists())
        receipt = json.loads(destination.with_name("media.json").read_text())
        self.assertEqual(receipt, {"schema": 1, "sha256": self.args.sha256, "size_bytes": len(self.payload)})
        self.source.unlink()
        self.args.source = None
        self.assertEqual(media.admit(self.args), destination)

    def test_corrupt_cache_never_falls_back_to_network(self):
        destination = media.admit(self.args)
        destination.chmod(0o644)
        destination.write_bytes(b"corrupted")
        with patch.object(media, "download") as download:
            with self.assertRaisesRegex(ValueError, "checksum"):
                media.admit(self.args)
        download.assert_not_called()

    def test_expired_link_retains_partial_and_fresh_link_resumes(self):
        self.args.source = None
        self.args.url_file = self.root / "url.txt"
        self.args.url_file.write_text("https://software.download.prss.microsoft.com/windows.iso?token=expired")
        calls = []

        def curl(args, **kwargs):
            self.assertNotIn("token=", " ".join(map(str, args)))
            calls.append(kwargs["input"])
            target = Path(args[args.index("--output") + 1])
            if len(calls) == 1:
                target.write_bytes(self.payload[:5])
                return subprocess.CompletedProcess(args, 22, "", "sensitive URL must not escape")
            self.assertEqual(target.read_bytes(), self.payload[:5])
            target.write_bytes(self.payload)
            self.assertIn("--continue-at", args)
            return subprocess.CompletedProcess(args, 0, "", "")

        with patch.object(media.subprocess, "run", curl):
            with self.assertRaisesRegex(RuntimeError, "fresh link") as failure:
                media.admit(self.args)
            self.assertNotIn("token=", str(failure.exception))
            self.args.url_file.write_text("https://software.download.prss.microsoft.com/windows.iso?token=fresh")
            destination = media.admit(self.args)
        self.assertEqual(destination.read_bytes(), self.payload)
        self.assertNotIn("token=", destination.with_name("media.json").read_text())

    def test_bad_download_is_not_published_or_resumed(self):
        self.args.source = None
        self.args.url_file = self.root / "url.txt"
        self.args.url_file.write_text("https://example.com/windows.iso")

        def download(_, partial):
            partial.write_bytes(b"wrong ISO")

        with patch.object(media, "download", download):
            with self.assertRaisesRegex(ValueError, "checksum"):
                media.admit(self.args)
        entry = self.args.cache / "media/sha256" / self.args.sha256
        self.assertFalse((entry / "windows11.iso").exists())
        self.assertFalse((entry / "windows11.iso.part").exists())

    def test_local_filesystem_cannot_satisfy_nfs_requirement(self):
        self.args.require_nfs = True
        with patch.object(media.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "ext4\n", "")):
            with self.assertRaisesRegex(ValueError, "NFS"):
                media.admit(self.args)
        self.assertFalse(self.args.cache.exists())

    def test_second_lab_can_admit_the_same_bytes_independently(self):
        first = media.admit(self.args)
        self.args.cache = self.root / "second-lab"
        self.args.source = first
        second = media.admit(self.args)
        self.assertNotEqual(first, second)
        self.assertEqual(media.digest(first), media.digest(second))


if __name__ == "__main__":
    unittest.main()
