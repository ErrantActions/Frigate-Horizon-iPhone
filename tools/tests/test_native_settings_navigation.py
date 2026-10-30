import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DESTINATIONS = (
    "NativeSettingsNode",
    "NativeSettingRow",
    "NativeSettingValueEditor",
    "NativeSettingsReview",
    "NativeSettingNumberRow",
)


class TestNativeSettingsNavigation(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (
            ROOT / "App" / "Settings" / "NativeServerSettingsView.swift"
        ).read_text(encoding="utf-8")

    def test_destinations_require_an_explicit_observed_store(self):
        for name in DESTINATIONS:
            with self.subTest(destination=name):
                declaration = re.search(
                    rf"private struct {name}: View \{{(.*?)\n    var body:",
                    self.source,
                    re.DOTALL,
                )
                self.assertIsNotNone(declaration)
                self.assertRegex(
                    declaration.group(1),
                    r"@ObservedObject var store: NativeServerSettingsStore",
                )
                self.assertNotRegex(
                    declaration.group(1),
                    r"@EnvironmentObject[^\n]*NativeServerSettingsStore",
                )

    def test_every_navigation_path_passes_the_existing_store(self):
        calls = list(
            re.finditer(
                r"\b(" + "|".join(DESTINATIONS) + r")\s*\(",
                self.source,
            )
        )
        self.assertEqual({call.group(1) for call in calls}, set(DESTINATIONS))
        for call in calls:
            with self.subTest(destination=call.group(1), offset=call.start()):
                self.assertRegex(
                    self.source[call.end() : call.end() + 80],
                    r"\A\s*store:\s*store\s*[,)]",
                )

    def test_root_owns_one_store_for_the_entire_draft_navigation(self):
        self.assertIn(
            "@StateObject private var store: NativeServerSettingsStore",
            self.source,
        )
        self.assertIn(
            "_store = StateObject(wrappedValue: NativeServerSettingsStore(api: api))",
            self.source,
        )
        self.assertEqual(self.source.count("NativeServerSettingsStore(api: api)"), 1)
