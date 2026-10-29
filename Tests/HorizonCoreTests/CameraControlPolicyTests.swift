import XCTest
@testable import HorizonCore

final class CameraControlPolicyTests: XCTestCase {
    private func talkbackLease(_ id: UUID, expires: Double, wallNow: Double) throws -> CameraTalkbackLease {
        try CameraTalkbackLease(headers: [
            CameraTalkbackLease.idHeader: id.uuidString,
            CameraTalkbackLease.expiresHeader: String(expires),
            CameraTalkbackLease.renewHeader: "5000",
        ], now: wallNow)
    }

    private func renewal(_ id: UUID, expires: Double) throws -> CameraTalkbackLeaseRenewal {
        try JSONDecoder().decode(CameraTalkbackLeaseRenewal.self,
            from: JSONSerialization.data(withJSONObject: [
                "lease_id": id.uuidString, "expires_at": expires, "renew_after_ms": 5000,
            ]))
    }

    func testRenewalCadenceIsShorterThanBothServerTTLAndClientDeadline() {
        XCTAssertLessThanOrEqual(CameraPTZLease.renewalInterval, 0.25)
        XCTAssertLessThan(CameraPTZLease.acknowledgementDeadline,
            Double(CameraPTZRequest.leaseDurationMilliseconds) / 1000)
    }

    func testUnacknowledgedHoldExpiresBeforeTheServerDeadman() {
        var state = CameraPTZLease()
        let lease = state.begin(now: 0)
        XCTAssertTrue(state.canRenew(lease, now: 0.2))
        XCTAssertTrue(state.canRenew(lease, now: 0.4))
        XCTAssertFalse(state.canRenew(lease, now: 0.45))
        XCTAssertFalse(state.acknowledge(lease, now: 0.5))
    }

    func testAcknowledgementsRenewOnlyTheCurrentLiveHold() {
        var state = CameraPTZLease()
        let lease = state.begin(now: 10)
        XCTAssertTrue(state.acknowledge(lease, now: 10.2))
        XCTAssertTrue(state.canRenew(lease, now: 10.6))
        XCTAssertFalse(state.canRenew(lease, now: 10.7))
        XCTAssertFalse(state.acknowledge(UUID(), now: 10.3))
    }

    func testReleaseAndLateNetworkResponseCannotRestartMotion() {
        var state = CameraPTZLease()
        let old = state.begin(now: 1)
        XCTAssertEqual(state.end(), old)
        XCTAssertNil(state.end())
        XCTAssertFalse(state.acknowledge(old, now: 1.1))
        let new = state.begin(now: 1.2)
        XCTAssertNotEqual(old, new)
        XCTAssertFalse(state.acknowledge(old, now: 1.3))
        XCTAssertTrue(state.canRenew(new, now: 1.3))
    }

    func testInvalidOrBackwardMonotonicTimeFailsClosed() {
        var state = CameraPTZLease()
        let lease = state.begin(now: 1)
        for now in [0, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertFalse(state.canRenew(lease, now: now))
            XCTAssertFalse(state.acknowledge(lease, now: now))
        }
    }

    func testPermissionAndConnectionRequireTheSameExplicitHeldGeneration() {
        var state = CameraPushToTalkState()
        let hold = state.begin()
        XCTAssertEqual(state.phase, .awaitingPermission)
        XCTAssertFalse(state.connected(hold))
        XCTAssertTrue(state.permissionGranted(hold))
        XCTAssertEqual(state.phase, .negotiating)
        XCTAssertTrue(state.connected(hold))
        XCTAssertEqual(state.phase, .transmitting)
        XCTAssertFalse(state.connected(hold))
        state.end()
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.generation)
    }

    func testDelayedPermissionAfterReleaseCannotAcquireCapture() {
        var state = CameraPushToTalkState()
        let hold = state.begin()
        state.end()
        XCTAssertFalse(state.permissionGranted(hold))
        XCTAssertFalse(state.connected(hold))
        XCTAssertEqual(state.phase, .idle)
    }

    func testDelayedSDPAfterCancellationCannotTransmitOrHijackANewHold() {
        var state = CameraPushToTalkState()
        let old = state.begin()
        XCTAssertTrue(state.permissionGranted(old))
        state.end()
        let new = state.begin()
        XCTAssertFalse(state.connected(old))
        XCTAssertFalse(state.permissionGranted(old))
        XCTAssertTrue(state.permissionGranted(new))
        XCTAssertTrue(state.connected(new))
    }

    func testThirtySecondHoldLimitStopsOwnershipAndRejectsLatePermissionAndSDP() {
        XCTAssertEqual(CameraPushToTalkState.maximumHoldDuration, 30)
        var state = CameraPushToTalkState()
        let hold = state.begin(now: 100)
        XCTAssertTrue(state.permissionGranted(hold, now: 101))
        XCTAssertTrue(state.connected(hold, now: 102))
        XCTAssertTrue(state.owns(hold, now: 129.999))
        XCTAssertFalse(state.hasExpired(now: 129.999))
        XCTAssertTrue(state.hasExpired(now: 130))
        XCTAssertFalse(state.owns(hold, now: 130))
        state.end()
        XCTAssertFalse(state.owns(hold, now: 130.1))

        let delayedPermission = state.begin(now: 200)
        XCTAssertFalse(state.permissionGranted(delayedPermission, now: 230))
        state.end()
        let delayedAnswer = state.begin(now: 300)
        XCTAssertTrue(state.permissionGranted(delayedAnswer, now: 301))
        XCTAssertFalse(state.connected(delayedAnswer, now: 330))
        state.end()
        let replacement = state.begin(now: 331)
        XCTAssertFalse(state.connected(delayedAnswer, now: 332))
        XCTAssertTrue(state.permissionGranted(replacement, now: 332))
    }

    func testOnlyOneCameraCanOwnTheMicrophone() {
        var microphone = CameraMicrophoneOwnership()
        let first = UUID()
        let second = UUID()
        XCTAssertTrue(microphone.acquire(first))
        XCTAssertTrue(microphone.acquire(first))
        XCTAssertFalse(microphone.acquire(second))
        XCTAssertFalse(microphone.release(second))
        XCTAssertEqual(microphone.owner, first)
        XCTAssertTrue(microphone.release(first))
        XCTAssertTrue(microphone.acquire(second))
        XCTAssertFalse(microphone.release(first))
        XCTAssertEqual(microphone.owner, second)
    }

    func testMicrophoneLeaseCannotBeUsedBeforeHeadersOrAfterTheFifteenSecondTTL() throws {
        let generation = UUID()
        let id = UUID()
        var state = CameraTalkbackLeaseState()
        state.begin(generation: generation, now: 100)
        XCTAssertFalse(state.canUse(generation, now: 100))
        let lease = try talkbackLease(id, expires: 1015, wallNow: 1000)
        XCTAssertTrue(try state.acceptInitial(lease, generation: generation, now: 100, wallNow: 1000))
        XCTAssertTrue(state.canUse(generation, now: 114.999))
        XCTAssertFalse(state.canUse(generation, now: 115))
        XCTAssertFalse(state.needsRenewal(generation, now: 104.999))
        XCTAssertTrue(state.needsRenewal(generation, now: 105))
        XCTAssertFalse(state.canUse(generation, now: .nan))
        XCTAssertFalse(state.canUse(generation, now: 99))
    }

    func testFiveSecondRenewalExtendsOnlyTheCurrentHeldLease() throws {
        let generation = UUID()
        let id = UUID()
        var state = CameraTalkbackLeaseState()
        state.begin(generation: generation, now: 100)
        XCTAssertTrue(try state.acceptInitial(talkbackLease(id, expires: 1015, wallNow: 1000),
            generation: generation, now: 100, wallNow: 1000))
        XCTAssertTrue(try state.acceptRenewal(renewal(id, expires: 1020),
            generation: generation, now: 105, wallNow: 1005))
        XCTAssertFalse(state.needsRenewal(generation, now: 109.999))
        XCTAssertTrue(state.needsRenewal(generation, now: 110))
        XCTAssertTrue(state.canUse(generation, now: 119.999))
        XCTAssertFalse(state.canUse(generation, now: 120))
    }

    func testReleasedGenerationRejectsLateOfferAndRenewalWithoutChangingTheNewLease() throws {
        var state = CameraTalkbackLeaseState()
        let old = UUID()
        let oldID = UUID()
        state.begin(generation: old, now: 0)
        XCTAssertTrue(try state.acceptInitial(talkbackLease(oldID, expires: 1015, wallNow: 1000),
            generation: old, now: 0, wallNow: 1000))
        state.end()
        XCTAssertFalse(try state.acceptRenewal(renewal(oldID, expires: 1020),
            generation: old, now: 5, wallNow: 1005))
        let current = UUID()
        let currentID = UUID()
        state.begin(generation: current, now: 6)
        XCTAssertFalse(try state.acceptInitial(talkbackLease(oldID, expires: 1021, wallNow: 1006),
            generation: old, now: 6, wallNow: 1006))
        XCTAssertNil(state.lease)
        XCTAssertTrue(try state.acceptInitial(talkbackLease(currentID, expires: 1021, wallNow: 1006),
            generation: current, now: 6, wallNow: 1006))
        XCTAssertFalse(try state.acceptRenewal(renewal(oldID, expires: 1022),
            generation: old, now: 7, wallNow: 1007))
        XCTAssertEqual(state.lease?.id, currentID)
        XCTAssertTrue(state.canUse(current, now: 7))
    }

    func testExpiredLeaseCannotBeRevivedByAnOtherwiseValidRenewal() throws {
        var state = CameraTalkbackLeaseState()
        let generation = UUID()
        let id = UUID()
        state.begin(generation: generation, now: 0)
        XCTAssertTrue(try state.acceptInitial(talkbackLease(id, expires: 1015, wallNow: 1000),
            generation: generation, now: 0, wallNow: 1000))
        XCTAssertFalse(try state.acceptRenewal(renewal(id, expires: 1030),
            generation: generation, now: 15, wallNow: 1015))
        XCTAssertFalse(state.canUse(generation, now: 15))
    }

    func testWrongOrStaleRenewalsFailWithoutReplacingTheCurrentLease() throws {
        var state = CameraTalkbackLeaseState()
        let generation = UUID()
        let id = UUID()
        state.begin(generation: generation, now: 0)
        let initial = try talkbackLease(id, expires: 1015, wallNow: 1000)
        XCTAssertTrue(try state.acceptInitial(initial, generation: generation, now: 0, wallNow: 1000))
        XCTAssertThrowsError(try state.acceptRenewal(renewal(UUID(), expires: 1020),
            generation: generation, now: 5, wallNow: 1005))
        XCTAssertThrowsError(try state.acceptRenewal(renewal(id, expires: 1014),
            generation: generation, now: 5, wallNow: 1005))
        XCTAssertEqual(state.lease, initial)
    }

    func testHeaderExpiryIsRevalidatedWhenTheOfferIsAccepted() throws {
        var state = CameraTalkbackLeaseState()
        let generation = UUID()
        state.begin(generation: generation, now: 0)
        let delayed = try talkbackLease(UUID(), expires: 1015, wallNow: 1000)
        XCTAssertThrowsError(try state.acceptInitial(delayed, generation: generation, now: 15, wallNow: 1015))
        XCTAssertNil(state.lease)
    }

    func testServerHardMaximumIsOneHundredTwentySecondsDespiteSuccessfulRenewals() throws {
        XCTAssertEqual(CameraTalkbackLease.maximumServerLifetime, 120)
        var state = CameraTalkbackLeaseState()
        let generation = UUID()
        let id = UUID()
        state.begin(generation: generation, now: 0)
        XCTAssertTrue(try state.acceptInitial(talkbackLease(id, expires: 1015, wallNow: 1000),
            generation: generation, now: 0, wallNow: 1000))
        for second in stride(from: 5, through: 115, by: 5) {
            XCTAssertTrue(try state.acceptRenewal(renewal(id, expires: min(1120, 1015 + Double(second))),
                generation: generation, now: Double(second), wallNow: 1000 + Double(second)))
        }
        XCTAssertTrue(state.canUse(generation, now: 119.999))
        XCTAssertFalse(state.canUse(generation, now: 120))
        XCTAssertFalse(try state.acceptRenewal(renewal(id, expires: 1135),
            generation: generation, now: 120, wallNow: 1120))
        XCTAssertEqual(CameraPushToTalkState.maximumHoldDuration, 30)
    }
}
