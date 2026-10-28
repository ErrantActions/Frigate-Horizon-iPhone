import os
import subprocess
import unittest
from pathlib import Path

from test_prepare_ios import BASH, ROOT


@unittest.skipUnless(BASH and Path(BASH).is_file(), "Bash is required")
class TestSigningPrivacy(unittest.TestCase):
    def setUp(self):
        script = (ROOT / ".github" / "scripts" / "testflight.sh").read_text()
        start = script.index("mask_value() {")
        self.mask = script[start : script.index("\n}", start) + 2]
        start = script.index('identity="$(security find-identity')
        self.identity = script[
            start : script.index("\nsecurity set-key-partition-list", start)
        ]

    def run_script(self, body, identities=""):
        environment = os.environ.copy()
        environment["FAKE_IDENTITIES"] = identities
        return subprocess.run(
            [
                str(BASH),
                "--noprofile",
                "--norc",
                "-c",
                "set -euo pipefail\n" + self.mask + "\n" + body,
            ],
            env=environment,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )

    def test_mask_escapes_workflow_command_characters(self):
        result = self.run_script("mask_value $'Synthetic%Owner\\r\\nnext'")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "::add-mask::Synthetic%25Owner%0D%0Anext\n")

    def test_signing_identity_and_personal_name_are_both_masked(self):
        result = self.run_script(
            'security() { printf "%s\\n" "$FAKE_IDENTITIES"; }\n'
            "keychain=synthetic\nAPPLE_TEAM_ID=TEAMID1234\n" + self.identity,
            '1) ABC "Apple Distribution: Example Person (TEAMID1234)"',
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout,
            "::add-mask::Apple Distribution: Example Person (TEAMID1234)\n"
            "::add-mask::Example Person\n",
        )

    def test_missing_or_multiple_signing_identities_are_rejected(self):
        for identities in [
            "",
            (
                '1) ABC "Apple Distribution: Example Person (TEAMID1234)"\n'
                '2) DEF "Apple Distribution: Another Person (TEAMID1234)"'
            ),
        ]:
            with self.subTest(identities=identities):
                result = self.run_script(
                    'security() { printf "%s\\n" "$FAKE_IDENTITIES"; }\n'
                    "keychain=synthetic\nAPPLE_TEAM_ID=TEAMID1234\n" + self.identity,
                    identities,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(
                    "Expected one valid Apple Distribution signing identity",
                    result.stdout,
                )
