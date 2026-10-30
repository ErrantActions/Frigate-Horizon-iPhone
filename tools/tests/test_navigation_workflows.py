import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def source(path):
    return (ROOT / "App" / path).read_text(encoding="utf-8")


class TestNavigationWorkflows(unittest.TestCase):
    def test_compact_shell_has_five_tabs_before_wide_shortcuts(self):
        root = source("Views/HorizonRoot.swift")
        compact = root.split("if horizontalSizeClass == .regular {")[0]
        self.assertEqual(compact.count('Tab("'), 5)
        for label in ["Live", "Activity", "Recordings", "Library", "Settings"]:
            self.assertIn(f'Tab("{label}"', compact)
        self.assertIn("selection = selection.compactDestination", root)
        self.assertIn("if model.isAdmin", root)

    def test_review_uses_one_presentation_and_preserves_filters(self):
        review = source("Views/ReviewView.swift")
        self.assertNotIn("NavigationSplitView", review)
        self.assertNotIn("selectedID", review)
        self.assertIn("Button { workspace = row }", review)
        self.assertEqual(review.count(".fullScreenCover"), 1)
        self.assertIn("@Binding var query: ReviewQuery", review)
        hubs = source("Views/NavigationHubs.swift")
        self.assertIn("query: $state.reviewQuery", hubs)
        self.assertIn("query: $state.searchQuery", hubs)

    def test_camera_history_reuses_permission_checked_recordings_and_pauses_inline_consumers(self):
        live = source("Views/LiveView.swift")
        self.assertIn("!showQuickEvidence && !showHistory", live)
        self.assertIn("CameraHistoryContext(camera: camera.id", live)
        self.assertIn("RecordingsView(api: api, context: history, standalone: true)", live)
        recordings = source("Views/RecordingsView.swift")
        self.assertIn("if let selected, allowed", recordings)
        self.assertIn("context?.camera", recordings)
        self.assertIn("context?.day", recordings)
        self.assertIn("showBookmarks = false", recordings)

    def test_notifications_have_one_settings_entry_and_no_implicit_opt_in(self):
        settings = source("Views/SettingsView.swift")
        self.assertEqual(settings.count("NativePushSettingsView()"), 1)
        self.assertNotIn("NativeNotificationSetupView()", settings)
        self.assertIn("AdministrationView(api: api, embedded: true)", settings)
        push = source("Notifications/NativePushSettingsView.swift")
        self.assertIn("Enable on this iPhone", push)
        self.assertIn("push.capabilities?.enabled != true", push)
        self.assertIn("confirmTest = true", push)

    def test_inline_settings_only_stage_and_retain_review_and_discard(self):
        settings = source("Settings/NativeServerSettingsView.swift")
        number = settings.split("private struct NativeSettingNumberRow: View {")[1].split(
            "private struct NativeSettingValueEditor: View {"
        )[0]
        self.assertIn("store.set(candidate, path: path, authorized: true)", number)
        self.assertNotIn("api.action", number)
        self.assertIn("Find a setting", settings)
        self.assertIn("Discard unsaved settings?", settings)
        self.assertIn("Save and restart the real server?", settings)
