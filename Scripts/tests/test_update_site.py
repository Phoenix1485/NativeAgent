import base64
import importlib.util
import json
import hashlib
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("update_site", Path(__file__).parents[1] / "prepare-update-site.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class UpdateSiteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.archive = Path(self.temp.name) / "NativeAgent-1001.1.zip"
        self.archive.write_bytes(b"fixture")
        self.info = {"CFBundleVersion": "1001.1"}
        self.url = "https://github.com/Phoenix1485/NativeAgent/releases/download/v0.5.0-build.1001.1/NativeAgent-1001.1.zip"
        signature = base64.b64encode(bytes(64)).decode()
        self.feed = f'''<rss xmlns:sparkle="{module.SPARKLE}"><channel><item><sparkle:version>1001.1</sparkle:version><enclosure url="{self.url}" length="7" sparkle:edSignature="{signature}"/></item></channel></rss>'''

    def validate(self, feed):
        return module.validate_feed(feed.encode(), self.archive, "Phoenix1485/NativeAgent", "v0.5.0-build.1001.1", self.info)

    def test_exact_archive_and_build_are_accepted(self):
        self.assertEqual(self.validate(self.feed), self.url)

    def test_wrong_url_length_version_and_missing_signature_fail(self):
        changes = [(self.url, "https://attacker.invalid/app.zip"), ('length="7"', 'length="8"'),
                   (">1001.1<", ">1000<"), ("sparkle:edSignature", "unsigned")]
        for before, after in changes:
            with self.subTest(before=before), self.assertRaises(ValueError):
                self.validate(self.feed.replace(before, after))

    def test_empty_or_duplicate_release_feed_fails(self):
        for feed in ["<rss><channel/></rss>", self.feed.replace("</channel>", "<item/></channel>")]:
            with self.assertRaises(ValueError):
                self.validate(feed)

    def test_app_and_archive_staging_preserve_signed_feed_bytes(self):
        root = Path(self.temp.name)
        app = root / "NativeAgent.app"
        (app / "Contents").mkdir(parents=True)
        info = {"CFBundleIdentifier": "dev.nativeagent.mac", "CFBundleVersion": "1001.1",
                "CFBundleShortVersionString": "0.5.0"}
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        with zipfile.ZipFile(self.archive, "w") as bundle:
            bundle.write(app / "Contents/Info.plist", "NativeAgent.app/Contents/Info.plist")
        # This test checks byte preservation only. CryptoKit tests use real signatures.
        feed = self.feed.replace('length="7"', f'length="{self.archive.stat().st_size}"').encode() + b"\n<!-- signature fixture: preserve these exact bytes -->\n"
        (root / "appcast.xml").write_bytes(feed)
        site = root / "site"
        site.mkdir()
        (site / "index.html").write_text("<!doctype html><title>Fixture</title>")
        installer = root / "NativeAgent-1001.1.dmg"
        installer.write_bytes(b"DMG fixture; real signing and mounting are tested by release tools")
        for name, extra in [("local", ["--app", str(app)]), ("ci", [])]:
            destination = root / name
            subprocess.run([sys.executable, str(Path(module.__file__)), "--source", str(site),
                            "--destination", str(destination), "--archive", str(self.archive),
                            "--appcast", str(root / "appcast.xml"), "--installer", str(installer), "--repository", "Phoenix1485/NativeAgent",
                            "--tag", "v0.5.0-build.1001.1", "--commit", "a" * 40, "--notarized", "true", *extra],
                           check=True, capture_output=True)
            self.assertEqual((destination / "appcast.xml").read_bytes(), feed)
            data = json.loads((destination / "release.json").read_text())
            self.assertEqual(data["commit"], "a" * 40)
            self.assertIs(data["notarized"], True)
            self.assertEqual(data["format"], "dmg")
            self.assertTrue(data["download"].endswith("/NativeAgent-1001.1.dmg"))
            self.assertEqual(data["sha256"], hashlib.sha256(installer.read_bytes()).hexdigest())
            self.assertEqual(data["updateDownload"], self.url)
            self.assertEqual(data["updateSha256"], hashlib.sha256(self.archive.read_bytes()).hexdigest())
            checksums = (destination / "SHA256SUMS.txt").read_text()
            self.assertIn(installer.name, checksums)
            self.assertIn(self.archive.name, checksums)
        for name in ["release.json", "SHA256SUMS.txt", "appcast.xml"]:
            self.assertEqual((root / "local" / name).read_bytes(), (root / "ci" / name).read_bytes())
        # Reject a wrongly named, missing or empty manual installer before staging.
        for candidate in [root / "wrong.dmg", installer]:
            candidate.write_bytes(b"" if candidate == installer else b"wrong name")
            result = subprocess.run([sys.executable, str(Path(module.__file__)), "--source", str(site),
                                    "--destination", str(root / "invalid"), "--archive", str(self.archive),
                                    "--appcast", str(root / "appcast.xml"), "--installer", str(candidate),
                                    "--repository", "Phoenix1485/NativeAgent", "--tag", "v0.5.0-build.1001.1",
                                    "--commit", "a" * 40, "--notarized", "true"], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((root / "invalid").exists())

    def test_archive_rejects_a_numbered_or_second_app_bundle(self):
        info = plistlib.dumps({"CFBundleIdentifier": "dev.nativeagent.mac"})
        for entries in [
            {"NativeAgent 2.app/Contents/Info.plist": info},
            {
                "NativeAgent.app/Contents/Info.plist": info,
                "NativeAgent 2.app/Contents/Info.plist": info,
            },
        ]:
            with self.subTest(entries=tuple(entries)):
                with zipfile.ZipFile(self.archive, "w") as bundle:
                    for name, contents in entries.items():
                        bundle.writestr(name, contents)
                with self.assertRaisesRegex(ValueError, "exactly NativeAgent.app"):
                    module.read_archive_info(self.archive)


if __name__ == "__main__":
    unittest.main()
