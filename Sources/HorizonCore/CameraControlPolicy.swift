import Foundation

/// Uses monotonic seconds supplied by the caller, never wall-clock time.
public struct CameraPTZLease: Sendable {
    public static let renewalInterval: TimeInterval = 0.2
    public static let acknowledgementDeadline: TimeInterval = 0.45
    public private(set) var id: UUID?
    private var lastAcknowledgement: TimeInterval = 0

    public init() {}

    public mutating func begin(now: TimeInterval) -> UUID {
        let token = UUID()
        id = token
        lastAcknowledgement = now
        return token
    }

    public func canRenew(_ token: UUID, now: TimeInterval) -> Bool {
        id == token && now.isFinite && now >= lastAcknowledgement &&
            now - lastAcknowledgement < Self.acknowledgementDeadline
    }

    @discardableResult
    public mutating func acknowledge(_ token: UUID, now: TimeInterval) -> Bool {
        guard canRenew(token, now: now) else { return false }
        lastAcknowledgement = now
        return true
    }

    @discardableResult
    public mutating func end() -> UUID? {
        let previous = id
        id = nil
        return previous
    }
}

public struct CameraPushToTalkState: Sendable {
    public static let maximumHoldDuration: TimeInterval = 30
    public enum Phase: Equatable, Sendable { case idle, awaitingPermission, negotiating, transmitting }
    public private(set) var generation: UUID?
    public private(set) var phase: Phase = .idle
    private var beganAt: TimeInterval?

    public init() {}

    public mutating func begin(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> UUID {
        let token = UUID()
        generation = token
        phase = .awaitingPermission
        beganAt = now
        return token
    }

    public func hasExpired(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard generation != nil, let beganAt else { return false }
        return !now.isFinite || !beganAt.isFinite || now < beganAt || now - beganAt >= Self.maximumHoldDuration
    }

    public func owns(_ token: UUID, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        generation == token && phase != .idle && !hasExpired(now: now)
    }

    @discardableResult
    public mutating func permissionGranted(
        _ token: UUID, now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        guard owns(token, now: now), phase == .awaitingPermission else { return false }
        phase = .negotiating
        return true
    }

    @discardableResult
    public mutating func connected(
        _ token: UUID, now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        guard owns(token, now: now), phase == .negotiating else { return false }
        phase = .transmitting
        return true
    }

    public mutating func end() {
        generation = nil
        phase = .idle
        beganAt = nil
    }
}

public struct CameraMicrophoneOwnership: Sendable {
    public private(set) var owner: UUID?
    public init() {}

    public mutating func acquire(_ token: UUID) -> Bool {
        guard owner == nil || owner == token else { return false }
        owner = token
        return true
    }

    @discardableResult
    public mutating func release(_ token: UUID) -> Bool {
        guard owner == token else { return false }
        owner = nil
        return true
    }
}

public struct CameraTalkbackLeaseState: Sendable {
    public private(set) var generation: UUID?
    public private(set) var lease: CameraTalkbackLease?
    private var beganAt: TimeInterval?
    private var acceptedAt: TimeInterval?
    private var expiresAt: TimeInterval?
    private var renewAt: TimeInterval?

    public init() {}

    public mutating func begin(generation: UUID, now: TimeInterval) {
        end()
        self.generation = generation
        beganAt = now
    }

    @discardableResult
    public mutating func acceptInitial(
        _ lease: CameraTalkbackLease, generation: UUID, now: TimeInterval, wallNow: TimeInterval
    ) throws -> Bool {
        guard self.generation == generation, self.lease == nil, withinHardDeadline(now) else { return false }
        try lease.validate(now: wallNow)
        install(lease, now: now, wallNow: wallNow)
        return true
    }

    @discardableResult
    public mutating func acceptRenewal(
        _ response: CameraTalkbackLeaseRenewal, generation: UUID, now: TimeInterval, wallNow: TimeInterval
    ) throws -> Bool {
        guard canUse(generation, now: now), let current = lease else { return false }
        let renewed = try CameraTalkbackLease(renewal: response, expectedID: current.id, now: wallNow)
        guard renewed.expiresAt >= current.expiresAt else {
            throw HorizonError.message("The server returned a stale talkback lease renewal.")
        }
        install(renewed, now: now, wallNow: wallNow)
        return true
    }

    public func canUse(_ generation: UUID, now: TimeInterval) -> Bool {
        guard self.generation == generation, lease != nil, let acceptedAt, let expiresAt else { return false }
        return withinHardDeadline(now) && now >= acceptedAt && now < expiresAt
    }

    public func needsRenewal(_ generation: UUID, now: TimeInterval) -> Bool {
        guard let renewAt else { return false }
        return canUse(generation, now: now) && now >= renewAt
    }

    public mutating func end() {
        generation = nil
        lease = nil
        beganAt = nil
        acceptedAt = nil
        expiresAt = nil
        renewAt = nil
    }

    private func withinHardDeadline(_ now: TimeInterval) -> Bool {
        guard let beganAt else { return false }
        return beganAt.isFinite && now.isFinite && now >= beganAt &&
            now - beganAt < CameraTalkbackLease.maximumServerLifetime
    }

    private mutating func install(_ lease: CameraTalkbackLease, now: TimeInterval, wallNow: TimeInterval) {
        self.lease = lease
        acceptedAt = now
        expiresAt = now + min(CameraTalkbackLease.timeToLive, lease.expiresAt - wallNow)
        renewAt = now + Double(lease.renewAfterMilliseconds) / 1000
    }
}
