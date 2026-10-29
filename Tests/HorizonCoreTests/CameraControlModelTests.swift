import XCTest
@testable import HorizonCore

final class CameraControlModelTests: XCTestCase {
    private func capabilities(
        camera: String = "front", supported: Bool = true, panTilt: Bool = true,
        zoom: Bool = true, presets: [[String: String]] = [["id": "home", "name": "Home"]]
    ) throws -> CameraControlCapabilities {
        let value: [String: Any] = [
            "camera": camera,
            "ptz": ["supported": supported, "pan_tilt": panTilt, "zoom": zoom, "presets": presets],
            "talkback": ["supported": true],
        ]
        return try JSONDecoder().decode(CameraControlCapabilities.self,
            from: JSONSerialization.data(withJSONObject: value))
    }

    func testExactBackendCapabilitiesAndPresetSchema() throws {
        let result = try capabilities()
        try result.validate(cameraID: "front")
        XCTAssertEqual(result.camera, "front")
        XCTAssertTrue(result.ptz.panTilt)
        XCTAssertTrue(result.ptz.zoom)
        XCTAssertTrue(result.talkback.supported)
        XCTAssertEqual(result.ptz.presets.first?.id, "home")
    }

    func testMissingFlagsDoNotManufactureCapabilities() throws {
        let data = Data(#"{"camera":"front","ptz":{"supported":true},"talkback":{"supported":true}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(CameraControlCapabilities.self, from: data))
    }

    func testCapabilitiesMustMatchTheSelectedCamera() throws {
        let result = try capabilities(camera: "back")
        XCTAssertThrowsError(try result.validate(cameraID: "front"))
        XCTAssertThrowsError(try CameraPTZRequest(command: .up, leaseID: UUID(),
            capabilities: result, cameraID: "front"))
    }

    func testNativeRouteCannotEscapeTheCameraControlsNamespace() throws {
        XCTAssertEqual(try CameraControlRoute.prefix(cameraID: "front"),
            ["native", "cameras", "front", "controls"])
        for id in ["", " ", ".", "..", "../front", "front/back", "front\\back", "%2e%2e", "%2ffront", "front\n"] {
            XCTAssertThrowsError(try CameraControlRoute.prefix(cameraID: id))
        }
    }

    func testOnlyWhitelistedPhysicalCommandsCanDecode() throws {
        XCTAssertEqual(Set(CameraPTZCommand.allCases.map(\.rawValue)),
            Set(["MOVE_UP", "MOVE_DOWN", "MOVE_LEFT", "MOVE_RIGHT", "ZOOM_IN", "ZOOM_OUT", "STOP", "PRESET"]))
        for invalid in ["move_up", "REBOOT", "GOTO", "", "MOVE_UP;STOP"] {
            XCTAssertThrowsError(try JSONDecoder().decode(CameraPTZCommand.self,
                from: JSONEncoder().encode(invalid)))
        }
    }

    func testMovementIsGatedByEachAdvertisedAxis() throws {
        let result = try capabilities(panTilt: false, zoom: true)
        for command in [CameraPTZCommand.up, .down, .left, .right] {
            XCTAssertThrowsError(try CameraPTZRequest(command: command, leaseID: UUID(),
                capabilities: result, cameraID: "front"))
        }
        XCTAssertNoThrow(try CameraPTZRequest(command: .zoomIn, leaseID: UUID(),
            capabilities: result, cameraID: "front"))
        let noZoom = try capabilities(zoom: false)
        for command in [CameraPTZCommand.zoomIn, .zoomOut] {
            XCTAssertThrowsError(try CameraPTZRequest(command: command, leaseID: UUID(),
                capabilities: noZoom, cameraID: "front"))
        }
    }

    func testUnsupportedPTZOverridesIndividualCapabilityFlags() throws {
        let result = try capabilities(supported: false)
        for command in CameraPTZCommand.allCases where command != .stop {
            XCTAssertThrowsError(try CameraPTZRequest(command: command, leaseID: UUID(),
                preset: command == .preset ? "home" : nil,
                capabilities: result, cameraID: "front"))
        }
    }

    func testPresetsMustBeAdvertisedAndCannotAccompanyOtherCommands() throws {
        let result = try capabilities()
        XCTAssertNoThrow(try CameraPTZRequest(command: .preset, leaseID: UUID(), preset: "home",
            capabilities: result, cameraID: "front"))
        for preset in [nil, "", "other", "../home"] as [String?] {
            XCTAssertThrowsError(try CameraPTZRequest(command: .preset, leaseID: UUID(), preset: preset,
                capabilities: result, cameraID: "front"))
        }
        XCTAssertThrowsError(try CameraPTZRequest(command: .up, leaseID: UUID(), preset: "home",
            capabilities: result, cameraID: "front"))
    }

    func testAmbiguousOrEmptyPresetsAreRejectedRatherThanShown() throws {
        for presets in [
            [["id": "home", "name": "One"], ["id": "home", "name": "Two"]],
            [["id": " ", "name": "Empty"]],
            [["id": "home", "name": ""]],
        ] {
            XCTAssertThrowsError(try capabilities(presets: presets).validate(cameraID: "front"))
        }
    }

    func testPTZEncodingHasOnlyBoundedNativeLeaseFields() throws {
        let lease = UUID()
        let body = try CameraPTZRequest(command: .up, leaseID: lease,
            capabilities: capabilities(), cameraID: "front")
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertEqual(Set(value.keys), Set(["command", "lease_id", "duration_ms"]))
        XCTAssertEqual(value["command"] as? String, "MOVE_UP")
        XCTAssertEqual((value["lease_id"] as? String).flatMap(UUID.init(uuidString:)), lease)
        XCTAssertEqual(value["duration_ms"] as? Int, 500)
    }

    func testPresetEncodingUsesTheAdvertisedIDNotItsDisplayName() throws {
        let body = try CameraPTZRequest(command: .preset, leaseID: UUID(), preset: "home",
            capabilities: capabilities(), cameraID: "front")
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertEqual(value["preset"] as? String, "home")
        XCTAssertEqual(value["command"] as? String, "PRESET")
    }

    func testStopCanBeEncodedAfterCapabilityRevocationWithoutAReplacementLease() throws {
        let lease = UUID()
        let body = CameraPTZRequest.stop(leaseID: lease)
        XCTAssertEqual(body.command, .stop)
        XCTAssertEqual(body.leaseID, lease)
        XCTAssertNil(body.preset)
        XCTAssertEqual(body.durationMilliseconds, 500)
        XCTAssertThrowsError(try CameraPTZRequest(command: .stop, leaseID: lease,
            capabilities: capabilities(), cameraID: "front"))
    }

    func testTalkbackUsesAudioOnlyOfferAndAnswerWithoutAnArbitraryURL() throws {
        let sdp = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=sendrecv\r\n"
        let offer = try CameraTalkbackDescription(offer: sdp)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(offer)) as? [String: String])
        XCTAssertEqual(value, ["type": "offer", "sdp": sdp])
        XCTAssertThrowsError(try offer.validatedAnswer())
        let answer = try JSONDecoder().decode(CameraTalkbackDescription.self,
            from: JSONSerialization.data(withJSONObject: ["type": "answer", "sdp": sdp]))
        XCTAssertEqual(try answer.validatedAnswer(), sdp)
    }

    func testTalkbackRejectsVideoDataOnlyEmptyAndOversizedDescriptions() {
        for sdp in ["", "v=0\r\n", "m=video 9 RTP/SAVPF 96\r\n",
                    "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n",
                    "m=audio 9 RTP/SAVPF 111\r\nm=video 9 RTP/SAVPF 96\r\n",
                    "m=audio 9 RTP/SAVPF 111\r\nm=audio 9 RTP/SAVPF 111\r\n",
                    "m=audio 9 RTP/SAVPF 111\r\n" + String(repeating: "x", count: 262_144)] {
            XCTAssertThrowsError(try CameraTalkbackDescription(offer: sdp))
        }
    }

    func testTalkbackAnswerMustActuallyAcceptMicrophoneAudio() throws {
        for sdp in ["v=0\r\nm=audio 0 UDP/TLS/RTP/SAVPF 111\r\na=sendrecv\r\n",
                    "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=sendonly\r\n",
                    "v=0\r\na=inactive\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"] {
            let answer = try JSONDecoder().decode(CameraTalkbackDescription.self,
                from: JSONSerialization.data(withJSONObject: ["type": "answer", "sdp": sdp]))
            XCTAssertThrowsError(try answer.validatedAnswer())
        }
    }

    func testMediaDirectionOverridesSessionDirectionInATalkbackAnswer() throws {
        let sdp = "v=0\r\na=sendonly\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=recvonly\r\n"
        let answer = try JSONDecoder().decode(CameraTalkbackDescription.self,
            from: JSONSerialization.data(withJSONObject: ["type": "answer", "sdp": sdp]))
        XCTAssertEqual(try answer.validatedAnswer(), sdp)
    }

    func testTalkbackLeaseRequiresAllHeadersAndAcceptsCaseInsensitiveNames() throws {
        let id = UUID()
        let lease = try CameraTalkbackLease(headers: [
            "x-horizon-talkback-lease": " \(id.uuidString) ",
            "X-HORIZON-TALKBACK-EXPIRES": "1015",
            "x-Horizon-Talkback-Renew-After-Ms": "5000",
        ], now: 1000)
        XCTAssertEqual(lease.id, id)
        XCTAssertEqual(lease.expiresAt, 1015)
        XCTAssertEqual(lease.renewAfterMilliseconds, 5000)
        let complete = [
            CameraTalkbackLease.idHeader: id.uuidString,
            CameraTalkbackLease.expiresHeader: "1015",
            CameraTalkbackLease.renewHeader: "5000",
        ]
        for header in CameraTalkbackLease.headerNames {
            var missing = complete
            missing.removeValue(forKey: header)
            XCTAssertThrowsError(try CameraTalkbackLease(headers: missing, now: 1000))
        }
    }

    func testTalkbackLeaseRejectsMalformedAmbiguousExpiredOrUnboundedHeaders() {
        let valid = [
            CameraTalkbackLease.idHeader: UUID().uuidString,
            CameraTalkbackLease.expiresHeader: "1015",
            CameraTalkbackLease.renewHeader: "5000",
        ]
        for (header, value) in [
            (CameraTalkbackLease.idHeader, "../another-peer"),
            (CameraTalkbackLease.expiresHeader, "NaN"),
            (CameraTalkbackLease.expiresHeader, "Infinity"),
            (CameraTalkbackLease.expiresHeader, "1000"),
            (CameraTalkbackLease.expiresHeader, "999"),
            (CameraTalkbackLease.expiresHeader, "1030"),
            (CameraTalkbackLease.expiresHeader, "1015000"),
            (CameraTalkbackLease.renewHeader, "0"),
            (CameraTalkbackLease.renewHeader, "15000"),
        ] {
            var invalid = valid
            invalid[header] = value
            XCTAssertThrowsError(try CameraTalkbackLease(headers: invalid, now: 1000))
        }
        var duplicate = valid
        duplicate[CameraTalkbackLease.idHeader.lowercased()] = valid[CameraTalkbackLease.idHeader]
        XCTAssertNil(CameraTalkbackLease.id(in: duplicate))
        XCTAssertThrowsError(try CameraTalkbackLease(headers: duplicate, now: 1000))
    }

    func testTalkbackRenewalHasExactNativeSchemaAndCannotChangeTheLease() throws {
        let id = UUID()
        let value: [String: Any] = [
            "lease_id": id.uuidString, "expires_at": 1015, "renew_after_ms": 5000,
        ]
        let renewal = try JSONDecoder().decode(CameraTalkbackLeaseRenewal.self,
            from: JSONSerialization.data(withJSONObject: value))
        XCTAssertEqual(renewal.leaseID, id)
        XCTAssertEqual(renewal.expiresAt, 1015)
        XCTAssertNoThrow(try CameraTalkbackLease(renewal: renewal, expectedID: id, now: 1000))
        XCTAssertThrowsError(try CameraTalkbackLease(renewal: renewal, expectedID: UUID(), now: 1000))
        for key in ["lease_id", "expires_at", "renew_after_ms"] {
            var missing = value
            missing.removeValue(forKey: key)
            XCTAssertThrowsError(try JSONDecoder().decode(CameraTalkbackLeaseRenewal.self,
                from: JSONSerialization.data(withJSONObject: missing)))
        }
        var wrongInterval = value
        wrongInterval["renew_after_ms"] = 10000
        let invalid = try JSONDecoder().decode(CameraTalkbackLeaseRenewal.self,
            from: JSONSerialization.data(withJSONObject: wrongInterval))
        XCTAssertThrowsError(try CameraTalkbackLease(renewal: invalid, expectedID: id, now: 1000))
    }

    func testTalkbackLeaseRoutesAreScopedAndRenewalBodyIsEmptyJSON() throws {
        let id = UUID()
        let base = ["native", "cameras", "front", "talkback"]
        XCTAssertEqual(try CameraControlRoute.talkback(cameraID: "front"), base)
        XCTAssertEqual(try CameraControlRoute.talkback(cameraID: "front", leaseID: id),
            base + [id.uuidString.lowercased()])
        XCTAssertEqual(try CameraControlRoute.ptz(cameraID: "front"),
            ["native", "cameras", "front", "ptz"])
        XCTAssertThrowsError(try CameraControlRoute.talkback(cameraID: "../other", leaseID: id))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(CameraTalkbackEmptyBody())) as? [String: Any])
        XCTAssertTrue(value.isEmpty)
    }
}
