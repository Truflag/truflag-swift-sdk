import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum TruflagLogLevel: String, Codable, Sendable {
    case debug
    case info
    case warn
    case error
    case silent
}

public protocol TruflagLogger: Sendable {
    func debug(message: String, meta: [String: AnyCodable]?)
    func info(message: String, meta: [String: AnyCodable]?)
    func warn(message: String, meta: [String: AnyCodable]?)
    func error(message: String, meta: [String: AnyCodable]?)
}

public typealias TruflagFetchFunction = @Sendable (URLRequest) async throws -> (Data, URLResponse)

public struct TruflagUser: Codable, Equatable, Sendable {
    public let id: String
    public let attributes: [String: AnyCodable]?

    public init(id: String, attributes: [String: AnyCodable]? = nil) {
        self.id = id
        self.attributes = attributes
    }
}

public struct TruflagConfigureOptions: Sendable {
    public let apiKey: String
    public let user: TruflagUser?
    public let baseURL: URL
    public let streamURL: URL
    public let streamEnabled: Bool
    public let pollingIntervalMs: Int
    public let requestTimeoutMs: Int
    public let cacheTtlMs: Int
    public let telemetryFlushIntervalMs: Int
    public let telemetryBatchSize: Int
    public let telemetryEnabled: Bool
    public let logLevel: TruflagLogLevel
    public let logger: (any TruflagLogger)?
    public let fetchFn: TruflagFetchFunction?
    public let storage: (any TruflagStorage)?
    public let debugLoggingEnabled: Bool

    public init(
        apiKey: String,
        user: TruflagUser? = nil,
        baseURL: URL = URL(string: "https://sdk.truflag.com")!,
        streamURL: URL = URL(string: "wss://stream.sdk.truflag.com")!,
        streamEnabled: Bool = true,
        pollingIntervalMs: Int = 60_000,
        requestTimeoutMs: Int = 6000,
        cacheTtlMs: Int = 5 * 60_000,
        telemetryFlushIntervalMs: Int = 10_000,
        telemetryBatchSize: Int = 50,
        telemetryEnabled: Bool = true,
        logLevel: TruflagLogLevel = .debug,
        logger: (any TruflagLogger)? = nil,
        fetchFn: TruflagFetchFunction? = nil,
        storage: (any TruflagStorage)? = nil,
        debugLoggingEnabled: Bool = false
    ) {
        self.apiKey = apiKey
        self.user = user
        self.baseURL = baseURL
        self.streamURL = streamURL
        self.streamEnabled = streamEnabled
        self.pollingIntervalMs = pollingIntervalMs
        self.requestTimeoutMs = requestTimeoutMs
        self.cacheTtlMs = cacheTtlMs
        self.telemetryFlushIntervalMs = telemetryFlushIntervalMs
        self.telemetryBatchSize = telemetryBatchSize
        self.telemetryEnabled = telemetryEnabled
        self.logLevel = logLevel
        self.logger = logger
        self.fetchFn = fetchFn
        self.storage = storage
        self.debugLoggingEnabled = debugLoggingEnabled
    }
}

public struct TruflagFlag: Codable, Equatable, Sendable {
    public let key: String
    public let value: AnyCodable
    public let payload: [String: AnyCodable]?

    public init(key: String, value: AnyCodable, payload: [String: AnyCodable]? = nil) {
        self.key = key
        self.value = value
        self.payload = payload
    }
}

public struct TruflagClientState: Equatable, Sendable {
    public let configured: Bool
    public let ready: Bool
    public let apiKey: String?
    public let user: TruflagUser?
    public let userId: String
    public let flags: [String: TruflagFlag]
    public let lastFetchAt: Int64?
    public let configVersion: String?
    public let error: String?
    public let lastError: String?
    public let streamStatus: String
    public let pollingActive: Bool
    public let lastStreamEventAt: String?
    public let lastStreamEventVersion: String?
}

struct TruflagRemoteFlagsMeta: Codable {
    let configVersion: String?
    let staleConfig: Bool?
}

struct TruflagRemoteFlagsResponse: Codable {
    let flags: [TruflagFlag]
    let meta: TruflagRemoteFlagsMeta?
}

public struct AnyCodable: Codable, Equatable, @unchecked Sendable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let value = try? container.decode(Bool.self) {
            self.value = value
        } else if let value = try? container.decode(Int.self) {
            self.value = value
        } else if let value = try? container.decode(Double.self) {
            self.value = value
        } else if let value = try? container.decode(String.self) {
            self.value = value
        } else if let value = try? container.decode([String: AnyCodable].self) {
            self.value = value.mapValues { $0.value }
        } else if let value = try? container.decode([AnyCodable].self) {
            self.value = value.map { $0.value }
        } else if container.decodeNil() {
            self.value = NSNull()
        } else {
            throw DecodingError.typeMismatch(
                AnyCodable.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unsupported value in AnyCodable"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case let value as Bool:
            try container.encode(value)
        case let value as Int:
            try container.encode(value)
        case let value as Double:
            try container.encode(value)
        case let value as String:
            try container.encode(value)
        case let value as [String: Any]:
            try container.encode(value.mapValues(AnyCodable.init))
        case let value as [Any]:
            try container.encode(value.map(AnyCodable.init))
        case _ as NSNull:
            try container.encodeNil()
        default:
            let context = EncodingError.Context(
                codingPath: encoder.codingPath,
                debugDescription: "Unsupported value in AnyCodable"
            )
            throw EncodingError.invalidValue(value, context)
        }
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case let (left as Bool, right as Bool):
            return left == right
        case let (left as Int, right as Int):
            return left == right
        case let (left as Double, right as Double):
            return left == right
        case let (left as String, right as String):
            return left == right
        case let (left as [String: Any], right as [String: Any]):
            return NSDictionary(dictionary: left).isEqual(to: right)
        case let (left as [Any], right as [Any]):
            return NSArray(array: left).isEqual(to: right)
        case (_ as NSNull, _ as NSNull):
            return true
        default:
            return false
        }
    }
}

public protocol TruflagStorage: Sendable {
    func getItem(_ key: String) -> String?
    func setItem(_ key: String, value: String)
    func removeItem(_ key: String)
}

public final class UserDefaultsTruflagStorage: TruflagStorage, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func getItem(_ key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func setItem(_ key: String, value: String) {
        defaults.set(value, forKey: key)
    }

    public func removeItem(_ key: String) {
        defaults.removeObject(forKey: key)
    }
}
