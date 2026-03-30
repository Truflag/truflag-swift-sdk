import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor TruflagClient {
    private struct StorageKeys {
        let user: String
        let anonymousId: String

        init(prefix: String) {
            self.user = "truflag_\(prefix)_user"
            self.anonymousId = "truflag_\(prefix)_anonymous_id"
        }
    }

    private let session: URLSession
    private let storage: TruflagStorage
    private let storageKeys: StorageKeys

    private var options: TruflagConfigureOptions?
    private var user: TruflagUser?
    private var flagsByKey: [String: TruflagFlag] = [:]
    private var latestConfigVersion: String?
    private var ready: Bool = false

    public init(
        storage: TruflagStorage = UserDefaultsTruflagStorage(),
        storagePrefix: String = "ios",
        session: URLSession = .shared
    ) {
        self.storage = storage
        self.storageKeys = StorageKeys(prefix: storagePrefix)
        self.session = session
    }

    public func configure(_ options: TruflagConfigureOptions) async throws {
        let trimmedKey = options.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw TruflagError.invalidApiKey
        }

        self.options = TruflagConfigureOptions(
            apiKey: trimmedKey,
            user: options.user,
            baseURL: options.baseURL,
            requestTimeoutMs: options.requestTimeoutMs
        )

        if let explicitUser = options.user {
            user = explicitUser
            try persistUser(explicitUser)
        } else if let persistedUser = try loadUser() {
            user = persistedUser
        } else {
            let anonymous = TruflagUser(id: try ensureAnonymousId(), attributes: ["anonymous": AnyCodable(true)])
            user = anonymous
            try persistUser(anonymous)
        }

        let startupVersion = try await fetchPublishedConfigVersion()
        try await refresh(expectedConfigVersion: startupVersion)
    }

    public func refresh(expectedConfigVersion: String? = nil) async throws {
        let response = try await fetchFlags(expectedConfigVersion: expectedConfigVersion, bypassRuntimeCache: false)
        if response.meta?.staleConfig == true {
            let retry = try await fetchFlags(expectedConfigVersion: expectedConfigVersion, bypassRuntimeCache: true)
            applyFlags(from: retry)
            return
        }
        applyFlags(from: response)
    }

    public func login(user: TruflagUser) async throws {
        guard options != nil else { throw TruflagError.notConfigured }
        self.user = user
        try persistUser(user)
        try await refresh()
    }

    public func setAttributes(_ attributes: [String: AnyCodable]) async throws {
        guard let currentUser = user else { throw TruflagError.notConfigured }
        var merged = currentUser.attributes ?? [:]
        for (key, value) in attributes {
            merged[key] = value
        }
        let nextUser = TruflagUser(id: currentUser.id, attributes: merged)
        user = nextUser
        try persistUser(nextUser)
        try await refresh()
    }

    public func logout() async throws {
        guard options != nil else { throw TruflagError.notConfigured }
        let anonymous = TruflagUser(id: try ensureAnonymousId(), attributes: ["anonymous": AnyCodable(true)])
        user = anonymous
        try persistUser(anonymous)
        try await refresh()
    }

    public func isReady() -> Bool {
        ready
    }

    public func getFlag<T>(_ key: String, defaultValue: T) -> T {
        guard ready, let flag = flagsByKey[key] else { return defaultValue }
        if let typed = flag.value.value as? T {
            return typed
        }
        return defaultValue
    }

    public func getFlagPayload(_ key: String) -> [String: Any]? {
        guard ready, let payload = flagsByKey[key]?.payload else { return nil }
        return payload.mapValues { $0.value }
    }

    public func getAllFlags() -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, flag) in flagsByKey {
            out[key] = flag.value.value
        }
        return out
    }

    public func track(eventName: String, properties: [String: AnyCodable] = [:]) async throws {
        guard let options else { throw TruflagError.notConfigured }
        guard !eventName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        var event: [String: AnyCodable] = [
            "name": AnyCodable(eventName),
            "timestamp": AnyCodable(iso8601Now())
        ]
        if let currentUser = user {
            event["userId"] = AnyCodable(currentUser.id)
            if let attrs = currentUser.attributes {
                event["userAttributes"] = AnyCodable(attrs.mapValues { $0.value })
            }
        }
        if let anonymousId = storage.getItem(storageKeys.anonymousId) {
            event["anonymousId"] = AnyCodable(anonymousId)
        }
        event["properties"] = AnyCodable(properties.mapValues { $0.value })

        let body: [String: AnyCodable] = [
            "events": AnyCodable([event.mapValues { $0.value }])
        ]

        _ = try await post(
            path: "/v1/events/batch",
            apiKey: options.apiKey,
            requestTimeoutMs: options.requestTimeoutMs,
            body: body
        )
    }

    public func expose(flagKey: String) async throws {
        guard let flag = flagsByKey[flagKey] else { return }
        let payload = flag.payload ?? [:]
        let properties: [String: AnyCodable] = [
            "sdkSource": AnyCodable("ios"),
            "flagKey": AnyCodable(flagKey),
            "variationId": payload["variationId"] ?? AnyCodable(""),
            "experimentId": payload["experimentId"] ?? AnyCodable(""),
            "experimentArmId": payload["experimentArmId"] ?? AnyCodable(""),
            "assignmentId": payload["assignmentId"] ?? AnyCodable(""),
            "configVersion": payload["configVersion"] ?? AnyCodable(""),
            "reason": payload["reason"] ?? AnyCodable(""),
            "source": AnyCodable("sdk")
        ]
        try await track(eventName: "truflag.system.exposure", properties: properties)
    }

    public func destroy() {
        options = nil
        user = nil
        flagsByKey = [:]
        latestConfigVersion = nil
        ready = false
    }

    private func applyFlags(from response: TruflagRemoteFlagsResponse) {
        var indexed: [String: TruflagFlag] = [:]
        for flag in response.flags {
            indexed[flag.key] = flag
        }
        flagsByKey = indexed
        latestConfigVersion = response.meta?.configVersion
        ready = true
    }

    private func ensureAnonymousId() throws -> String {
        if let existing = storage.getItem(storageKeys.anonymousId), !existing.isEmpty {
            return existing
        }
        let next = "anon_\(UUID().uuidString.lowercased())"
        storage.setItem(storageKeys.anonymousId, value: next)
        return next
    }

    private func loadUser() throws -> TruflagUser? {
        guard let raw = storage.getItem(storageKeys.user), !raw.isEmpty else {
            return nil
        }
        let data = Data(raw.utf8)
        return try JSONDecoder().decode(TruflagUser.self, from: data)
    }

    private func persistUser(_ user: TruflagUser) throws {
        let encoded = try JSONEncoder().encode(user)
        guard let text = String(data: encoded, encoding: .utf8) else {
            throw TruflagError.serializationFailed
        }
        storage.setItem(storageKeys.user, value: text)
    }

    private func fetchPublishedConfigVersion() async throws -> String? {
        guard let options else { throw TruflagError.notConfigured }
        let currentPath = "/config/client-side-id=\(urlEncode(options.apiKey))/current.json"
        let responseData = try await get(
            path: currentPath,
            apiKey: options.apiKey,
            query: [:],
            requestTimeoutMs: options.requestTimeoutMs
        )

        guard
            let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            let version = object["version"] as? String,
            !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return version
    }

    private func fetchFlags(expectedConfigVersion: String?, bypassRuntimeCache: Bool) async throws -> TruflagRemoteFlagsResponse {
        guard let options else { throw TruflagError.notConfigured }
        guard let user else { throw TruflagError.notConfigured }

        var query: [String: String] = [
            "userId": user.id
        ]
        if let attrs = user.attributes {
            let encodedAttrs = try JSONEncoder().encode(attrs)
            query["userAttributes"] = String(data: encodedAttrs, encoding: .utf8)
        }
        if let anonymousId = storage.getItem(storageKeys.anonymousId) {
            query["anonymousId"] = anonymousId
        }
        if let expectedConfigVersion, !expectedConfigVersion.isEmpty {
            query["expectedConfigVersion"] = expectedConfigVersion
        }
        if bypassRuntimeCache {
            query["bypassRuntimeCache"] = "1"
        }

        let data = try await get(
            path: "/v1/flags",
            apiKey: options.apiKey,
            query: query,
            requestTimeoutMs: options.requestTimeoutMs
        )
        return try JSONDecoder().decode(TruflagRemoteFlagsResponse.self, from: data)
    }

    private func get(
        path: String,
        apiKey: String,
        query: [String: String],
        requestTimeoutMs: Int
    ) async throws -> Data {
        guard let options else { throw TruflagError.notConfigured }
        guard var components = URLComponents(string: buildURL(baseURL: options.baseURL, path: path)) else {
            throw TruflagError.invalidURL
        }
        components.queryItems = query
            .filter { !$0.value.isEmpty }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
            .sorted(by: { $0.name < $1.name })

        guard let url = components.url else {
            throw TruflagError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = TimeInterval(requestTimeoutMs) / 1000.0
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TruflagError.networkFailed
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TruflagError.httpError(statusCode: http.statusCode)
        }

        return data
    }

    private func post(
        path: String,
        apiKey: String,
        requestTimeoutMs: Int,
        body: [String: AnyCodable]
    ) async throws -> Data {
        guard let options else { throw TruflagError.notConfigured }
        guard let url = URL(string: buildURL(baseURL: options.baseURL, path: path)) else {
            throw TruflagError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(requestTimeoutMs) / 1000.0
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TruflagError.networkFailed
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TruflagError.httpError(statusCode: http.statusCode)
        }

        return data
    }

    private func urlEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private func buildURL(baseURL: URL, path: String) -> String {
        let normalizedBase = baseURL.absoluteString.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        return normalizedBase + normalizedPath
    }

    private func iso8601Now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

public enum TruflagError: Error, Equatable {
    case invalidApiKey
    case notConfigured
    case invalidURL
    case serializationFailed
    case networkFailed
    case httpError(statusCode: Int)
}
