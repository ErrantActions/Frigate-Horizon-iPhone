import Foundation

public enum NativeSettingsSection: String, CaseIterable, Hashable, Sendable {
    case cameras, recording, detection, alerts, viewing, integrations, security, advanced

    public var title: String {
        switch self {
        case .cameras: return "Cameras"
        case .recording: return "Recording and retention"
        case .detection: return "Detection, motion and objects"
        case .alerts: return "Alerts and review"
        case .viewing: return "Live viewing and display"
        case .integrations: return "Integrations"
        case .security: return "Access and security"
        case .advanced: return "Advanced"
        }
    }

    public static func section(for key: String) -> Self {
        switch key {
        case "cameras", "camera_groups": return .cameras
        case "record", "snapshots", "retention", "storage": return .recording
        case "detect", "detectors", "model", "motion", "objects", "audio", "semantic_search": return .detection
        case "notifications", "apns", "review": return .alerts
        case "live", "go2rtc", "ui", "birdseye": return .viewing
        case "mqtt", "onvif", "plugins", "integrations", "telemetry": return .integrations
        case "auth", "tls", "proxy": return .security
        default: return .advanced
        }
    }
}

public struct NativeSettingsSearchEntry: Identifiable, Equatable, Sendable {
    public let path: [String]
    public var id: String { path.joined(separator: "/") }
    public var breadcrumb: String { path.dropLast().joined(separator: " > ") }
}

public struct NativeSettingsSearchResult: Sendable {
    public let entries: [NativeSettingsSearchEntry]
    public let unsupportedPaths: [[String]]
    public let limited: Bool
}

public enum NativeSettingsCatalog {
    public static func search(_ query: String, at root: [String], schema: NativeSettingsSchema,
                              values: NativeSettingValue, allowedCameraIDs: Set<String>,
                              limit: Int = 50) -> NativeSettingsSearchResult {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else {
            return NativeSettingsSearchResult(entries: [], unsupportedPaths: [], limited: false)
        }
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var matches: [NativeSettingsSearchEntry] = []
        var unsupported: [[String]] = []
        var visited = 0
        var limited = false
        func visit(_ path: [String]) {
            guard matches.count < limit, visited < 4000 else { limited = true; return }
            if path.count >= 2, path[0] == "cameras", !allowedCameraIDs.contains(path[1]) { return }
            visited += 1
            do {
                let node = try schema.node(at: path, values: values)
                // Search schema labels and keys, never configuration values or credentials.
                let text = (path + [node["title"]?.string ?? ""]).joined(separator: " ")
                    .replacingOccurrences(of: "_", with: " ")
                if path != root, terms.allSatisfy({ text.localizedCaseInsensitiveContains($0) }) {
                    matches.append(NativeSettingsSearchEntry(path: path))
                }
                let kind = node["type"]?.string ?? values.value(at: path)?.kind
                if kind == "object", path.count - root.count < 8 {
                    for key in try schema.keys(at: path, values: values) { visit(path + [key]) }
                } else if kind == "object" {
                    limited = true
                }
            } catch {
                unsupported.append(path)
            }
        }
        visit(root)
        return NativeSettingsSearchResult(entries: matches, unsupportedPaths: unsupported, limited: limited)
    }
}
