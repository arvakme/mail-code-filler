#!/usr/bin/env python3
"""Check AutoFill build configuration or signed bundles; runtime enablement is a separate test."""

import argparse
import datetime
import json
import pathlib
import plistlib
import re
import subprocess
import sys
import tempfile

CAPABILITY = "com.apple.developer.authentication-services.autofill-credential-provider"
APP_TYPE = "com.apple.product-type.application"
EXTENSION_TYPE = "com.apple.product-type.app-extension"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def command(*args):
    result = subprocess.run(args, capture_output=True)
    require(result.returncode == 0, f"{args[0]} failed (exit {result.returncode}).")
    return result.stdout


def targets(path):
    settings = [item["buildSettings"] for item in json.loads(path.read_text())]
    selected = []
    for product_type in [APP_TYPE, EXTENSION_TYPE]:
        matches = [item for item in settings if item.get("PRODUCT_TYPE") == product_type]
        require(len(matches) == 1, f"Expected one {product_type} target.")
        selected.append(matches[0])
    return selected


def configuration(settings):
    for target in settings:
        name = target["PRODUCT_BUNDLE_IDENTIFIER"]
        require(target.get("CODE_SIGNING_ALLOWED") != "NO", "Compile-only is not signing verification.")
        profile = target.get("PROVISIONING_PROFILE_SPECIFIER", "")
        require(profile and not profile.startswith("YOUR_"),
                f"{name}: missing profile. Configure MAIL_CODE_HOST_PROFILE and MAIL_CODE_EXTENSION_PROFILE "
                "with installed profiles granting AutoFill and Keychain Sharing. No profile is created automatically.")
    print("Both targets specify profiles; Xcode must resolve and validate them during signing.")


def bundle_path(settings):
    return pathlib.Path(settings["TARGET_BUILD_DIR"]) / settings["FULL_PRODUCT_NAME"]


def profile_allows(profile, key, value):
    values = profile.get("Entitlements", {}).get(key, [])
    return any(identifier_allowed(value, allowed) for allowed in values)


def identifier_allowed(value, allowed):
    # Profile identifiers support a trailing wildcard, not shell glob syntax.
    if not value or any(char in value for char in "*?[]"):
        return False
    return value == allowed or (allowed.endswith("*") and value.startswith(allowed[:-1]))


def local_device_id():
    hardware = json.loads(command("system_profiler", "SPHardwareDataType", "-json"))
    device = hardware["SPHardwareDataType"][0].get("provisioning_UDID", "")
    require(device, "Cannot determine this Mac's provisioning UDID; local profile verification is incomplete.")
    return device


def signing_certificate(bundle):
    with tempfile.TemporaryDirectory(prefix="mail-code-certificate-") as directory:
        prefix = pathlib.Path(directory) / "cert"
        command("codesign", "--display", "--extract-certificates=" + str(prefix), str(bundle))
        return prefix.with_name("cert0").read_bytes()


def validate_profile(profile, entitlements, team, bundle_id, group, certificate, device):
    require(team in profile.get("TeamIdentifier", []), "Profile team mismatch.")
    expires = profile.get("ExpirationDate")
    require(isinstance(expires, datetime.datetime), "Provisioning profile has no valid expiration date.")
    if expires.tzinfo is None:
        expires = expires.replace(tzinfo=datetime.timezone.utc)
    require(expires > datetime.datetime.now(datetime.timezone.utc), "Provisioning profile expired.")
    require("OSX" in profile.get("Platform", []), "Profile does not support macOS.")
    require(certificate and certificate in profile.get("DeveloperCertificates", []),
            "Profile does not authorize the actual signing certificate.")
    require(device and device in profile.get("ProvisionedDevices", []),
            "Development profile does not authorize this Mac's provisioning UDID.")
    allowed = profile.get("Entitlements", {})
    require(entitlements.get("com.apple.developer.team-identifier") == team ==
            allowed.get("com.apple.developer.team-identifier"), "Signed/profile team entitlement mismatch.")
    require(allowed.get(CAPABILITY) is True, "Profile does not grant AutoFill.")
    require(entitlements.get(CAPABILITY) is True, "Signed bundle is missing AutoFill entitlement.")
    application_id = entitlements.get("com.apple.application-identifier", "")
    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    require(any(application_id == prefix + "." + bundle_id for prefix in prefixes),
            "Signed application identifier does not match bundle and profile prefix.")
    require(identifier_allowed(application_id, allowed.get("com.apple.application-identifier", "")),
            "Profile does not permit this application identifier.")
    groups = entitlements.get("keychain-access-groups", [])
    require(group in groups, "Signed bundle is missing the shared Keychain group.")
    require(all(profile_allows(profile, "keychain-access-groups", value) for value in groups),
            "Profile does not permit all signed Keychain groups.")


def verify_bundle(bundle, target, device):
    team = target["DEVELOPMENT_TEAM"]
    bundle_id = target["PRODUCT_BUNDLE_IDENTIFIER"]
    require(re.fullmatch(r"[A-Z0-9]{10}", team) is not None, "Invalid team identifier.")
    require(re.fullmatch(r"[A-Za-z0-9.-]+", bundle_id) is not None, "Invalid bundle identifier.")
    requirement = (f'anchor apple generic and identifier "{bundle_id}" '
                   f'and certificate leaf[subject.OU] = "{team}"')
    command("codesign", "--verify", "--strict", "--deep", "-R=" + requirement, str(bundle))
    entitlements = plistlib.loads(command("codesign", "--display", "--entitlements", "-", "--xml", str(bundle)))
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    require(info.get("CFBundleIdentifier") == bundle_id, "Info.plist bundle identifier differs from build settings.")
    group = info.get("MailCodeAutoFillAccessGroup", "")
    require(re.fullmatch(r"[A-Z0-9]{10}\.dev\.zhijie\.MailCodeFiller\.autofill", group) is not None,
            "Shared Keychain group is unresolved or unexpected.")
    profile_path = bundle / "Contents/embedded.provisionprofile"
    require(profile_path.is_file(), f"{bundle_id}: no embedded provisioning profile.")
    profile = plistlib.loads(command("security", "cms", "-D", "-i", str(profile_path)))
    validate_profile(profile, entitlements, team, bundle_id, group, signing_certificate(bundle), device)
    print(f"{bundle_id}: signature and AutoFill profile agreement verified.")
    return info, entitlements, group


def verify(settings):
    host, extension = settings
    device = local_device_id()
    app = bundle_path(host)
    host_info, _, group = verify_bundle(app, host, device)
    embedded = app / "Contents/PlugIns" / extension["FULL_PRODUCT_NAME"]
    info, entitlements, extension_group = verify_bundle(embedded, extension, device)
    require(host["DEVELOPMENT_TEAM"] == extension["DEVELOPMENT_TEAM"], "Host and extension teams differ.")
    require(extension_group == group, "Host and extension Keychain groups differ.")
    require(entitlements.get("com.apple.security.app-sandbox") is True, "Extension must be sandboxed.")
    require(entitlements["keychain-access-groups"] == [group], "Extension must not access host Gmail credentials.")
    capabilities = info["NSExtension"]["NSExtensionAttributes"]["ASCredentialProviderExtensionCapabilities"]
    require(capabilities.get("ProvidesOneTimeCodes") is True, "Extension does not advertise OTP support.")
    require(info["NSExtension"]["NSExtensionPointIdentifier"] ==
            "com.apple.authentication-services-credential-provider-ui", "Wrong extension point.")
    require(host_info["CFBundleVersion"] == info["CFBundleVersion"], "Host and extension versions differ.")
    print("Static AutoFill checks passed. System enablement and actual input still require runtime verification.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("settings", type=pathlib.Path)
    parser.add_argument("--configuration-only", action="store_true")
    args = parser.parse_args()
    settings = targets(args.settings)
    configuration(settings)
    if not args.configuration_only:
        verify(settings)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException) as error:
        sys.exit(f"AutoFill verification failed: {error}")
