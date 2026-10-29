import SwiftUI
import HorizonCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var api: HorizonAPI?
    @Published private(set) var configuration: HorizonConfiguration?
    @Published private(set) var profile: UserProfile?
    @Published private(set) var isConnecting = false
    @Published var error: String?
    @Published var serverText = ""
    @Published private(set) var pendingExportIDs: [String] = []

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
        do {
            guard let saved = try SessionVault.read() else { return }
            serverText = saved.server
            let address = try ServerAddress(saved.server)
            let client = HorizonAPI(
                address: address, cookies: saved.cookies.compactMap { $0.restore(for: address) }
            )
            isConnecting = true
            defer { isConnecting = false }
            do {
                try await activate(client)
            } catch {
                client.close()
                throw error
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func connect(username: String, password: String, authenticate: Bool) async {
        guard !isConnecting else { return }
        isConnecting = true
        error = nil
        defer { isConnecting = false }
        var candidate: HorizonAPI?
        do {
            let client = HorizonAPI(address: try ServerAddress(serverText))
            candidate = client
            if authenticate { try await client.login(user: username, password: password) }
            try await activate(client)
        } catch {
            candidate?.close()
            self.error = error.localizedDescription
        }
    }

    func refresh() async {
        guard let api else { return }
        do {
            try await activate(api)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func disconnect(skippingPushCleanup: Bool = false) async -> Bool {
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
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func activate(_ client: HorizonAPI) async throws {
        async let config: HorizonConfiguration = client.get(["config"])
        async let profile: UserProfile = client.get(["profile"])
        let (newConfig, newProfile) = try await (config, profile)
        if api?.address != client.address || self.profile?.username != newProfile.username {
            try NativePushController.shared.prepareForAccountChange(api: client, username: newProfile.username)
        }
        try SessionVault.save(client)
        configuration = newConfig
        self.profile = newProfile
        api = client
        serverText = client.address.url.absoluteString
        NativePushController.shared.refreshImageSession(api: client, username: newProfile.username,
            allowedCameraIDs: newProfile.allowedCameras)
    }
}
