import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def source(*parts):
    return ROOT.joinpath(*parts).read_text(encoding="utf-8")


class TestHLSOnly(unittest.TestCase):
    def test_explicit_mode_reaches_avplayer_without_legacy_stream_aliases(self):
        live = source("App", "Views", "LiveView.swift")
        self.assertIn('Text("HLS-only (AVPlayer over HTTPS)").tag("hls")', live)
        self.assertIn('if transport == "hls" { return nil }', live)
        self.assertIn('requiresHLS: transport == "hls"', live)
        session = source("App", "Media", "LivePlaybackSession.swift")
        self.assertIn('transport == "https" || transport == "hls"', session)

    def test_required_hls_cannot_fall_through_to_websocket_or_webrtc(self):
        session = source("App", "Media", "LivePlaybackSession.swift")
        self.assertLess(
            session.index("guard LiveHLSGate.permitsCompatibilityFallback(configuration)"),
            session.index("self.hlsUnsupported = true"),
        )
        self.assertLess(session.index('guard transport != "hls"'), session.index("await httpsLive.run("))
        self.assertIn("No compatibility stream was opened.", session)
        self.assertIn("authenticationRequired: LiveHLSGate.requiresReauthentication(error)", session)

    def test_pip_scope_and_return_honor_explicit_hls_configuration(self):
        for path in [("App", "HorizonApp.swift"), ("App", "Views", "HorizonRoot.swift")]:
            self.assertIn("LiveHLSGate.mayRetain", source(*path))
        root = source("App", "Views", "HorizonRoot.swift")
        self.assertIn("model.api === api", root)
        self.assertIn("requested.cameraID && $0.settings.enabled", root)

    def test_hls_quality_choices_use_status_renditions_and_existing_native_abr(self):
        player = source("App", "Media", "HLSLiveStream.swift")
        self.assertIn("capability.renditions.map(\\.height)", player)
        self.assertIn("AVPlayerItem(asset: source.asset)", player)
        self.assertIn("Double(master.lowestBandwidth)", player)
        live = source("App", "Views", "LiveView.swift")
        self.assertIn("onHLSHeightsChanged: { hlsHeights = $0 }", live)
        self.assertIn('transport == "hls" ? hlsHeights', live)
        self.assertNotIn("NSAllowsArbitraryLoads", source("App", "Info.plist"))
