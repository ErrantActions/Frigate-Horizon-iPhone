import SwiftUI
import HorizonCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var api: HorizonAPI?
    @Published private(set) var configuration: HorizonConfiguration?
    @Published private(set) var profile: UserProfile?
    @Published private(set) var isConnecting = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var connectionIssue: ConnectionIssue?
    @Published private(set) var lastConnectionCheck: Date?
    @Published private(set) var savedServerAddress: String?
    @Published var error: String?
    @Published var serverText = ""
    @Published private(set) var pendingExportIDs: [String] = []
    private var connectionGeneration = UUID()

    var canRetrySavedConnection: Bool {
        api == nil && savedServerAddress != nil
            && savedServerAddress == (try? ServerAddress(serverText))?.url.absoluteString
            && connectionIssue?.allowsSavedSessionRetry == true
    }

    var cameras: [HorizonCamera] {
        guard let configuration, let profile else { return [] }
        let allowed = Set(profile.allowedCameras)
        return configuration.orderedCameras.filter { allowed.contains($0.id) }
    }

    var iceServers: [ICEServer] { configuration?.go2rtc?.webrtc?.iceServers ?? [] }
    var isAdmin: Bool { profile?.isAdmin == true }
    var semanticSearchEnabled: Bool { configuration?.semanticSearch?.enabled == true }
    var roles: [String] { configuration?.auth?.roles.keys.sorted() ?? [] }

    func trackExport(_ id: String) {
        if !pendingExportIDs.contains(id) { pendingExportIDs.append(id) }
    }

    func finishExport(_ id: String) {
        if pendingExportIDs.contains(id) { pendingExportIDs.removeAll { $0 == id } }
    }

    func restore() async {
        guard !isConnecting, api == nil else { return }
        let generation = beginConnectionAttempt()
        defer { if connectionGeneration == generation { isConnecting = false } }
        do {
            guard let saved = try SessionVault.read() else { return }
            serverText = saved.server
            let address = try ServerAddress(saved.server)
            savedServerAddress = address.url.absoluteString
            let client = HorizonAPI(
                address: address, cookies: saved.cookies.compactMap { $0.restore(for: address) }
            )
            do {
                try await activate(client, generation: generation)
            } catch {
                client.close()
                throw error
            }
        } catch {
            recordConnectionFailure(error, generation: generation)
        }
    }

    func connect(username: String, password: String, authenticate: Bool) async {
        guard !isConnecting else { return }
        let generation = beginConnectionAttempt()
        defer { if connectionGeneration == generation { isConnecting = false } }
        var candidate: HorizonAPI?
        do {
            let client = HorizonAPI(address: try ServerAddress(serverText))
            candidate = client
            if authenticate { try await client.login(user: username, password: password) }
            try await activate(client, generation: generation)
        } catch {
            candidate?.close()
            recordConnectionFailure(error, generation: generation)
        }
    }

    func refresh() async {
        guard let api, !isRefreshing, !isConnecting else { return }
        let generation = connectionGeneration
        isRefreshing = true
        defer { if connectionGeneration == generation { isRefreshing = false } }
        do {
            try await activate(api, generation: generation)
        } catch {
            recordConnectionFailure(error, generation: generation)
        }
    }

    func reauthenticate(password: String) async -> Bool {
        guard !isConnecting, let api, let username = profile?.username else { return false }
        guard !password.isEmpty else {
            error = "Enter your current Frigate password."
            return false
        }

        let generation = beginConnectionAttempt()
        defer { if connectionGeneration == generation { isConnecting = false } }
        let client = HorizonAPI(address: api.address)
        do {
            try await client.login(user: username, password: password)
            try await activate(client, generation: generation, expectedUsername: username)
            return true
        } catch {
            client.close()
            recordConnectionFailure(error, generation: generation)
            return false
        }
    }

    func reportSessionExpiry(from client: HorizonAPI) {
        guard api === client, !isConnecting else { return }
        recordConnectionFailure(HorizonError.unauthorized, generation: connectionGeneration)
    }

    func disconnect(skippingPushCleanup: Bool = false) async -> Bool {
        guard !isConnecting else { return false }
        let generation = beginConnectionAttempt()
        defer { if connectionGeneration == generation { isConnecting = false } }
        let push = NativePushController.shared
        if !skippingPushCleanup, let api {
            guard await push.disable(using: api) else {
                error = push.error ?? "Could not remove the server's push registration. Retry or explicitly disconnect without cleanup."
                return false
            }
        }
        do {
            try push.abandonForLogout()
            try SessionVault.clear()
            api?.close()
            api = nil
            configuration = nil
            profile = nil
            pendingExportIDs = []
            error = nil
            connectionIssue = nil
            lastConnectionCheck = nil
            savedServerAddress = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func beginConnectionAttempt() -> UUID {
        connectionGeneration = UUID()
        isConnecting = true
        isRefreshing = false
        error = nil
        connectionIssue = nil
        return connectionGeneration
    }

    private func recordConnectionFailure(_ failure: Error, generation: UUID) {
        guard generation == connectionGeneration else { return }
        let issue = ConnectionIssue(error: failure)
        guard issue.kind != .cancelled else { return }
        error = failure.localizedDescription
        connectionIssue = issue
    }

    private func activate(_ client: HorizonAPI, generation: UUID,
                          expectedUsername: String? = nil) async throws {
        async let config: HorizonConfiguration = client.get(["config"])
        async let profile: UserProfile = client.get(["profile"])
        let (newConfig, newProfile) = try await (config, profile)
        try Task.checkCancellation()
        guard generation == connectionGeneration else { throw CancellationError() }
        if let expectedUsername, newProfile.username != expectedUsername {
            throw HorizonError.message("The server returned a different account. Disconnect before switching accounts.")
        }
        if api?.address != client.address || self.profile?.username != newProfile.username {
            try NativePushController.shared.prepareForAccountChange(api: client, username: newProfile.username)
        }
        try SessionVault.save(client)
        configuration = newConfig
        self.profile = newProfile
        api = client
        serverText = client.address.url.absoluteString
        savedServerAddress = serverText
        lastConnectionCheck = Date()
        error = nil
        connectionIssue = nil
        NativePushController.shared.refreshImageSession(api: client, username: newProfile.username,
            allowedCameraIDs: newProfile.allowedCameras)
    }
}
