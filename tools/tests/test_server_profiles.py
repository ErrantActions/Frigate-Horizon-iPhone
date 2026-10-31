import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def source(*parts):
    return ROOT.joinpath(*parts).read_text(encoding="utf-8")


class TestServerProfiles(unittest.TestCase):
    def test_profiles_are_reachable_before_login_and_from_settings(self):
        for name in ["ConnectionView.swift", "SettingsView.swift"]:
            self.assertIn("ServerProfilesView()", source("App", "Views", name))
        profiles = source("App", "Views", "ServerProfilesView.swift")
        self.assertIn("Use primary address", profiles)
        self.assertIn("Use local address", profiles)
        self.assertIn("Switch without server cleanup?", profiles)
        self.assertIn("Discard profile edits?", profiles)

    def test_profile_credentials_stay_in_scoped_keychain_records(self):
        vault = source("App", "Networking", "SessionVault.swift")
        self.assertIn('"FrigateHorizon.profileSessions"', vault)
        self.assertIn('id.uuidString + "."', vault)
        self.assertIn("server: address.url.absoluteString", vault)
        self.assertIn("record.requireMatch(profileID: id, address: address)", vault)
        self.assertIn("kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly", vault)
        self.assertNotIn("UserDefaults", vault)
        model = source("App", "AppModel.swift")
        self.assertIn("JSONEncoder().encode(library)", model)
        self.assertNotIn("JSONEncoder().encode(record)", model)

    def test_switch_uses_cleanup_generation_and_exact_cached_account(self):
        model = source("App", "AppModel.swift")
        self.assertIn("releaseConnection(skippingPushCleanup: skippingPushCleanup, forgetSession: false)", model)
        self.assertIn("generation == connectionGeneration", model)
        self.assertIn("expectedUsername: record.username", model)
        self.assertIn("push.disable(using: api)", model)
        self.assertIn("push.abandonForLogout()", model)
        self.assertIn("LivePictureInPictureController.shared.stop()", model)
        self.assertNotIn("api?.close()", model)
        self.assertIn("clearProfileEndpoint", model)

    def test_dns_lookup_does_not_probe_servers_or_scan_networks(self):
        lookup = source("App", "Networking", "LocalServerAddressLookup.swift")
        self.assertIn("getaddrinfo(host", lookup)
        self.assertIn("LocalServerAddress.isPrivateIP", lookup)
        self.assertIn("lookup.cancel()", lookup)
        for operation in ["URLSession", "HorizonAPI", "NWBrowser", "NWConnection"]:
            self.assertNotIn(operation, lookup)

    def test_local_ip_does_not_weaken_tls_origin_or_cookie_rules(self):
        profiles = source("Sources", "HorizonCore", "ServerProfiles.swift")
        self.assertIn('result.url.scheme == "https"', profiles)
        self.assertIn("ServerAddress(session.server) == address", profiles)
        api = source("App", "Networking", "HorizonAPI.swift")
        self.assertIn("address.hasSameOrigin", api)
        self.assertNotIn("didReceive challenge", api)
        self.assertNotIn("serverTrust", api)
        self.assertNotIn("NSAllowsArbitraryLoads", source("App", "Info.plist"))

    def test_profile_selection_never_automatically_replays_passwords(self):
        model = source("App", "AppModel.swift")
        selection = model.split("func selectServerProfile(")[1].split(
            "private func beginConnectionAttempt"
        )[0]
        self.assertNotIn(".login(", selection)
        self.assertIn("SessionVault.profileSession(selection.profileID, address: address)", selection)
        self.assertIn("return false", selection)
        self.assertNotIn("return api == nil", selection)

    def test_selected_offline_profile_edit_and_delete_preserve_push_cleanup_obligation(self):
        model = source("App", "AppModel.swift")
        edit = model.split("func saveServerProfile(")[1].split("func deleteServerProfile(")[0]
        delete = model.split("func deleteServerProfile(")[1].split("func resetServerProfiles(")[0]
        for action in [edit, delete]:
            self.assertIn("NativePushController.shared.abandonForLogout()", action)
            self.assertIn("SessionVault.clear()", action)
