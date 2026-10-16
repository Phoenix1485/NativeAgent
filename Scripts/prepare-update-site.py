#!/usr/bin/env python3
"""Validate a generated appcast, preserve its signature bytes, and stage Pages."""
import argparse
import hashlib
import json
import plistlib
import re
import shutil
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import quote

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
APP_BUNDLE = "NativeAgent.app"


def read_archive_info(archive):
    """Require the update to contain one canonically named application bundle."""
    with zipfile.ZipFile(archive) as bundle:
        names = bundle.namelist()
        app_roots = {
            name.split("/", 1)[0]
            for name in names
            if "/" in name and name.split("/", 1)[0].endswith(".app")
        }
        if app_roots != {APP_BUNDLE}:
            raise ValueError(f"Update archive must contain exactly {APP_BUNDLE}")
        entry = bundle.getinfo(f"{APP_BUNDLE}/Contents/Info.plist")
        if entry.file_size > 65536:
            raise ValueError("Oversized bundle plist")
        return plistlib.loads(bundle.read(entry))


def validate_feed(data, archive, repository, tag, info):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Invalid repository")
    if not re.fullmatch(r"v[0-9.]+-build\.[0-9.]+", tag):
        raise ValueError("Invalid release tag")
    root = ET.fromstring(data)
    items = root.findall("./channel/item")
    if len(items) != 1:
        raise ValueError("Expected exactly one release in this generated feed")
    item = items[0]
    enclosure = item.find("enclosure")
    expected_url = f"https://github.com/{repository}/releases/download/{tag}/{quote(archive.name)}"
    if enclosure is None or enclosure.get("url") != expected_url:
        raise ValueError("Update must use this release's immutable GitHub URL")
    if enclosure.get("length") != str(archive.stat().st_size):
        raise ValueError("Archive byte length differs from the feed")
    signature = enclosure.get(f"{{{SPARKLE}}}edSignature", "")
    import base64
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Missing Ed25519 archive signature")
    build = item.findtext(f"{{{SPARKLE}}}version") or enclosure.get(f"{{{SPARKLE}}}version")
    if build != info["CFBundleVersion"]:
        raise ValueError("Feed and bundle build numbers differ")
    return expected_url


def main():
    parser = argparse.ArgumentParser()
    for arg in ("source", "destination", "archive", "appcast", "repository", "tag", "commit", "notarized"):
        parser.add_argument("--" + arg, required=True)
    parser.add_argument("--app")
    args = parser.parse_args()
    archive = Path(args.archive)
    archive_info = read_archive_info(archive)
    if args.app:
        app = Path(args.app)
        if app.name != APP_BUNDLE:
            raise ValueError(f"Release bundle must be named {APP_BUNDLE}")
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        for key in ("CFBundleIdentifier", "CFBundleVersion", "CFBundleShortVersionString"):
            if archive_info.get(key) != info.get(key):
                raise ValueError(f"Archive and release bundle differ for {key}")
    else:
        # CI reads a single plist; it never extracts or runs the downloaded app.
        info = archive_info
    if info.get("CFBundleIdentifier") != "dev.nativeagent.mac":
        raise ValueError("Unexpected application identifier")
    if args.tag != f"v{info['CFBundleShortVersionString']}-build.{info['CFBundleVersion']}":
        raise ValueError("Tag and bundle versions differ")
    if args.notarized != "true" or not re.fullmatch(r"[0-9a-f]{40}", args.commit):
        raise ValueError("A notarized release and full source commit are required")
    feed = Path(args.appcast).read_bytes()
    download = validate_feed(feed, archive, args.repository, args.tag, info)
    destination = Path(args.destination)
    shutil.copytree(args.source, destination, dirs_exist_ok=True)
    # Do not parse/reserialize the feed: its exact bytes are signed by Sparkle.
    shutil.copyfile(args.appcast, destination / "appcast.xml")
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (destination / "SHA256SUMS.txt").write_text(f"{digest}  {archive.name}\n")
    (destination / ".nojekyll").touch()
    (destination / "release.json").write_text(json.dumps({
        "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
        "download": download, "sha256": digest, "commit": args.commit,
        "notarized": args.notarized == "true",
        "release": f"https://github.com/{args.repository}/releases/tag/{args.tag}"
    }, indent=2) + "\n")


if __name__ == "__main__":
    main()
