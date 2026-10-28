import SwiftUI
import UIKit
import UserNotifications
import CryptoKit
import HorizonCore

@MainActor
final class NativePushController: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NativePushController()
    @Published private(set) var capabilities: NativePushCapabilities?
    @Published private(set) var wantsPush = UserDefaults.standard.bool(forKey: "nativePushWanted")
    @Published private(set) var cleanupPending = UserDefaults.standard.bool(forKey: "nativePushCleanupPending")
    @Published private(set) var registered = false
    @Published private(set) var busy = false
    @Published private(set) var permission: UNAuthorizationStatus = .notDetermined
    @Published var error: String?
    @Published var route: NativeNotificationRoute?
    @Published private(set) var status = "Native push has not been configured."
    private var api: HorizonAPI?
    private var accountFingerprint: String?
    private var deviceToken: String?
    private var requestTask: Task<Void, Never>?
    private var disablingTask: Task<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var generation = UUID()
    private var registrationRequest = UUID()
    private var queuedRoute: NativeNotificationRoute?
    private var navigationBlocks: Set<UUID> = []

    var supportedBuild: Bool {
        Bundle.main.object(forInfoDictionaryKey: "HorizonNativePushEnabled") as? String == "YES"
    }

    func refreshAuthorization() async {
        permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func attach(api: HorizonAPI?, username: String?) async {
        let token = UUID()
        generation = token
        self.api = api
        capabilities = nil
        registered = false
        guard let api, let username else { accountFingerprint = nil; route = nil; return }
        accountFingerprint = SHA256.hash(data: Data(
            (api.address.url.absoluteString + "\0" + username).utf8
        )).map { String(format: "%02x", $0) }.joined()
        permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard generation == token else { return }
        guard supportedBuild else {
            status = "Native push is disabled in this build. A push-enabled App ID, profile, and build are required."
            return
        }
        do {
            let result: NativePushCapabilities = try await api.get(["notifications", "apns"])
            guard !Task.isCancelled, generation == token else { return }
            guard !result.enabled || (result.topic == Bundle.main.bundleIdentifier && result.serverID != nil) else {
                throw HorizonError.message("The server APNs topic does not match this app's bundle ID.")
            }
            capabilities = result
            guard result.enabled else { status = "The server's APNs provider is disabled."; return }
            status = "Native push is available. Enable it to request permission."
            publishQueuedRoute()
            if wantsPush && bindingMatches {
                await enable(cameraIDs: savedCameraIDs, requestPermission: false)
            } else if wantsPush {
                stopLocalDelivery()
                setWanted(false)
                status = "This is a different account/server. Enable notifications to register this installation here."
            }
        } catch {
            if !Task.isCancelled && generation == token { self.error = error.localizedDescription }
        }
    }

    var savedCameraIDs: [String]? {
        if UserDefaults.standard.bool(forKey: "nativePushSelectedCameras") {
            return UserDefaults.standard.stringArray(forKey: "nativePushCameraIDs") ?? []
        }
        return nil
    }

    private var bindingMatches: Bool {
        accountFingerprint != nil
            && accountFingerprint == UserDefaults.standard.string(forKey: "nativePushAccount")
    }

    private func installationID() throws -> String {
        if let stored = UserDefaults.standard.string(forKey: "nativePushInstallationID") {
            guard let value = UUID(uuidString: stored) else {
                throw HorizonError.message("The saved notification installation ID is invalid.")
            }
            return value.uuidString.lowercased()
        }
        let value = UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: "nativePushInstallationID")
        return value
    }

    func enable(cameraIDs: [String]?, requestPermission: Bool = true) async {
        guard !busy else { return }
        guard supportedBuild, capabilities?.enabled == true, api != nil else {
            error = "A push-enabled build and configured server are required."
            return
        }
        guard !cleanupPending || bindingMatches
                || UserDefaults.standard.string(forKey: "nativePushAccount") == nil else {
            error = "Sign back into the previous account/server and finish notification cleanup before enabling notifications here."
            return
        }
        busy = true; error = nil
        let session = generation
        do {
            _ = try installationID()
            let center = UNUserNotificationCenter.current()
            let granted: Bool
            if requestPermission {
                granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } else {
                let existing = await center.notificationSettings().authorizationStatus
                granted = [.authorized, .provisional, .ephemeral].contains(existing)
            }
            permission = await center.notificationSettings().authorizationStatus
            guard generation == session else { busy = false; return }
            guard granted else {
                throw HorizonError.message("Notifications were not allowed. Enable them in iOS Settings.")
            }
            UserDefaults.standard.set(cameraIDs != nil, forKey: "nativePushSelectedCameras")
            UserDefaults.standard.set(cameraIDs ?? [], forKey: "nativePushCameraIDs")
            setWanted(true)
            status = "Registering this device with Apple..."
            let token = generation
            timeoutTask?.cancel()
            timeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(25)) } catch { return }
                guard let self, self.generation == token, self.busy, self.deviceToken == nil else { return }
                self.busy = false
                self.error = "Apple device registration timed out. Check connectivity and the app's push entitlement."
            }
            if let deviceToken { scheduleRegistration(deviceToken) }
            else { UIApplication.shared.registerForRemoteNotifications() }
        } catch {
            busy = false
            self.error = error.localizedDescription
        }
    }

    func receivedToken(_ data: Data) {
        guard wantsPush else { return }
        let token = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = token
        timeoutTask?.cancel()
        scheduleRegistration(token)
    }

    func registrationFailed(_ error: Error) {
        timeoutTask?.cancel()
        busy = false
        self.error = "Apple registration failed: \(error.localizedDescription)"
    }

    private func scheduleRegistration(_ token: String) {
        timeoutTask?.cancel()
        let previous = requestTask
        let requestID = UUID()
        registrationRequest = requestID
        let session = generation
        busy = true
        requestTask = Task {
            await previous?.value
            defer { if registrationRequest == requestID { busy = false } }
            guard generation == session, wantsPush, let api, let capabilities,
                  let fingerprint = accountFingerprint else { return }
            do {
                let environment: String
                switch Bundle.main.object(forInfoDictionaryKey: "HorizonAPNsEnvironment") as? String {
                case "development": environment = "sandbox"
                case "production": environment = "production"
                default: throw HorizonError.message("The app's APNs environment build setting is invalid.")
                }
                let body = try NativePushRegistrationBody(installationID: installationID(),
                    token: token, environment: environment, cameraIDs: savedCameraIDs)
                UserDefaults.standard.set(fingerprint, forKey: "nativePushAccount")
                UserDefaults.standard.set(capabilities.serverID, forKey: "nativePushServerID")
                let result: NativePushRegistrationResult = try await api.send(
                    ["notifications", "apns", "register"], body: body
                )
                guard result.success, result.serverID == capabilities.serverID else {
                    throw HorizonError.message("The server did not confirm this notification registration.")
                }
                guard generation == session, registrationRequest == requestID, wantsPush else { return }
                registered = true
                status = result.message
                cleanupPending = false
                UserDefaults.standard.set(false, forKey: "nativePushCleanupPending")
                UserDefaults.standard.set(fingerprint, forKey: "nativePushAccount")
                UserDefaults.standard.set(result.serverID, forKey: "nativePushServerID")
                publishQueuedRoute()
            } catch {
                guard generation == session, registrationRequest == requestID else { return }
                cleanupPending = true
                UserDefaults.standard.set(true, forKey: "nativePushCleanupPending")
                self.error = error.localizedDescription
            }
        }
    }

    func disable(using explicitAPI: HorizonAPI? = nil) async -> Bool {
        if let disablingTask { return await disablingTask.value }
        busy = true
        let task = Task { await performDisable(using: explicitAPI) }
        disablingTask = task
        let result = await task.value
        disablingTask = nil
        return result
    }

    private func performDisable(using explicitAPI: HorizonAPI?) async -> Bool {
        let needsCleanup = wantsPush || cleanupPending || registered
        setWanted(false)
        stopLocalDelivery()
        registered = false
        timeoutTask?.cancel()
        await requestTask?.value
        guard needsCleanup else { busy = false; return true }
        guard bindingMatches || UserDefaults.standard.string(forKey: "nativePushAccount") == nil,
              let api = explicitAPI ?? api else {
            error = "Server cleanup requires the account that registered this installation."
            cleanupPending = true
            UserDefaults.standard.set(true, forKey: "nativePushCleanupPending")
            busy = false
            return false
        }
        busy = true
        defer { busy = false }
        do {
            try await api.action(["notifications", "apns", "register", try installationID()],
                method: "DELETE", body: [String: String]())
            cleanupPending = false
            UserDefaults.standard.set(false, forKey: "nativePushCleanupPending")
            UserDefaults.standard.removeObject(forKey: "nativePushAccount")
            UserDefaults.standard.removeObject(forKey: "nativePushServerID")
            error = nil
            status = "Native notifications are disabled and the server registration was removed."
            return true
        } catch {
            cleanupPending = true
            UserDefaults.standard.set(true, forKey: "nativePushCleanupPending")
            self.error = "Notifications are off locally, but server cleanup failed: \(error.localizedDescription)"
            return false
        }
    }

    func stopLocalDelivery() {
        UIApplication.shared.unregisterForRemoteNotifications()
        deviceToken = nil
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    func abandonForLogout() {
        if wantsPush || registered {
            cleanupPending = true
            UserDefaults.standard.set(true, forKey: "nativePushCleanupPending")
        }
        setWanted(false)
        stopLocalDelivery()
        registered = false
        deviceToken = nil
        route = nil; queuedRoute = nil
    }

    func sendTest() async {
        guard registered, let api else { error = "Register this installation first."; return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let result: APIActionResult = try await api.send(["notifications", "apns", "test"],
                body: ["installation_id": try installationID()])
            try result.requireSuccess()
            status = result.message ?? "Apple accepted the test request. Display is best-effort."
        } catch { self.error = error.localizedDescription }
    }

    private func setWanted(_ value: Bool) {
        wantsPush = value
        UserDefaults.standard.set(value, forKey: "nativePushWanted")
    }

    func blockNavigation(_ id: UUID) { navigationBlocks.insert(id) }
    func unblockNavigation(_ id: UUID) { navigationBlocks.remove(id); publishQueuedRoute() }

    private func publishQueuedRoute() {
        guard navigationBlocks.isEmpty, let queuedRoute, api != nil,
              capabilities?.serverID == queuedRoute.serverID else { return }
        route = queuedRoute
        self.queuedRoute = nil
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let candidate = NativeNotificationRoute(userInfo: response.notification.request.content.userInfo)
        Task { @MainActor in
            guard let candidate else {
                self.error = "This notification could not be opened because its routing data is invalid."
                return
            }
            self.queuedRoute = candidate
            self.publishQueuedRoute()
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let candidate = NativeNotificationRoute(userInfo: notification.request.content.userInfo)
        Task { @MainActor in
            let allowed = self.wantsPush && self.api != nil && candidate?.serverID == self.capabilities?.serverID
            completionHandler(allowed && candidate != nil ? [.banner, .list, .sound] : [])
        }
    }
}

@MainActor
final class HorizonApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = NativePushController.shared
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NativePushController.shared.receivedToken(deviceToken)
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NativePushController.shared.registrationFailed(error)
    }
}

struct DeferNotificationNavigation: ViewModifier {
    @EnvironmentObject private var push: NativePushController
    @State private var id = UUID()
    func body(content: Content) -> some View {
        content.onAppear { push.blockNavigation(id) }.onDisappear { push.unblockNavigation(id) }
    }
}
