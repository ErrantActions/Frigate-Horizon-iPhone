import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from test_prepare_ios import BASH, ROOT


@unittest.skipUnless(BASH and Path(BASH).is_file(), "Bash is required")
class TestBuildNumber(unittest.TestCase):
    def select_number(self, run, offset=None):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "build.env"
            environment = os.environ.copy()
            environment.pop("BUILD_NUMBER_OFFSET", None)
            environment.update(GITHUB_RUN_NUMBER=run, GITHUB_ENV=str(output))
            if offset is not None:
                environment["BUILD_NUMBER_OFFSET"] = offset
            result = subprocess.run(
                [
                    str(BASH),
                    str(ROOT / ".github" / "scripts" / "select-build-number.sh"),
                ],
                env=environment,
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
            return result, output.read_text() if output.exists() else ""

    def test_new_repository_starts_above_previous_uploads(self):
        result, output = self.select_number("1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, "BUILD_NUMBER=1001\n")

    def test_custom_offset_and_decimal_leading_zero_are_supported(self):
        result, output = self.select_number("7", "0100")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, "BUILD_NUMBER=107\n")

    def test_invalid_inputs_never_export_a_build_number(self):
        for run, offset in [
            ("", None),
            ("0", None),
            ("1", "-1"),
            ("1", "bad"),
            ("10000", None),
        ]:
            with self.subTest(run=run, offset=offset):
                result, output = self.select_number(run, offset)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(output, "")

    def test_build_numbers_cannot_overflow_the_version_component(self):
        result, output = self.select_number("1", "9999")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output, "")
