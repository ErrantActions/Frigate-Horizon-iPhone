"""Local, no-Xcode tests for the early provisioning-profile spending gate."""

import copy
import datetime
import importlib.util
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).parents[2] / ".github" / "scripts" / "validate-profile.py"
SPEC = importlib.util.spec_from_file_location("validate_profile", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class TestValidateProfile(unittest.TestCase):
    def setUp(self):
        self.now = datetime.datetime(2026, 10, 28, tzinfo=datetime.timezone.utc)
        self.profile = {
            "Name": "Test App Store",
            "TeamIdentifier": ["TEAMID1234"],
            "ExpirationDate": datetime.datetime(2027, 10, 28),
            "Entitlements": {
                "application-identifier": "TEAMID1234.com.example.horizon",
                "get-task-allow": False,
            },
        }

    def validate(self, native_push=False):
        return MODULE.validate_profile(
            self.profile, "TEAMID1234", "com.example.horizon", native_push, self.now
        )

    def test_existing_non_push_profile_remains_supported(self):
        options = self.validate()
        self.assertEqual(
            options["provisioningProfiles"], {"com.example.horizon": "Test App Store"}
        )
        self.assertEqual(options["method"], "app-store-connect")
        self.assertFalse(options["manageAppVersionAndBuildNumber"])

    def test_native_push_requires_production_entitlement(self):
        with self.assertRaisesRegex(ValueError, "aps-environment"):
            self.validate(native_push=True)
        self.profile["Entitlements"]["aps-environment"] = "development"
        with self.assertRaises(ValueError):
            self.validate(native_push=True)
        self.profile["Entitlements"]["aps-environment"] = "production"
        self.assertIsInstance(self.validate(native_push=True), dict)

    def test_mismatched_team_and_bundle_are_rejected(self):
        self.profile["TeamIdentifier"] = ["OTHERTEAM1"]
        with self.assertRaises(ValueError):
            self.validate()
        self.profile["TeamIdentifier"] = ["TEAMID1234"]
        self.profile["Entitlements"]["application-identifier"] = (
            "TEAMID1234.com.other.app"
        )
        with self.assertRaises(ValueError):
            self.validate()

    def test_expired_or_missing_expiry_is_rejected(self):
        self.profile["ExpirationDate"] = self.now
        with self.assertRaises(ValueError):
            self.validate()
        del self.profile["ExpirationDate"]
        with self.assertRaises(TypeError):
            self.validate()

    def test_non_app_store_distribution_types_are_rejected(self):
        self.profile["ProvisionedDevices"] = []
        with self.assertRaises(ValueError):
            self.validate()
        del self.profile["ProvisionedDevices"]
        self.profile["ProvisionsAllDevices"] = True
        with self.assertRaises(ValueError):
            self.validate()
        del self.profile["ProvisionsAllDevices"]
        self.profile["Entitlements"]["get-task-allow"] = True
        with self.assertRaises(ValueError):
            self.validate()

    def test_invalid_entitlements_and_missing_name_are_rejected(self):
        self.profile["Name"] = ""
        with self.assertRaises(ValueError):
            self.validate()
        self.profile["Entitlements"] = None
        with self.assertRaises(ValueError):
            self.validate()

    def image_profiles(self):
        app = copy.deepcopy(self.profile)
        app["ApplicationIdentifierPrefix"] = ["TEAMID1234"]
        app["DeveloperCertificates"] = [b"synthetic-public-distribution-certificate"]
        app["Entitlements"].update(
            {
                "aps-environment": "production",
                "keychain-access-groups": ["TEAMID1234.*"],
            }
        )
        extension = copy.deepcopy(app)
        extension["Name"] = "Notification service"
        extension["Entitlements"]["application-identifier"] = (
            "TEAMID1234.com.example.horizon.NotificationService"
        )
        del extension["Entitlements"]["aps-environment"]
        return app, extension

    def test_image_profiles_map_both_targets_without_requiring_push_on_the_extension(
        self,
    ):
        app, extension = self.image_profiles()
        options = MODULE.validate_image_profiles(
            app, extension, "TEAMID1234", "com.example.horizon", self.now
        )
        self.assertEqual(
            options["provisioningProfiles"],
            {
                "com.example.horizon": "Test App Store",
                "com.example.horizon.NotificationService": "Notification service",
            },
        )

    def test_image_profiles_require_production_push_on_the_containing_app(self):
        app, extension = self.image_profiles()
        app["Entitlements"]["aps-environment"] = "development"
        with self.assertRaisesRegex(ValueError, "production"):
            MODULE.validate_image_profiles(
                app, extension, "TEAMID1234", "com.example.horizon", self.now
            )

    def test_image_profiles_require_shared_keychain_access_on_both_targets(self):
        for target in ("app", "extension"):
            with self.subTest(target=target):
                app, extension = self.image_profiles()
                profile = app if target == "app" else extension
                profile["Entitlements"]["keychain-access-groups"] = [
                    "TEAMID1234.unrelated"
                ]
                with self.assertRaisesRegex(ValueError, "Keychain"):
                    MODULE.validate_image_profiles(
                        app, extension, "TEAMID1234", "com.example.horizon", self.now
                    )

    def test_image_profiles_reject_a_different_extension_identity_or_signing_prefix(
        self,
    ):
        app, extension = self.image_profiles()
        extension["Entitlements"]["application-identifier"] = (
            "TEAMID1234.com.example.other"
        )
        with self.assertRaisesRegex(ValueError, "APP_BUNDLE_ID"):
            MODULE.validate_image_profiles(
                app, extension, "TEAMID1234", "com.example.horizon", self.now
            )
        app, extension = self.image_profiles()
        extension["ApplicationIdentifierPrefix"] = ["OTHERPREFIX"]
        with self.assertRaisesRegex(ValueError, "prefix"):
            MODULE.validate_image_profiles(
                app, extension, "TEAMID1234", "com.example.horizon", self.now
            )

    def test_image_profiles_require_the_same_distribution_certificate(self):
        app, extension = self.image_profiles()
        extension["DeveloperCertificates"] = [b"another-public-certificate"]
        with self.assertRaisesRegex(ValueError, "same distribution certificate"):
            MODULE.validate_image_profiles(
                app, extension, "TEAMID1234", "com.example.horizon", self.now
            )

    def test_image_profiles_also_reject_expired_or_development_extension_profiles(self):
        for key, value in [("ExpirationDate", self.now), ("ProvisionedDevices", [])]:
            with self.subTest(key=key):
                app, extension = self.image_profiles()
                extension[key] = value
                with self.assertRaises(ValueError):
                    MODULE.validate_image_profiles(
                        app, extension, "TEAMID1234", "com.example.horizon", self.now
                    )


if __name__ == "__main__":
    unittest.main()
