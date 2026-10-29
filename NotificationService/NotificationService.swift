import Foundation
import HorizonCore
import UniformTypeIdentifiers
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private let lifetimeLock = NSLock()
    private var active: NotificationRequestContext?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let context = NotificationRequestContext(original: request.content, handler: contentHandler)
        lifetimeLock.lock()
        let previous = active
        active = context
        lifetimeLock.unlock()
        previous?.fallback(.cancelled)
        NotificationRequestContext.removeExpiredFiles()
        context.start(route: NativeNotificationRoute(userInfo: request.content.userInfo))
    }

    override func serviceExtensionTimeWillExpire() {
        lifetimeLock.lock()
        let context = active
        lifetimeLock.unlock()
        context?.fallback(.deadline)
    }
}

// Framework completion ownership crosses the expiry callback, a timer, and a Swift task.
// The lock owns every mutable field and transfers the handler to exactly one finishing caller.
private final class NotificationRequestContext: @unchecked Sendable {
    private let lock = NSLock()
    private let original: UNNotificationContent
    private let expiresAt = ProcessInfo.processInfo.systemUptime + 15
    private var handler: ((UNNotificationContent) -> Void)?
    private var work: Task<Void, Never>?
    private var deadline: DispatchWorkItem?

    init(original: UNNotificationContent, handler: @escaping (UNNotificationContent) -> Void) {
        self.original = original
        self.handler = handler
    }

    func start(route: NativeNotificationRoute?) {
        guard let route else { fallback(.invalidPayload); return }
        guard route.kind != .test else { fallback(.unsupportedKind); return }
        let expiry = DispatchWorkItem { [weak self] in self?.fallback(.deadline) }
        lock.lock()
        guard handler != nil else { lock.unlock(); return }
        deadline = expiry
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: expiry)

        let task = Task { [self] in
            do {
                let saved: NotificationImageSession?
                do { saved = try NotificationImageVault.read() }
                catch { throw NotificationThumbnailFailure.sessionUnavailable }
                guard let saved else { throw NotificationThumbnailFailure.missingSession }
                let jpeg = try await NotificationThumbnailLoader().load(
                    route: route, session: saved, currentSession: { try NotificationImageVault.read() }
                )
                try Task.checkCancellation()
                try deliver(jpeg, expected: saved)
            } catch let failure as NotificationThumbnailFailure {
                fallback(failure)
            } catch is CancellationError {
                fallback(.cancelled)
            } catch {
                fallback(.unexpected)
            }
        }
        lock.lock()
        let finished = handler == nil
        if !finished { work = task }
        lock.unlock()
        if finished { task.cancel() }
    }

    func fallback(_ reason: NotificationThumbnailFailure) {
        finish(attachment: nil, expected: nil, reason: reason)
    }

    private func deliver(_ jpeg: Data, expected: NotificationImageSession) throws {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw NotificationThumbnailFailure.attachment
        }
        // The extension's own sandbox is used, never a shared app-group or public media directory.
        let directory = caches.appendingPathComponent("NotificationAttachments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        var delivered = false
        defer { if !delivered { cleanup(directory) } }
        let attachment: UNNotificationAttachment
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("preview.jpg", isDirectory: false)
            try jpeg.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            attachment = try UNNotificationAttachment(
                identifier: "preview", url: file,
                options: [UNNotificationAttachmentOptionsTypeHintKey: UTType.jpeg.identifier]
            )
        } catch {
            throw NotificationThumbnailFailure.attachment
        }
        // Apple validates and moves remote attachments after the extension finishes.
        // Keep successful files available for that handoff, rather than deleting them here.
        delivered = finish(attachment: attachment, expected: expected, reason: nil)
    }

    @discardableResult
    private func finish(
        attachment: UNNotificationAttachment?, expected: NotificationImageSession?,
        reason initialReason: NotificationThumbnailFailure?
    ) -> Bool {
        var content = original
        var reason = initialReason
        var imageDelivered = false
        if let attachment, let expected {
            do {
                // Keychain IPC must not hold the handler lock and block the expiry fallback.
                let current = try NotificationImageVault.read()
                if ProcessInfo.processInfo.systemUptime >= expiresAt {
                    reason = .deadline
                } else if NotificationThumbnailLoader.isCurrent(expected, current) {
                    if let copy = original.mutableCopy() as? UNMutableNotificationContent {
                        copy.attachments = [attachment]
                        content = copy
                        imageDelivered = true
                    } else {
                        reason = .attachment
                    }
                } else {
                    reason = .sessionChanged
                }
            } catch {
                reason = .sessionUnavailable
            }
        }
        lock.lock()
        guard let completion = handler else { lock.unlock(); return false }
        if imageDelivered, ProcessInfo.processInfo.systemUptime >= expiresAt {
            content = original
            imageDelivered = false
            reason = .deadline
        }
        handler = nil
        let running = work
        let expiry = deadline
        work = nil
        deadline = nil
        lock.unlock()
        expiry?.cancel()
        running?.cancel()
        if let reason { Self.log(reason) }
        completion(content)
        return imageDelivered
    }

    private func cleanup(_ directory: URL) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do { try FileManager.default.removeItem(at: directory) }
        catch { Self.log(.fileCleanup) }
    }

    private static func log(_ reason: NotificationThumbnailFailure) {
        NSLog("Horizon notification image fallback=%@", reason.rawValue)
    }

    static func removeExpiredFiles() {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let root = caches.appendingPathComponent("NotificationAttachments", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey])
            for file in files where UUID(uuidString: file.lastPathComponent) != nil {
                let values = try file.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory == true, values.isSymbolicLink != true,
                   let created = values.creationDate, created < Date().addingTimeInterval(-3600) {
                    try FileManager.default.removeItem(at: file)
                }
            }
        } catch { log(.fileCleanup) }
    }
}
