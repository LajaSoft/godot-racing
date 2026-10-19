"""Check release provenance before any GitHub mutation is possible."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


PACKAGE = module("package_release")
PUBLISH = module("publish_release")


class PublicationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base = tempfile.TemporaryDirectory(prefix="ffb-publication-fixture-")
        cls.version = (ROOT / "addons/ffb/VERSION").read_text().strip()
        cls.fixture = Path(cls.base.name)
        PACKAGE.package(cls.fixture, cls.version)

    @classmethod
    def tearDownClass(cls):
        cls.base.cleanup()

    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory(prefix="ffb-publication-case-")
        self.directory = Path(self.workspace.name)
        shutil.copytree(self.fixture, self.directory, dirs_exist_ok=True)
        self.archive = next(self.directory.glob("*.zip"))
        self.metadata = json.loads((self.directory / "release.json").read_text())
        self.source_commit = self.metadata["source_commit"]
        self.metadata["source_dirty"] = False
        self.rewrite()

    def tearDown(self):
        self.workspace.cleanup()

    def rewrite(self, payload=None):
        with zipfile.ZipFile(self.archive) as source:
            entries = {name: source.read(name) for name in source.namelist()}
        entries["addons/ffb/BUILD.json"] = json.dumps(self.metadata).encode()
        if payload is not None:
            entries.update(payload)
        with zipfile.ZipFile(self.archive, "w", zipfile.ZIP_DEFLATED) as destination:
            for name, data in entries.items():
                destination.writestr(name, data)
        (self.directory / "release.json").write_text(json.dumps(self.metadata))
        digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        (self.directory / "SHA256SUMS").write_text(f"{digest}  {self.archive.name}\n")

    def verify(self):
        return PUBLISH.verify_release(self.directory, "v" + self.version, self.source_commit)

    def test_complete_candidate_passes_without_contacting_github(self):
        metadata, archive, digest = self.verify()
        self.assertEqual(metadata["distribution_tag"], "addon-v" + self.version)
        self.assertEqual(archive, self.archive)
        self.assertEqual(digest, hashlib.sha256(archive.read_bytes()).hexdigest())

    def test_dirty_source_is_not_publishable(self):
        self.metadata["source_dirty"] = True
        self.rewrite()
        with self.assertRaisesRegex(RuntimeError, "uncommitted"):
            self.verify()

    def test_different_source_commit_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "mismatched"):
            PUBLISH.verify_release(self.directory, "v" + self.version, "f" * 40)

    def test_tag_cannot_redirect_the_distribution(self):
        self.metadata["distribution_tag"] = "main"
        self.rewrite()
        with self.assertRaisesRegex(RuntimeError, "distribution tag"):
            self.verify()

    def test_zip_checksum_must_match(self):
        with self.archive.open("ab") as output:
            output.write(b"changed")
        with self.assertRaisesRegex(RuntimeError, "archive checksum"):
            self.verify()

    def test_payload_change_is_detected_even_with_new_zip_checksum(self):
        self.rewrite({"addons/ffb/ffb_wheel.gd": b"changed source"})
        with self.assertRaisesRegex(RuntimeError, "file checksum"):
            self.verify()

    def test_archive_cannot_write_outside_addon(self):
        self.rewrite({"../outside.txt": b"not an addon file"})
        with self.assertRaisesRegex(RuntimeError, "Unexpected path"):
            self.verify()


if __name__ == "__main__":
    unittest.main()
