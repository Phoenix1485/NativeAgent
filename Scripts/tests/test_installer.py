import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


class InstallerTests(unittest.TestCase):
    def test_builder_refuses_to_overwrite_existing_download(self):
        script = Path(__file__).parents[1] / "build-installer.sh"
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "NativeAgent-15.dmg"
            destination.write_bytes(b"keep this installer")
            result = subprocess.run(["bash", str(script), "/does-not-exist/NativeAgent.app", str(destination)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(destination.read_bytes(), b"keep this installer")

    @unittest.skipUnless(shutil.which("node"), "Node is required for the website behavior test")
    def test_website_uses_only_the_manual_dmg_link(self):
        result = subprocess.run(["node", str(Path(__file__).with_name("site-download.test.cjs"))], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
