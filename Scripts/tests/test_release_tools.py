import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("release_tools", Path(__file__).parents[1] / "release-tools.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ReleaseChecks(unittest.TestCase):
    def test_first_and_newer_build(self):
        module.validate_history("v0.5.0-build.9", [])
        module.validate_history("v0.5.1-build.10", ["v0.5.0-build.9"])

    def test_duplicate_older_and_malformed_build_fail(self):
        for tag in ["v0.5.0-build.9", "v0.4.0-build.8", "v0.5.0-build.0", "v1;echo-bad", "v1.0.0-build.10.1"]:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                module.validate_history(tag, ["v0.5.0-build.9"])
        with self.assertRaises(ValueError):
            module.validate_history("v1.0.0-build.10", ["unknown-release"])

    def test_only_accepted_notarization_succeeds(self):
        module.accepted_notarization({"status": "Accepted"})
        for status in [None, "Invalid", "In Progress", "Rejected"]:
            with self.subTest(status=status), self.assertRaises(ValueError):
                module.accepted_notarization({"status": status})

    def test_metadata_bound_to_tag_commit_and_notarization(self):
        data = dict(version="0.5.0", build="9", commit="a" * 40, notarized=True)
        module.validate_metadata(data, "v0.5.0-build.9", "a" * 40)
        for name, value in [("version", "0.4.0"), ("build", "8"), ("commit", "b" * 40), ("notarized", False), ("notarized", "true")]:
            with self.subTest(name=name), self.assertRaises(ValueError):
                module.validate_metadata(dict(data, **{name: value}), "v0.5.0-build.9", "a" * 40)
