import Foundation

public struct NativeCameraNotificationRules: Identifiable, Sendable {
    public let id: String
    public let cameraEnabled: Bool?
    public let notificationsEnabled: Bool?
    public let cooldown: Double?
    public let alertLabels: [String]?
    public let requiredZones: [String]?
    public var eligible: Bool? {
        guard let cameraEnabled, let notificationsEnabled else { return nil }
        return cameraEnabled && notificationsEnabled
    }

    public init(camera: String, configuration: NativeSettingValue) {
        id = camera
        let value = configuration["cameras"]?[camera]
        cameraEnabled = value?["enabled"]?.bool
        notificationsEnabled = value?["notifications"]?["enabled"]?.bool
            ?? configuration["notifications"]?["enabled"]?.bool
        cooldown = value?["notifications"]?["cooldown"]?.numeric
        alertLabels = Self.strings(value?["review"]?["alerts"]?["labels"])
        requiredZones = Self.strings(value?["review"]?["alerts"]?["required_zones"])
    }

    private static func strings(_ value: NativeSettingValue?) -> [String]? {
        if let string = value?.string { return [string] }
        guard let array = value?.array, array.allSatisfy({ $0.string != nil }) else { return nil }
        return array.compactMap(\.string)
    }
}
