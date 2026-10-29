"""Verify image-capable releases retain signing and explicit readiness gates."""

import os
import subprocess
import unittest
from pathlib import Path

from test_prepare_ios import BASH, ROOT


@unittest.skipUnless(BASH and Path(BASH).is_file(), "Bash is required")
class TestImageBuildGate(unittest.TestCase):
    def gate(self, push, backend, pending="false"):
        environment = os.environ.copy()
        environment.update(
            ENABLE_NATIVE_PUSH=push,
            APNS_IMAGES_BACKEND_READY=backend,
            ALLOW_PENDING_IMAGE_BACKEND=pending,
            APP_BUNDLE_ID="com.example.horizon",
            APPLE_TEAM_ID="TEAMID1234",
            PROVISIONING_PROFILE_BASE64="synthetic-not-a-profile",
        )
        environment.pop("NOTIFICATION_SERVICE_PROFILE_BASE64", None)
        return subprocess.run(
            [str(BASH), str(ROOT / ".github" / "scripts" / "check-profile.sh")],
            env=environment,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )

    def test_push_flag_requires_its_own_approval(self):
        result = self.gate("false", "true")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("separately approved ENABLE_NATIVE_PUSH=true", result.stdout)

    def test_backend_readiness_cannot_be_assumed_from_text_push_capabilities(self):
        result = self.gate("true", "false")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Backend image-payload support", result.stdout)

    def test_extension_profile_is_required_before_any_decoding_or_compilation(self):
        result = self.gate("true", "true")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "Missing required signing configuration: NOTIFICATION_SERVICE_PROFILE_BASE64",
            result.stdout,
        )

    def test_explicit_pending_backend_approval_warns_without_waiving_extension(self):
        result = self.gate("true", "false", "true")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("::warning::Backend image support is pending", result.stdout)
        self.assertIn(
            "Missing required signing configuration: NOTIFICATION_SERVICE_PROFILE_BASE64",
            result.stdout,
        )

    def test_pending_backend_approval_does_not_waive_push_permission(self):
        result = self.gate("false", "false", "true")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("separately approved ENABLE_NATIVE_PUSH=true", result.stdout)

    def test_invalid_readiness_flags_are_rejected_even_with_pending_approval(self):
        for backend, pending, invalid_name in (
            ("unknown", "true", "APNS_IMAGES_BACKEND_READY"),
            ("false", "unknown", "ALLOW_PENDING_IMAGE_BACKEND"),
        ):
            with self.subTest(flag=invalid_name):
                result = self.gate("true", backend, pending)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"{invalid_name} must be true or false", result.stdout)
