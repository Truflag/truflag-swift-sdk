import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor TruflagClient {
    private struct StorageKeys {
        let user: String
        let anonymousId: String
        let snapshot: String

        init(prefix: String) {
            self.user = "truflag_\(prefix)_user"
            self.anonymousId = "truflag_\(prefix)_anonymous_id"
            self.snapshot = "truflag_\(prefix)_snapshot"
        }
    }

    private struct FlagSnapshot: Codable {
        let flags: [TruflagFlag]
        let fetchedAt: Int64
    }

    private struct CachedSnapshotPayload: Codable {
        let snapshot: FlagSnapshot
        let savedAt: Int64
    }

    private enum Defaults {
        static let retryAttempts = 4
        static let retryBaseDelayMs: UInt64 = 400
        static let retryMaxDelayMs: UInt64 = 8_000
        static let retryJitterRatio = 0.35
    }

    private let session: URLSession
    private let storage: TruflagStorage
    private let storageKeys: StorageKeys
    private let blockedAttributeKeys: Set<String> = [
        "projectID",
        "id",
        "environmentID",
        "currentUserID",
        "deviceID",
        "tenantGroup",
        "isAnonymous",
        "anonymousID",
        "firstSeenAt",
        "lastSeenAt",
        "userAttributes",
    ]

    private var options: TruflagConfigureOptions?
    private var user: TruflagUser?
    private var flagsByKey: [String: TruflagFlag] = [:]
    private var latestConfigVersion: String?
    private var ready: Bool = false

    private var telemetryQueue: [[String: Any]] = []
    private var telemetryFlushTask: Task<Void, Never>?
    private var exposureIdentityByFlag: [String: String] = [:]

    private var configureSignature: String?
    private var configureInFlight: Task<Void, Error>?
    private var pendingExpectedConfigVersion: String?
    private var refreshInFlight: Task<Void, Error>?

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
        let signature = buildConfigureSignature(options)
        if let inFlight = configureInFlight, configureSignature == signature {
            return try await inFlight.value
        }
        if self.options != nil, configureSignature == signature {
            return
        }

        let task = Task {
            try await configureInternal(options, signature: signature)
        }
        configureInFlight = task
        do {
            try await task.value
        } catch {
            configureInFlight = nil
            throw error
        }
        configureInFlight = nil
    }

    private func configureInternal(_ rawOptions: TruflagConfigureOptions, signature: String) async throws {
        let trimmedKey = rawOptions.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw TruflagError.invalidApiKey
        }

        stopTelemetryFlush()
        configureSignature = signature
        exposureIdentityByFlag = [:]
        options = TruflagConfigureOptions(
            apiKey: trimmedKey,
            user: rawOptions.user,
            baseURL: rawOptions.baseURL,
            requestTimeoutMs: rawOptions.requestTimeoutMs,
            cacheTtlMs: max(1, rawOptions.cacheTtlMs),
            telemetryFlushIntervalMs: max(100, rawOptions.telemetryFlushIntervalMs),
            telemetryBatchSize: max(1, rawOptions.telemetryBatchSize),
            telemetryEnabled: rawOptions.telemetryEnabled
        )

        guard let options else { throw TruflagError.notConfigured }

        let resolvedUser: TruflagUser
        if let explicit = options.user {
            resolvedUser = try normalizeUser(explicit)
            user = resolvedUser
            try persistUser(resolvedUser)
        } else if let persisted = try loadUser() {
            resolvedUser = try normalizeUser(persisted)
            user = resolvedUser
            try persistUser(resolvedUser)
        } else {
            let anonymous = TruflagUser(id: try ensureAnonymousId(), attributes: ["anonymous": AnyCodable(true)])
            resolvedUser = anonymous
            user = resolvedUser
            try persistUser(resolvedUser)
        }

        if let cachedSnapshot = try loadCachedSnapshot(ttlMs: options.cacheTtlMs) {
            applyFlags(from: cachedSnapshot.flags, configVersion: nil)
            ready = true
        } else {
            flagsByKey = [:]
            ready = false
        }

        startTelemetryFlush()

        let startupVersion = await fetchPublishedConfigVersionNoThrow()
        try await refresh(expectedConfigVersion: startupVersion)
    }

    public func refresh(expectedConfigVersion: String? = nil) async throws {
        if let expectedConfigVersion, !expectedConfigVersion.isEmpty {
            pendingExpectedConfigVersion = expectedConfigVersion
        }
        if let inFlight = refreshInFlight {
            return try await inFlight.value
        }

        let task = Task {
            try await drainRefreshQueue()
        }
        refreshInFlight = task
        do {
            try await task.value
        } catch {
            refreshInFlight = nil
            throw error
        }
        refreshInFlight = nil
    }

    private func drainRefreshQueue() async throws {
        var expected = pendingExpectedConfigVersion
        pendingExpectedConfigVersion = nil

        while true {
            try await refreshInternal(expectedConfigVersion: expected)
            let pending = pendingExpectedConfigVersion
            pendingExpectedConfigVersion = nil
            guard let next = pending, !next.isEmpty, next != latestConfigVersion else {
                break
            }
            expected = next
        }
    }

    private func refreshInternal(expectedConfigVersion: String?) async throws {
        do {
            var response = try await fetchFlags(expectedConfigVersion: expectedConfigVersion, bypassRuntimeCache: false)
            if response.meta?.staleConfig == true {
                response = try await fetchFlags(expectedConfigVersion: expectedConfigVersion, bypassRuntimeCache: true)
            }

            let fetchedAt = nowMs()
            applyFlags(from: response.flags, configVersion: response.meta?.configVersion)
            ready = true
            try persistCachedSnapshot(flags: response.flags, fetchedAt: fetchedAt)
        } catch {
            if !flagsByKey.isEmpty {
                ready = true
            }
            throw error
        }
    }

    public func login(user: TruflagUser) async throws {
        _ = try getOptionsOrThrow()
        let nextUser = try normalizeUser(user)
        self.user = nextUser
        exposureIdentityByFlag = [:]
        try persistUser(nextUser)
        try await refresh()
    }

    public func setAttributes(_ attributes: [String: AnyCodable]) async throws {
        _ = try getOptionsOrThrow()
        guard let currentUser = user else { throw TruflagError.notConfigured }
        try validateAttributes(attributes)
        var merged = currentUser.attributes ?? [:]
        for (key, value) in attributes {
            merged[key] = value
        }
        let nextUser = TruflagUser(id: currentUser.id, attributes: merged)
        user = nextUser
        exposureIdentityByFlag = [:]
        try persistUser(nextUser)
        try await refresh()
    }

    public func logout() async throws {
        _ = try getOptionsOrThrow()
        let anonymous = TruflagUser(id: try ensureAnonymousId(), attributes: ["anonymous": AnyCodable(true)])
        user = anonymous
        exposureIdentityByFlag = [:]
        try persistUser(anonymous)
        try await refresh()
    }

    public func isReady() -> Bool {
        ready
    }

    public func notifyFlagRead(flagKey: String) {
        guard ready, let flag = flagsByKey[flagKey] else { return }
        enqueueExposure(flag: flag, extraProperties: nil)
    }

    public func getFlag<T>(_ key: String, defaultValue: T) -> T {
        guard ready, let flag = flagsByKey[key] else { return defaultValue }
        enqueueExposure(flag: flag, extraProperties: nil)
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
            enqueueExposure(flag: flag, extraProperties: nil)
            out[key] = flag.value.value
        }
        return out
    }

    public func track(eventName: String, properties: [String: AnyCodable] = [:]) async throws {
        _ = try getOptionsOrThrow()
        guard !eventName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        var event: [String: Any] = [
            "name": eventName,
            "timestamp": iso8601Now(),
        ]
        if let currentUser = user {
            event["userId"] = currentUser.id
            if let attrs = currentUser.attributes {
                event["userAttributes"] = attrs.mapValues { $0.value }
            }
        }
        if let anonymousId = storage.getItem(storageKeys.anonymousId) {
            event["anonymousId"] = anonymousId
        }
        event["properties"] = properties.mapValues { $0.value }

        enqueueTelemetryEvent(event)
        if telemetryQueue.count >= (options?.telemetryBatchSize ?? 50) {
            await flushTelemetry()
        }
    }

    public func expose(flagKey: String) async throws {
        _ = try getOptionsOrThrow()
        guard let flag = flagsByKey[flagKey] else { return }
        enqueueExposure(flag: flag, extraProperties: nil)
        if telemetryQueue.count >= (options?.telemetryBatchSize ?? 50) {
            await flushTelemetry()
        }
    }

    public func destroy() {
        stopTelemetryFlush()
        options = nil
        user = nil
        flagsByKey = [:]
        latestConfigVersion = nil
        ready = false
        telemetryQueue = []
        exposureIdentityByFlag = [:]
        configureInFlight = nil
        configureSignature = nil
        refreshInFlight = nil
        pendingExpectedConfigVersion = nil
    }

    private func getOptionsOrThrow() throws -> TruflagConfigureOptions {
        guard let options else {
            throw TruflagError.notConfigured
        }
        return options
    }

    private func applyFlags(from flags: [TruflagFlag], configVersion: String?) {
        var indexed: [String: TruflagFlag] = [:]
        for flag in flags {
            indexed[flag.key] = flag
        }
        flagsByKey = indexed
        latestConfigVersion = configVersion
    }

    private func ensureAnonymousId() throws -> String {
        if let existing = storage.getItem(storageKeys.anonymousId), !existing.isEmpty {
            return existing
        }
        let next = "anon_\(UUID().uuidString.lowercased())"
        storage.setItem(storageKeys.anonymousId, value: next)
        return next
    }

    private func validateAttributes(_ attributes: [String: AnyCodable]?) throws {
        guard let attributes else { return }
        let blocked = attributes.keys.filter { blockedAttributeKeys.contains($0) }
        if !blocked.isEmpty {
            throw TruflagError.blockedAttributeKeys(blocked.sorted())
        }
    }

    private func normalizeUser(_ user: TruflagUser) throws -> TruflagUser {
        try validateAttributes(user.attributes)
        return user
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

    private func loadCachedSnapshot(ttlMs: Int) throws -> FlagSnapshot? {
        guard let raw = storage.getItem(storageKeys.snapshot), !raw.isEmpty else {
            return nil
        }
        let data = Data(raw.utf8)
        let payload = try JSONDecoder().decode(CachedSnapshotPayload.self, from: data)
        if nowMs() - payload.savedAt > Int64(ttlMs) {
            return nil
        }
        return payload.snapshot
    }

    private func persistCachedSnapshot(flags: [TruflagFlag], fetchedAt: Int64) throws {
        let snapshot = FlagSnapshot(flags: flags, fetchedAt: fetchedAt)
        let payload = CachedSnapshotPayload(snapshot: snapshot, savedAt: nowMs())
        let data = try JSONEncoder().encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TruflagError.serializationFailed
        }
        storage.setItem(storageKeys.snapshot, value: text)
    }

    private func fetchPublishedConfigVersionNoThrow() async -> String? {
        do {
            return try await fetchPublishedConfigVersion()
        } catch {
            return nil
        }
    }

    private func fetchPublishedConfigVersion() async throws -> String? {
        let options = try getOptionsOrThrow()
        let currentPath = "/config/client-side-id=\(urlEncode(options.apiKey))/current.json"
        let responseData = try await withRetry {
            try await withTimeout(
                promise: {
                    try await self.get(
                        path: currentPath,
                        apiKey: options.apiKey,
                        query: [:],
                        requestTimeoutMs: options.requestTimeoutMs
                    )
                },
                timeoutMs: options.requestTimeoutMs,
                message: "Timed out while loading current config version."
            )
        }

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
        let options = try getOptionsOrThrow()
        guard let user else { throw TruflagError.notConfigured }

        var query: [String: String] = [
            "userId": user.id,
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

        let requestQuery = query
        return try await withRetry {
            let data = try await withTimeout(
                promise: {
                    try await self.get(
                        path: "/v1/flags",
                        apiKey: options.apiKey,
                        query: requestQuery,
                        requestTimeoutMs: options.requestTimeoutMs
                    )
                },
                timeoutMs: options.requestTimeoutMs,
                message: "Timed out while refreshing flags."
            )
            return try JSONDecoder().decode(TruflagRemoteFlagsResponse.self, from: data)
        }
    }

    private func get(
        path: String,
        apiKey: String,
        query: [String: String],
        requestTimeoutMs: Int
    ) async throws -> Data {
        let options = try getOptionsOrThrow()
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
        let options = try getOptionsOrThrow()
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

    private func enqueueTelemetryEvent(_ event: [String: Any]) {
        telemetryQueue.append(event)
    }

    private func startTelemetryFlush() {
        stopTelemetryFlush()
        let intervalMs = max(100, options?.telemetryFlushIntervalMs ?? 10_000)
        let sleepNanos = UInt64(intervalMs) * 1_000_000
        telemetryFlushTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: sleepNanos)
                if Task.isCancelled { break }
                await self.flushTelemetry()
            }
        }
    }

    private func stopTelemetryFlush() {
        telemetryFlushTask?.cancel()
        telemetryFlushTask = nil
    }

    private func flushTelemetry() async {
        guard let options else { return }
        if options.telemetryEnabled == false { return }
        if telemetryQueue.isEmpty { return }

        let batchSize = max(1, options.telemetryBatchSize)
        let batch = Array(telemetryQueue.prefix(batchSize))
        let outboundEvents = dedupeExposureEvents(in: batch)
        let body: [String: AnyCodable] = [
            "events": AnyCodable(outboundEvents),
        ]

        do {
            _ = try await post(
                path: "/v1/events/batch",
                apiKey: options.apiKey,
                requestTimeoutMs: options.requestTimeoutMs,
                body: body
            )
            telemetryQueue.removeFirst(batch.count)
        } catch {
            // Keep events queued for a later attempt.
        }
    }

    private func dedupeExposureEvents(in events: [[String: Any]]) -> [[String: Any]] {
        var seenExposureKeys = Set<String>()
        var output: [[String: Any]] = []
        output.reserveCapacity(events.count)

        for event in events {
            guard (event["name"] as? String) == "truflag.system.exposure" else {
                output.append(event)
                continue
            }
            guard let properties = event["properties"] as? [String: Any] else {
                output.append(event)
                continue
            }
            let key = [
                event["userId"] as? String ?? "",
                event["anonymousId"] as? String ?? "",
                properties["flagKey"] as? String ?? "",
                properties["variationId"] as? String ?? "",
                properties["assignmentId"] as? String ?? "",
            ].joined(separator: "|")
            if seenExposureKeys.contains(key) {
                continue
            }
            seenExposureKeys.insert(key)
            output.append(event)
        }

        return output
    }

    private func enqueueExposure(flag: TruflagFlag, extraProperties: [String: Any]? = nil) {
        let payload = normalizedPayload(flag.payload)
        let identity = buildExposureIdentity(flag: flag, payload: payload)
        if exposureIdentityByFlag[flag.key] == identity {
            return
        }
        if hasQueuedExposure(flagKey: flag.key, payload: payload) {
            exposureIdentityByFlag[flag.key] = identity
            return
        }
        exposureIdentityByFlag[flag.key] = identity

        let experimentId = payload["experimentId"] as? String
        let experimentArmId = payload["experimentArmId"] as? String
        let assignmentId = payload["assignmentId"] as? String
        let includeExperimentFields =
            !(experimentId ?? "").isEmpty &&
            !(experimentArmId ?? "").isEmpty &&
            !(assignmentId ?? "").isEmpty

        var properties: [String: Any] = [
            "sdkSource": "ios",
            "flagKey": flag.key,
            "source": "sdk",
        ]
        if let variationId = payload["variationId"] as? String, !variationId.isEmpty {
            properties["variationId"] = variationId
        }
        if let configVersion = payload["configVersion"] as? String, !configVersion.isEmpty {
            properties["configVersion"] = configVersion
        }
        if let reason = payload["reason"] as? String, !reason.isEmpty {
            properties["reason"] = reason
        }
        if let rolloutId = payload["rolloutId"] as? String, !rolloutId.isEmpty {
            properties["rolloutId"] = rolloutId
        }
        if let rolloutStepIndex = payload["rolloutStepIndex"] as? Int {
            properties["rolloutStepIndex"] = rolloutStepIndex
        }
        if let rolloutReason = payload["rolloutReason"] as? String, !rolloutReason.isEmpty {
            properties["rolloutReason"] = rolloutReason
        }
        if includeExperimentFields {
            properties["experimentId"] = experimentId
            properties["experimentArmId"] = experimentArmId
            properties["assignmentId"] = assignmentId
        }
        if let extraProperties {
            for (key, value) in extraProperties {
                properties[key] = value
            }
        }

        var event: [String: Any] = [
            "name": "truflag.system.exposure",
            "timestamp": iso8601Now(),
            "properties": properties,
        ]
        if let currentUser = user {
            event["userId"] = currentUser.id
            if let attrs = currentUser.attributes {
                event["userAttributes"] = attrs.mapValues { $0.value }
            }
        }
        if let anonymousId = storage.getItem(storageKeys.anonymousId) {
            event["anonymousId"] = anonymousId
        }

        enqueueTelemetryEvent(event)
    }

    private func hasQueuedExposure(flagKey: String, payload: [String: Any]) -> Bool {
        let targetVariation = payload["variationId"] as? String
        let targetAssignment = payload["assignmentId"] as? String
        let currentUserID = user?.id
        let currentAnonymousID = storage.getItem(storageKeys.anonymousId)

        return telemetryQueue.contains { event in
            guard (event["name"] as? String) == "truflag.system.exposure" else { return false }
            guard (event["userId"] as? String) == currentUserID else { return false }
            guard (event["anonymousId"] as? String) == currentAnonymousID else { return false }
            guard let properties = event["properties"] as? [String: Any] else { return false }
            guard (properties["flagKey"] as? String) == flagKey else { return false }
            let variation = properties["variationId"] as? String
            let assignment = properties["assignmentId"] as? String
            return variation == targetVariation && assignment == targetAssignment
        }
    }

    private func normalizedPayload(_ payload: [String: AnyCodable]?) -> [String: Any] {
        guard let payload else { return [:] }
        return payload.mapValues { $0.value }
    }

    private func buildExposureIdentity(flag: TruflagFlag, payload: [String: Any]) -> String {
        let assignmentID = payload["assignmentId"] as? String ?? ""
        let variationID = payload["variationId"] as? String ?? ""
        return [
            "exposure",
            "flag=\(flag.key)",
            "assignment=\(assignmentID)",
            "variation=\(variationID)",
        ].joined(separator: "|")
    }

    private func fingerprintTelemetryValue(_ value: Any) -> String {
        let serialized = serializeTelemetryValue(value)
        var hash: UInt32 = 2166136261
        for scalar in serialized.unicodeScalars {
            hash ^= UInt32(scalar.value)
            hash = hash &* 16777619
        }
        return "\(serialized.count):\(String(hash, radix: 16))"
    }

    private func serializeTelemetryValue(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if let string = value as? String {
            return "\"\(string)\""
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if let bool = value as? Bool {
            return bool ? "true" : "false"
        }
        if let array = value as? [Any] {
            return "[\(array.map { serializeTelemetryValue($0) }.joined(separator: ","))]"
        }
        if let object = value as? [String: Any] {
            let encodedPairs = object.keys.sorted().map { key in
                let encodedKey = "\"\(key)\""
                let encodedValue = serializeTelemetryValue(object[key] as Any)
                return "\(encodedKey):\(encodedValue)"
            }
            return "{\(encodedPairs.joined(separator: ","))}"
        }
        return String(describing: value)
    }

    private func withRetry<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 0..<Defaults.retryAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                if attempt == Defaults.retryAttempts - 1 {
                    break
                }
                let delay = computeRetryDelay(attempt: attempt)
                try await Task.sleep(nanoseconds: delay * 1_000_000)
            }
        }
        throw lastError ?? TruflagError.networkFailed
    }

    private func computeRetryDelay(attempt: Int) -> UInt64 {
        let exponential = min(
            Defaults.retryBaseDelayMs * UInt64(1 << attempt),
            Defaults.retryMaxDelayMs
        )
        let jitter = UInt64(Double(exponential) * Defaults.retryJitterRatio * Double.random(in: 0...1))
        return exponential + jitter
    }

    private func buildConfigureSignature(_ options: TruflagConfigureOptions) -> String {
        let attrs = options.user?.attributes ?? [:]
        let normalizedAttrs = attrs.keys.sorted().map { key in
            "\(key):\(String(describing: attrs[key]?.value))"
        }
        return [
            "apiKey=\(options.apiKey)",
            "baseURL=\(options.baseURL.absoluteString)",
            "userID=\(options.user?.id ?? "")",
            "attrs=\(normalizedAttrs.joined(separator: ","))",
            "requestTimeoutMs=\(options.requestTimeoutMs)",
            "cacheTtlMs=\(options.cacheTtlMs)",
            "telemetryFlushIntervalMs=\(options.telemetryFlushIntervalMs)",
            "telemetryBatchSize=\(options.telemetryBatchSize)",
            "telemetryEnabled=\(options.telemetryEnabled)",
        ].joined(separator: "|")
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

    private func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

public enum TruflagError: Error, Equatable {
    case invalidApiKey
    case notConfigured
    case invalidURL
    case serializationFailed
    case networkFailed
    case httpError(statusCode: Int)
    case blockedAttributeKeys([String])
}

private func withTimeout<T>(promise: @escaping @Sendable () async throws -> T, timeoutMs: Int, message: String) async throws -> T {
    let timeoutTask = Task<T, Error> {
        try await Task.sleep(nanoseconds: UInt64(max(1, timeoutMs)) * 1_000_000)
        throw NSError(domain: "TruflagTimeout", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    let workTask = Task<T, Error> {
        try await promise()
    }

    defer {
        timeoutTask.cancel()
        workTask.cancel()
    }

    return try await withTaskCancellationHandler(operation: {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await timeoutTask.value }
            group.addTask { try await workTask.value }
            guard let first = try await group.next() else {
                throw NSError(domain: "TruflagTimeout", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
            group.cancelAll()
            return first
        }
    }, onCancel: {
        timeoutTask.cancel()
        workTask.cancel()
    })
}
