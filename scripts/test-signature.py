#!/usr/bin/env python3
"""Exercise the signing gate against the built app and a disposable ad-hoc copy."""

import json
import pathlib
import shutil
import subprocess
import sys
import tempfile


def check(command, should_pass):
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print(f"$ {command!r}\nRAW_EXIT={result.returncode}\n{result.stdout}")
    if (result.returncode == 0) != should_pass:
        raise SystemExit("Unexpected signing-gate result.")


def main(settings_path):
    verifier = str(pathlib.Path(__file__).with_name("verify-signature.py"))
    check([sys.executable, verifier, str(settings_path)], True)
    settings = json.loads(settings_path.read_text())
    host = next(t["buildSettings"] for t in settings
                if t["buildSettings"].get("PRODUCT_TYPE") == "com.apple.product-type.application")
    product = pathlib.Path(host["TARGET_BUILD_DIR"]) / host["FULL_PRODUCT_NAME"]
    with tempfile.TemporaryDirectory(prefix="mail-code-signing-", dir=settings_path.parent) as directory:
        root = pathlib.Path(directory)
        copy = root / product.name
        shutil.copytree(product, copy, symlinks=True)
        check(["codesign", "--force", "--sign", "-", "--options", "runtime", str(copy)], True)
        host["TARGET_BUILD_DIR"] = str(root.resolve())
        probe = root / "settings.json"
        probe.write_text(json.dumps(settings))
        check([sys.executable, verifier, str(probe)], False)
        # A certificate for another team must not satisfy this project's identity requirement.
        host["TARGET_BUILD_DIR"] = str(product.parent)
        host["DEVELOPMENT_TEAM"] = "0000000000"
        probe.write_text(json.dumps(settings))
        check([sys.executable, verifier, str(probe)], False)
    assert not root.exists()
    print("Signing gate accepted the original, rejected ad-hoc/wrong-team products, and removed its copies.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: python3 scripts/test-signature.py build/Debug-settings.json")
    main(pathlib.Path(sys.argv[1]))
