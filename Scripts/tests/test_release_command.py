"""Exercise shell fail-closed paths without network, credentials, or signing."""
import os
import platform
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


@unittest.skipUnless(platform.system() == "Darwin", "The release driver is macOS-only")
class ReleaseCommandTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        (self.root / "Scripts").mkdir()
        (self.root / "NativeAgent/Resources").mkdir(parents=True)
        project = Path(__file__).resolve().parents[2]
        shutil.copyfile(project / "Scripts/publish-release.sh", self.root / "Scripts/publish-release.sh")
        shutil.copyfile(project / "NativeAgent/Resources/Info.plist", self.root / "NativeAgent/Resources/Info.plist")
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "release-test@example.invalid")
        self.git("config", "core.hooksPath", "/dev/null")
        self.git("remote", "add", "origin", "https://github.com/Phoenix1485/NativeAgent.git")
        self.git("add", "Scripts", "NativeAgent")
        self.git("commit", "-m", "Fixture")

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.root), *args], check=True, capture_output=True)

    def run_release(self, *args, cloud=False):
        env = dict(os.environ, NATIVEAGENT_GH="/usr/bin/true")
        env.pop("GITHUB_ACTIONS", None)
        if cloud:
            env["GITHUB_ACTIONS"] = "true"
        return subprocess.run(["bash", "Scripts/publish-release.sh", *args], cwd=self.root,
                              env=env, capture_output=True, text=True, timeout=10)

    def test_help_and_invalid_argument(self):
        self.assertEqual(self.run_release("--help").returncode, 0)
        self.assertEqual(self.run_release("--invalid").returncode, 2)

    def test_architecture_check_places_input_before_architecture_list(self):
        import shlex
        script = (self.root / "Scripts/publish-release.sh").read_text()
        checks = [shlex.split(line) for line in script.splitlines() if line.startswith("lipo ")]
        # -verify_arch consumes every following argument as an architecture,
        # so a trailing input path would be rejected as an unknown architecture.
        self.assertEqual(checks, [["lipo", "$app/Contents/MacOS/NativeAgent",
                                   "-verify_arch", "arm64", "x86_64"]])

    def test_cloud_signing_is_refused(self):
        result = self.run_release("--publish", cloud=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not in GitHub Actions", result.stderr)

    def test_uncommitted_file_stops_before_credentials(self):
        (self.root / "uncommitted.txt").write_text("fixture")
        result = self.run_release("--publish")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Commit all changes", result.stderr)

    def test_non_main_branch_is_refused(self):
        self.git("switch", "-c", "feature")
        result = self.run_release("--publish")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Switch to main", result.stderr)

    def test_duplicate_tag_is_refused_before_network(self):
        import plistlib
        info = plistlib.loads((self.root / "NativeAgent/Resources/Info.plist").read_bytes())
        self.git("tag", f"v{info['CFBundleShortVersionString']}-build.{info['CFBundleVersion']}")
        result = self.run_release("--publish")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already exists locally", result.stderr)
