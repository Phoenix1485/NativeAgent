import base64
import importlib.util
import tempfile
import unittest
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


if __name__ == "__main__":
    unittest.main()
