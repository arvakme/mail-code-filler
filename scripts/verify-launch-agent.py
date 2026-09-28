#!/usr/bin/env python3
"""Verify the launch agent in the actual Xcode host product without registering it."""

import json
import pathlib
import plistlib
import subprocess
import sys


def verify(settings_path):
    targets = json.loads(settings_path.read_text())
    apps = [target["buildSettings"] for target in targets
            if target["buildSettings"].get("PRODUCT_TYPE") == "com.apple.product-type.application"]
    if len(apps) != 1:
        raise ValueError("Expected exactly one host application in build settings.")
    settings = apps[0]
    app = pathlib.Path(settings["TARGET_BUILD_DIR"]) / settings["FULL_PRODUCT_NAME"]
    program = str(pathlib.Path(settings["EXECUTABLE_PATH"]).relative_to(settings["FULL_PRODUCT_NAME"]))
    label = settings["PRODUCT_BUNDLE_IDENTIFIER"] + ".agent"
    plist_path = app / "Contents/Library/LaunchAgents" / (label + ".plist")
    subprocess.run(["plutil", "-lint", str(plist_path)], check=True)
    with plist_path.open("rb") as file:
        agent = plistlib.load(file)
    expected = {
        "Label": label,
        "BundleProgram": program,
        "ProgramArguments": [program, "--launch-agent"],
        "RunAtLoad": True,
        "KeepAlive": {"SuccessfulExit": False},
        "ProcessType": "Interactive",
        "ThrottleInterval": 10,
    }
    for key, value in expected.items():
        if agent.get(key) != value:
            raise ValueError(f"Unexpected {key} in {plist_path}.")
    if not (app / agent["BundleProgram"]).is_file():
        raise ValueError("BundleProgram does not point to the built host executable.")
    print(f"Launch agent bundled and validated: {plist_path}")


if __name__ == "__main__":
    try:
        verify(pathlib.Path(sys.argv[1]))
    except (OSError, ValueError, KeyError, IndexError, subprocess.CalledProcessError) as error:
        sys.exit(f"Launch agent verification failed: {error}")
