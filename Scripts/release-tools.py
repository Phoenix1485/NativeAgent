#!/usr/bin/env python3
"""Fail-closed release checks. No credentials or private keys are handled here."""
import json
import re
import sys
from pathlib import Path


def tag_parts(tag):
    match = re.fullmatch(r"v(\d+\.\d+\.\d+)-build\.([1-9][0-9]*)", tag)
    if not match:
        raise ValueError(f"Invalid release tag: {tag}")
    return match[1], int(match[2])


def validate_history(tag, previous):
    _, build = tag_parts(tag)
    for old in previous:
        if not old.strip():
            continue
        _, old_build = tag_parts(old.strip())
        if build <= old_build:
            raise ValueError(f"Build {build} must exceed existing release {old}, including drafts")


def accepted_notarization(result):
    if result.get("status") != "Accepted":
        raise ValueError(f"Apple did not accept this submission: {result.get('status', 'missing status')}. "
                         f"Inspect notarytool log for submission {result.get('id', '(unknown)')}.")


def validate_metadata(data, tag, commit):
    version, build = tag_parts(tag)
    if data.get("version") != version or data.get("build") != str(build):
        raise ValueError("Release metadata does not match its tag")
    if not re.fullmatch(r"[0-9a-f]{40}", commit) or data.get("commit") != commit:
        raise ValueError("Release metadata does not match its source commit")
    if data.get("notarized") is not True:
        raise ValueError("Only notarized releases can be deployed")


def main():
    action = sys.argv[1]
    if action == "history":
        validate_history(sys.argv[2], sys.stdin.read().splitlines())
    elif action == "notarization":
        accepted_notarization(json.loads(Path(sys.argv[2]).read_text()))
    elif action == "metadata":
        validate_metadata(json.loads(Path(sys.argv[2]).read_text()), sys.argv[3], sys.argv[4])
    else:
        raise ValueError("Unknown release check")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, IndexError) as error:
        sys.exit(f"Release check failed: {error}")
