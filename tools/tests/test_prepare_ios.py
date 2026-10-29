import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if os.name == "nt":
    BASH = (
        Path(os.environ.get("ProgramFiles", r"C:\Program Files"))
        / "Git"
        / "bin"
        / "bash.exe"
    )
else:
    BASH = shutil.which("bash")


class TestExportComplianceMetadata(unittest.TestCase):
    def test_existing_exempt_classification_is_boolean_in_both_bundles(self):
        for path in (
            ROOT / "App" / "Info.plist",
            ROOT / "NotificationService" / "Info.plist",
        ):
            with self.subTest(bundle=path.parent.name):
                with path.open("rb") as source:
                    info = plistlib.load(source)
                self.assertIs(info.get("ITSAppUsesNonExemptEncryption"), False)


@unittest.skipUnless(
    BASH and Path(BASH).is_file(), "Bash is required for preparation-script tests"
)
class TestPrepareIOS(unittest.TestCase):
    def run_prepare(self, value=None):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            commands = {
                "xcodebuild": "#!/bin/bash\nprintf 'Xcode 27.1\\n'\n",
                "xcrun": "#!/bin/bash\nprintf '27.1\\n'\n",
                "xcodegen": (
                    "#!/bin/bash\n"
                    'printf "GEN_PUSH=%s\\nGEN_ENTITLEMENTS=%s\\n" "$NATIVE_PUSH_ENABLED" "$APP_ENTITLEMENTS_FILE"\n'
                ),
            }
            for name, script in commands.items():
                command = path / name
                with command.open("w", encoding="utf-8", newline="\n") as output:
                    output.write(script)
                command.chmod(0o755)
            env = os.environ.copy()
            env.pop("ENABLE_NATIVE_PUSH", None)
            if value is not None:
                env["ENABLE_NATIVE_PUSH"] = value
            env.update(
                PATH=directory,
                PREPARE_SCRIPT=str(ROOT / ".github" / "scripts" / "prepare-ios.sh"),
                GITHUB_ENV=str(path / "build.env"),
                REQUIRE_DUO="true",
            )
            result = subprocess.run(
                [str(BASH), "--noprofile", "--norc", "-c", 'source "$PREPARE_SCRIPT"'],
                cwd=ROOT,
                env=env,
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
            exported = (
                (path / "build.env").read_text()
                if (path / "build.env").exists()
                else ""
            )
            return result, exported

    def test_default_build_has_no_push_entitlement(self):
        result, exported = self.run_prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "GEN_PUSH=NO\nGEN_ENTITLEMENTS=App/Horizon.entitlements\n", result.stdout
        )
        self.assertIn(
            "NATIVE_PUSH_ENABLED=NO\nAPP_ENTITLEMENTS_FILE=App/Horizon.entitlements\n",
            exported,
        )

    def test_explicit_disabled_build_has_no_push_entitlement(self):
        result, exported = self.run_prepare("false")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "GEN_PUSH=NO\nGEN_ENTITLEMENTS=App/Horizon.entitlements\n", result.stdout
        )
        self.assertIn("APP_ENTITLEMENTS_FILE=App/Horizon.entitlements\n", exported)

    def test_enabled_build_selects_push_entitlement(self):
        result, exported = self.run_prepare("true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "GEN_PUSH=YES\nGEN_ENTITLEMENTS=App/HorizonPush.entitlements\n",
            result.stdout,
        )
        self.assertIn(
            "NATIVE_PUSH_ENABLED=YES\nAPP_ENTITLEMENTS_FILE=App/HorizonPush.entitlements\n",
            exported,
        )

    def test_invalid_flags_fail_before_running_build_tools(self):
        for value in ("yes", "TRUE", "1"):
            with self.subTest(value=value):
                result, exported = self.run_prepare(value)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("ENABLE_NATIVE_PUSH must be true or false", result.stdout)
                self.assertNotIn("Xcode", result.stdout)
                self.assertEqual(exported, "")
