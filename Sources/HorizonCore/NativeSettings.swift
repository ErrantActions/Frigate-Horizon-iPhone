import Foundation

public enum NativeSettingValue: Codable, Equatable, Sendable {
    case object([String: NativeSettingValue]), array([NativeSettingValue])
    case string(String), integer(Int64), number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let result = try? value.decode(Bool.self) { self = .bool(result) }
        else if let result = try? value.decode(Int64.self) { self = .integer(result) }
        else if let result = try? value.decode(Double.self) { self = .number(result) }
        else if let result = try? value.decode(String.self) { self = .string(result) }
        else if let result = try? value.decode([NativeSettingValue].self) { self = .array(result) }
        else { self = .object(try value.decode([String: NativeSettingValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var target = encoder.singleValueContainer()
        switch self {
        case .object(let value): try target.encode(value)
        case .array(let value): try target.encode(value)
        case .string(let value): try target.encode(value)
        case .integer(let value): try target.encode(value)
        case .number(let value): try target.encode(value)
        case .bool(let value): try target.encode(value)
        case .null: try target.encodeNil()
        }
    }

    public var object: [String: Self]? { if case .object(let value) = self { return value }; return nil }
    public var array: [Self]? { if case .array(let value) = self { return value }; return nil }
    public var string: String? { if case .string(let value) = self { return value }; return nil }
    public var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
    public var numeric: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .number(let value): return value
        default: return nil
        }
    }
    public var kind: String {
        switch self {
        case .object: return "object"
        case .array: return "array"
        case .string: return "string"
        case .integer: return "integer"
        case .number: return "number"
        case .bool: return "boolean"
        case .null: return "null"
        }
    }
    public var fieldText: String {
        switch self {
        case .string(let value): return value
        case .integer(let value): return String(value)
        case .number(let value): return String(value)
        case .bool(let value): return value ? "On" : "Off"
        case .null: return "Not set"
        case .array(let value): return "\(value.count) items"
        case .object(let value): return "\(value.count) settings"
        }
    }
    public subscript(_ key: String) -> Self? { object?[key] }

    public func value(at path: [String]) -> Self? {
        var current = self
        for component in path {
            if let values = current.object, let child = values[component] { current = child }
            else if let values = current.array, let index = Int(component), values.indices.contains(index) { current = values[index] }
            else { return nil }
        }
        return current
    }

    public func replacing(at path: [String], with value: Self) throws -> Self {
        guard let first = path.first else { return value }
        let rest = Array(path.dropFirst())
        switch self {
        case .object(var values):
            values[first] = try (values[first] ?? .object([:])).replacing(at: rest, with: value)
            return .object(values)
        case .array(var values):
            guard let index = Int(first), values.indices.contains(index) else {
                throw HorizonError.message("Reload before editing this list item.")
            }
            values[index] = try values[index].replacing(at: rest, with: value)
            return .array(values)
        case .null:
            return try NativeSettingValue.object([:]).replacing(at: path, with: value)
        default: throw HorizonError.message("This setting's parent is not an editable object or list.")
        }
    }

    var containsRedaction: Bool {
        switch self {
        case .string(let value):
            return value.contains("__FRIGATE_SAVED_CREDENTIAL__") || ["***", "******", "<redacted>"].contains(value.lowercased())
        case .array(let values): return values.contains(where: \.containsRedaction)
        case .object(let values): return values.values.contains(where: \.containsRedaction)
        default: return false
        }
    }

    var containsPrivateKeyMaterial: Bool {
        switch self {
        case .string(let value): return value.contains("PRIVATE KEY-----")
        case .array(let values): return values.contains(where: \.containsPrivateKeyMaterial)
        case .object(let values): return values.values.contains(where: \.containsPrivateKeyMaterial)
        default: return false
        }
    }

    var containsPrivateURL: Bool {
        switch self {
        case .string(let value):
            return value.contains("://") && (value.contains("@") || value.contains("?"))
        case .array(let values): return values.contains(where: \.containsPrivateURL)
        case .object(let values): return values.values.contains(where: \.containsPrivateURL)
        default: return false
        }
    }
}

public struct NativeSettingChange: Identifiable, Equatable, Sendable {
    public let path: [String]
    public let before: NativeSettingValue?
    public let after: NativeSettingValue
    public var id: String { path.joined(separator: ".") }
    public var sensitive: Bool {
        let keys = path.joined(separator: ".").lowercased()
        return ["password", "secret", "credential", "token", "private_key", "api_key"].contains(where: keys.contains)
            || (path.contains("ffmpeg") && path.contains("inputs"))
            || before?.containsRedaction == true || after.containsRedaction
            || before?.containsPrivateURL == true || after.containsPrivateURL
    }
    public var beforeSummary: String { sensitive ? "Hidden" : summary(before) }
    public var afterSummary: String {
        if sensitive { return "Hidden" }
        if path.starts(with: ["auth", "roles"]), after.array?.isEmpty == true { return "All cameras (empty role list)" }
        return summary(after)
    }
    private func summary(_ value: NativeSettingValue?) -> String {
        if let values = value?.array, values.allSatisfy({ $0.object == nil && $0.array == nil }) {
            if values.isEmpty { return "Empty list" }
            return String(values.map(\.fieldText).joined(separator: ", ").prefix(120))
        }
        return String((value?.fieldText ?? "Inherited / default").prefix(120))
    }
}

public struct NativeSettingsUpdate: Encodable, Sendable {
    public let requiresRestart = 1
    public let configData: NativeSettingValue
    enum CodingKeys: String, CodingKey {
        case requiresRestart = "requires_restart"
        case configData = "config_data"
    }
}

public struct NativeSettingsDraft: Sendable {
    public let original: NativeSettingValue
    public private(set) var document: NativeSettingValue
    public init(document: NativeSettingValue) { original = document; self.document = document }

    public var changes: [NativeSettingChange] { Self.diff(original, document, path: []) }

    public mutating func set(_ value: NativeSettingValue, at path: [String]) throws {
        guard !path.isEmpty, path.allSatisfy({ !$0.isEmpty && !$0.contains(".") && !$0.contains("/") && !$0.contains("\\") }),
              !path.contains("enabled_in_config") else {
            throw HorizonError.message("This computed or ambiguous setting requires the advanced editor.")
        }
        if value.containsPrivateKeyMaterial {
            throw HorizonError.message("Private keys must remain on the server. Enter only the configured key-file path, never key contents.")
        }
        let candidate = try document.replacing(at: path, with: value)
        let delta = Self.diff(original, candidate, path: [])
        guard !delta.contains(where: { $0.after.containsRedaction }) else {
            throw HorizonError.message("This edit would resend hidden credentials inside a list. Use the advanced editor or the server's dedicated connection settings.")
        }
        document = candidate
    }

    public func update() throws -> NativeSettingsUpdate {
        guard !changes.isEmpty else { throw HorizonError.message("No settings have changed.") }
        var patch = NativeSettingValue.object([:])
        for change in changes { patch = try patch.replacing(at: change.path, with: change.after) }
        return NativeSettingsUpdate(configData: patch)
    }

    private static func diff(_ before: NativeSettingValue?, _ after: NativeSettingValue, path: [String]) -> [NativeSettingChange] {
        if before == after { return [] }
        if let values = after.object {
            let old = before?.object ?? [:]
            return Set(values.keys).union(old.keys).sorted().flatMap { key in
                diff(old[key], values[key] ?? .null, path: path + [key])
            }
        }
        return [NativeSettingChange(path: path, before: before, after: after)]
    }
}

public struct NativeSettingsSchema: Sendable {
    private let document: NativeSettingValue
    public init(document: NativeSettingValue) { self.document = document }

    public func resolved(_ schema: NativeSettingValue, value: NativeSettingValue?) throws -> NativeSettingValue {
        try resolve(schema, value: value, depth: 0)
    }

    private func resolve(_ schema: NativeSettingValue, value: NativeSettingValue?, depth: Int) throws -> NativeSettingValue {
        guard depth < 20 else { throw HorizonError.message("The settings schema contains a recursive reference.") }
        var current = schema
        for _ in 0..<20 {
            if let reference = current["$ref"]?.string {
                guard reference.hasPrefix("#/"),
                      let target = document.value(at: reference.dropFirst(2).split(separator: "/").map {
                          String($0).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
                      }) else { throw HorizonError.message("The server returned an unsupported settings reference.") }
                var merged = target.object ?? [:]
                for (key, entry) in current.object ?? [:] where key != "$ref" { merged[key] = entry }
                current = .object(merged)
                continue
            }
            if let choices = current["anyOf"]?.array ?? current["oneOf"]?.array {
                let resolved = try choices.map { try self.resolve($0, value: value, depth: depth + 1) }
                let tagged = resolved.first { choice in
                    guard let values = value?.object, let properties = choice["properties"]?.object else { return false }
                    var matched = false
                    for (key, rule) in properties {
                        guard let actual = values[key] else { continue }
                        if let constant = rule["const"] {
                            guard constant == actual else { return false }
                            matched = true
                        }
                        if let options = rule["enum"]?.array, options.count == 1 {
                            guard options[0] == actual else { return false }
                            matched = true
                        }
                    }
                    return matched
                }
                guard let choice = tagged ?? resolved.first(where: {
                    value?.kind != "null" && ($0["type"]?.string == value?.kind ||
                        ($0["type"]?.string == "number" && value?.kind == "integer"))
                })
                    ?? resolved.first(where: { $0["type"]?.string != "null" }) else {
                    throw HorizonError.message("No supported type is available for this setting.")
                }
                var merged = choice.object ?? [:]
                if resolved.contains(where: { $0["type"]?.string == "null" }) { merged["_nativeNullable"] = .bool(true) }
                for (key, entry) in current.object ?? [:] where key != "anyOf" && key != "oneOf" { merged[key] = entry }
                return .object(merged)
            }
            if let choices = current["allOf"]?.array {
                var merged: [String: NativeSettingValue] = [:]
                for choice in choices {
                    let entry = try resolve(choice, value: value, depth: depth + 1)
                    for (key, value) in entry.object ?? [:] {
                        if key == "properties", let properties = value.object {
                            merged[key] = .object((merged[key]?.object ?? [:]).merging(properties) { _, new in new })
                        } else { merged[key] = value }
                    }
                }
                for (key, value) in current.object ?? [:] where key != "allOf" { merged[key] = value }
                current = .object(merged)
                continue
            }
            return current
        }
        throw HorizonError.message("The settings schema contains a recursive reference.")
    }

    public func node(at path: [String], values: NativeSettingValue) throws -> NativeSettingValue {
        var schema = try resolved(document, value: values)
        var value: NativeSettingValue? = values
        for component in path {
            let candidate: NativeSettingValue?
            if schema["type"]?.string == "array" || value?.array != nil { candidate = schema["items"] }
            else { candidate = schema["properties"]?[component] ?? schema["additionalProperties"] }
            guard let candidate, candidate != .bool(false) else {
                throw HorizonError.message("This setting is not described by the server's schema.")
            }
            value = value?.value(at: [component])
            schema = try resolved(candidate == .bool(true) ? .object([:]) : candidate, value: value)
        }
        return schema
    }

    public func keys(at path: [String], values: NativeSettingValue) throws -> [String] {
        let schema = try node(at: path, values: values)
        let declared = Set(schema["properties"]?.object?.keys.map { $0 } ?? [])
        if !declared.isEmpty { return declared.sorted() }
        return values.value(at: path)?.object?.keys.sorted() ?? []
    }

    public func validate(_ value: NativeSettingValue, schema: NativeSettingValue) throws {
        let schema = try resolved(schema, value: value)
        if schema["readOnly"]?.bool == true { throw HorizonError.message("This setting is read-only.") }
        if value == .null, schema["_nativeNullable"]?.bool == true { return }
        if let type = schema["type"]?.string, type != value.kind && !(type == "number" && value.kind == "integer") {
            throw HorizonError.message("Enter a value of type \(type).")
        }
        if let choices = schema["enum"]?.array, !choices.contains(value) {
            throw HorizonError.message("Choose one of the values supported by the server.")
        }
        if let number = value.numeric {
            guard number.isFinite else { throw HorizonError.message("Enter a finite number.") }
            if let minimum = schema["minimum"]?.numeric, number < minimum { throw HorizonError.message("Minimum value: \(minimum).") }
            if let maximum = schema["maximum"]?.numeric, number > maximum { throw HorizonError.message("Maximum value: \(maximum).") }
            if let minimum = schema["exclusiveMinimum"]?.numeric, number <= minimum { throw HorizonError.message("Value must exceed \(minimum).") }
            if let maximum = schema["exclusiveMaximum"]?.numeric, number >= maximum { throw HorizonError.message("Value must be below \(maximum).") }
            if let step = schema["multipleOf"]?.numeric, step > 0,
               abs(number / step - (number / step).rounded()) > 0.000001 {
                throw HorizonError.message("Value must be a multiple of \(step).")
            }
        }
        if let text = value.string {
            if let maximum = schema["maxLength"]?.numeric, Double(text.count) > maximum { throw HorizonError.message("This value is too long.") }
            if let minimum = schema["minLength"]?.numeric, Double(text.count) < minimum { throw HorizonError.message("This value is too short.") }
            if let pattern = schema["pattern"]?.string {
                let expression = try NSRegularExpression(pattern: pattern)
                guard expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else {
                    throw HorizonError.message("This value does not match the server's required format.")
                }
            }
        }
        if let entries = value.array {
            if let minimum = schema["minItems"]?.numeric, Double(entries.count) < minimum { throw HorizonError.message("This list has too few items.") }
            if let maximum = schema["maxItems"]?.numeric, Double(entries.count) > maximum { throw HorizonError.message("This list has too many items.") }
            if let item = schema["items"] { for entry in entries { try validate(entry, schema: item) } }
        }
    }
}
