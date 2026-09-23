#!/usr/bin/env python3
"""Regression checks for profile agreement. Synthetic profiles cannot prove system acceptance."""

import copy
import datetime
import importlib.util
import pathlib
import plistlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("gate", pathlib.Path(__file__).with_name("verify-autofill.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.team = "TESTTEAM01"
        self.bundle = "dev.example.App"
        self.group = self.team + ".dev.example.shared"
        self.certificate = b"synthetic-signing-certificate"
        self.device = "synthetic-local-Mac-UDID"
        self.entitlements = {
            gate.CAPABILITY: True,
            "com.apple.application-identifier": self.team + "." + self.bundle,
            "com.apple.developer.team-identifier": self.team,
            "keychain-access-groups": [self.group],
        }
        self.profile = {
            "TeamIdentifier": [self.team],
            "ApplicationIdentifierPrefix": [self.team],
            "Platform": ["OSX"],
            "DeveloperCertificates": [self.certificate],
            "ProvisionedDevices": [self.device],
            "ExpirationDate": datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) + datetime.timedelta(days=1),
            "Entitlements": copy.deepcopy(self.entitlements),
        }

    def validate(self):
        gate.validate_profile(self.profile, self.entitlements, self.team, self.bundle, self.group,
                              self.certificate, self.device)

    def test_certificate_platform_and_local_device_are_required(self):
        for key, wrong, message in [
            ("DeveloperCertificates", [b"another-certificate-on-the-same-team"], "signing certificate"),
            ("Platform", ["iOS"], "macOS"),
            ("ProvisionedDevices", ["another-Mac"], "provisioning UDID"),
        ]:
            original = self.profile[key]
            for value in [wrong, []]:
                with self.subTest(key=key, value=value):
                    self.profile[key] = value
                    with self.assertRaisesRegex(ValueError, message):
                        self.validate()
            del self.profile[key]
            with self.assertRaisesRegex(ValueError, message):
                self.validate()
            self.profile[key] = original
        self.profile.pop("ProvisionedDevices")
        self.profile["ProvisionsAllDevices"] = True
        with self.assertRaisesRegex(ValueError, "Development profile"):
            self.validate()

    def test_missing_expiry_fails_and_aware_expiry_works(self):
        self.profile.pop("ExpirationDate")
        with self.assertRaisesRegex(ValueError, "expiration date"):
            self.validate()
        self.profile["ExpirationDate"] = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=1)
        self.validate()

    def test_app_prefix_is_not_assumed_to_equal_team(self):
        self.profile["ApplicationIdentifierPrefix"] = ["OLDPREFIX1"]
        app_id = "OLDPREFIX1." + self.bundle
        self.entitlements["com.apple.application-identifier"] = app_id
        self.profile["Entitlements"]["com.apple.application-identifier"] = app_id
        self.validate()
        self.entitlements["com.apple.application-identifier"] = "UNLISTED01." + self.bundle
        self.profile["Entitlements"]["com.apple.application-identifier"] = "*"
        with self.assertRaisesRegex(ValueError, "profile prefix"):
            self.validate()

    def test_team_entitlement_must_match_profile_and_signer(self):
        for values in [self.entitlements, self.profile["Entitlements"]]:
            values["com.apple.developer.team-identifier"] = "OTHERTEAM1"
            with self.assertRaisesRegex(ValueError, "team entitlement"):
                self.validate()
            values["com.apple.developer.team-identifier"] = self.team

    def test_signed_groups_cannot_contain_wildcards(self):
        self.profile["Entitlements"]["keychain-access-groups"] = [self.team + ".*"]
        self.entitlements["keychain-access-groups"].append(self.team + ".*")
        with self.assertRaisesRegex(ValueError, "Keychain groups"):
            self.validate()

    def test_rejects_capability_missing_from_profile_or_signature(self):
        for value in [self.profile["Entitlements"], self.entitlements]:
            with self.subTest(value=value is self.entitlements):
                value[gate.CAPABILITY] = False
                with self.assertRaisesRegex(ValueError, "AutoFill"):
                    self.validate()
                value[gate.CAPABILITY] = True

    def test_shared_group_must_be_in_both_signature_and_profile(self):
        self.validate()
        self.profile["Entitlements"]["keychain-access-groups"] = ["OTHERTEAM1.*"]
        with self.assertRaisesRegex(ValueError, "Keychain groups"):
            self.validate()
        self.profile["Entitlements"]["keychain-access-groups"] = [self.team + ".*"]
        self.validate()
        self.entitlements["keychain-access-groups"] = []
        with self.assertRaisesRegex(ValueError, "missing the shared"):
            self.validate()

    def test_wrong_team_wrong_app_and_expiry_are_rejected(self):
        changes = [
            ("TeamIdentifier", ["OTHERTEAM1"]),
            ("ExpirationDate", datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) - datetime.timedelta(seconds=1)),
            ("Entitlements", {**self.entitlements, "com.apple.application-identifier": self.team + ".dev.other.App"}),
        ]
        original = copy.deepcopy(self.profile)
        for key, value in changes:
            with self.subTest(key=key):
                self.profile = {**original, key: value}
                with self.assertRaises(ValueError):
                    self.validate()


class BundleTests(unittest.TestCase):
    def test_certificate_extraction_reads_leaf_and_removes_temporary_files(self):
        paths = []

        def extract(*args):
            prefix = pathlib.Path(args[2].split("=", 1)[1])
            paths.append(prefix.parent)
            prefix.with_name("cert0").write_bytes(b"leaf")
            prefix.with_name("cert1").write_bytes(b"issuer")
            return b""

        with patch.object(gate, "command", side_effect=extract):
            self.assertEqual(gate.signing_certificate(pathlib.Path("App.app")), b"leaf")
        self.assertFalse(paths[0].exists())

    def test_missing_provisioning_udid_does_not_fall_back_to_hardware_uuid(self):
        with patch.object(gate, "command", return_value=b'{"SPHardwareDataType":[{"platform_UUID":"wrong-id"}]}'):
            with self.assertRaisesRegex(ValueError, "provisioning UDID"):
                gate.local_device_id()

    def test_bundle_info_must_match_build_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = pathlib.Path(directory) / "App.app"
            (bundle / "Contents").mkdir(parents=True)
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "dev.other.App"}))
            target = {"DEVELOPMENT_TEAM": "TESTTEAM01", "PRODUCT_BUNDLE_IDENTIFIER": "dev.example.App"}
            with patch.object(gate, "command", return_value=plistlib.dumps({})):
                with self.assertRaisesRegex(ValueError, "Info.plist bundle identifier"):
                    gate.verify_bundle(bundle, target, "local-UDID")

    def test_checks_embedded_extension_and_rejects_group_or_sandbox_changes(self):
        group = "TESTTEAM01.dev.zhijie.MailCodeFiller.autofill"
        settings = [
            {"TARGET_BUILD_DIR": "/actual", "FULL_PRODUCT_NAME": "App.app", "DEVELOPMENT_TEAM": "TESTTEAM01"},
            {"TARGET_BUILD_DIR": "/standalone", "FULL_PRODUCT_NAME": "AutoFill.appex", "DEVELOPMENT_TEAM": "TESTTEAM01"},
        ]
        host_info = {"CFBundleVersion": "3"}
        info = {"CFBundleVersion": "3", "NSExtension": {
            "NSExtensionPointIdentifier": "com.apple.authentication-services-credential-provider-ui",
            "NSExtensionAttributes": {"ASCredentialProviderExtensionCapabilities": {"ProvidesOneTimeCodes": True}},
        }}
        entitlements = {"com.apple.security.app-sandbox": True, "keychain-access-groups": [group]}
        for change, message in [(None, None), ("group", "groups differ"),
                                ("credential", "Gmail credentials"), ("sandbox", "sandboxed")]:
            with self.subTest(change=change):
                signed = copy.deepcopy(entitlements)
                extension_group = group
                if change == "group":
                    extension_group = "OTHERTEAM1.dev.zhijie.MailCodeFiller.autofill"
                if change == "credential":
                    signed["keychain-access-groups"].append("TESTTEAM01.dev.zhijie.MailCodeFiller")
                if change == "sandbox":
                    signed["com.apple.security.app-sandbox"] = False
                with patch.object(gate, "local_device_id", return_value="local-UDID"), \
                     patch.object(gate, "verify_bundle", side_effect=[(host_info, {}, group),
                                  (info, signed, extension_group)]) as bundles:
                    if message:
                        with self.assertRaisesRegex(ValueError, message):
                            gate.verify(settings)
                    else:
                        gate.verify(settings)
                    self.assertEqual(bundles.call_args_list[1].args[0],
                                     pathlib.Path("/actual/App.app/Contents/PlugIns/AutoFill.appex"))


if __name__ == "__main__":
    unittest.main()
