#!/usr/bin/env python3
"""Validate the actual product described by Xcode's build settings."""

import argparse
import json
import pathlib
import re
import subprocess
import sys


def run(*args):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print(result.stdout, end="")
    if result.returncode:
        raise SystemExit(result.returncode)
    return result.stdout


def verify(settings_path, distribution=False):
    targets = json.loads(settings_path.read_text())
    apps = [t["buildSettings"] for t in targets
            if t["buildSettings"].get("PRODUCT_TYPE") == "com.apple.product-type.application"]
    if len(apps) != 1:
        raise SystemExit("Expected exactly one host application in build settings.")
    settings = apps[0]
    team = settings.get("DEVELOPMENT_TEAM", "")
    bundle_id = settings["PRODUCT_BUNDLE_IDENTIFIER"]
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise SystemExit("An explicit Apple development team is required; ad-hoc signing is not accepted.")
    if not re.fullmatch(r"[A-Za-z0-9.-]+", bundle_id):
        raise SystemExit("Invalid bundle identifier.")
    app = pathlib.Path(settings["TARGET_BUILD_DIR"]) / settings["FULL_PRODUCT_NAME"]
    requirement = (f'anchor apple generic and identifier "{bundle_id}" '
                   f'and certificate leaf[subject.OU] = "{team}"')
    run("codesign", "--verify", "--strict", "--deep", "--verbose=2", "-R=" + requirement, str(app))
    details = run("codesign", "--display", "--verbose=4", str(app))
    flags = re.search(r"flags=0x([0-9a-fA-F]+)", details)
    if flags is None or not int(flags[1], 16) & 0x10000:
        raise SystemExit("Hardened Runtime is required.")
    if distribution:
        verify_distribution(app, details)
    else:
        print("Local signing verified. This does not establish distribution or notarization readiness.")


def verify_distribution(app, details):
    if "Authority=Developer ID Application:" not in details:
        raise SystemExit("Distribution requires Developer ID Application, not Apple Development.")
    # Gatekeeper and the stapled ticket validate the final bundle, not a submitted zip's status.
    run("xcrun", "stapler", "validate", str(app))
    run("spctl", "--assess", "--type", "execute", "--verbose=4", str(app))
    print("Developer ID signature, stapled ticket and Gatekeeper assessment verified.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("settings", type=pathlib.Path)
    parser.add_argument("--distribution", action="store_true")
    args = parser.parse_args()
    try:
        verify(args.settings, args.distribution)
    except (OSError, KeyError, ValueError) as error:
        sys.exit(f"Signature verification failed: {error}")
