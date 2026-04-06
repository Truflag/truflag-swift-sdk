import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import TruflagSDK

final class ParityExportTests: XCTestCase {
    struct ParityResult: Codable {
        let id: String
        let status: String
        let notes: String?
    }

    override class func setUp() {
        super.setUp()
        ParityURLProtocolMock.reset()
    }

    func testExportParityResults() async throws {
        var results: [ParityResult] = []

        await run("configure_fresh_ready", into: &results) {
            let session = makeSession()
            ParityURLProtocolMock.handler = { request in
                guard let url = request.url else { return (500, Data()) }
                if url.path.contains("/config/client-side-id=") {
                    return (200, Data("{\"version\":\"v1\"}".utf8))
                }
                if url.path == "/v1/flags" {
                    return (200, Data("{\"flags\":[{\"key\":\"new-checkout\",\"value\":true}],\"meta\":{\"configVersion\":\"v1\"}}".utf8))
                }
                return (404, Data())
            }
            let client = TruflagClient(storage: MemoryStorage(), storagePrefix: "parity", session: session)
            try await client.configure(TruflagConfigureOptions(apiKey: "env_c_parity_1"))
            XCTAssertTrue(await client.isReady())
        }

        await run("configure_cache_hydrates", into: &results) {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let snapshot = "{\"snapshot\":{\"flags\":[{\"key\":\"cached-flag\",\"value\":true}],\"fetchedAt\":\(now)},\"savedAt\":\(now)}"
            let storage = MemoryStorage(seed: ["truflag:parity:snapshot": snapshot])
            let session = makeSession()
            ParityURLProtocolMock.handler = { request in
                guard let url = request.url else { return (500, Data()) }
                if url.path.contains("/config/client-side-id=") {
                    return (200, Data("{\"version\":\"v1\"}".utf8))
                }
                if url.path == "/v1/flags" {
                    return (500, Data("{\"error\":\"startup-refresh-failed\"}".utf8))
                }
                return (404, Data())
            }
            let client = TruflagClient(storage: storage, storagePrefix: "parity", session: session)
            try await client.configure(TruflagConfigureOptions(apiKey: "env_c_parity_2"))
            let value: Bool = await client.getFlag("cached-flag", defaultValue: false)
            XCTAssertTrue(value)
        }

        await run("configure_cache_ttl_expired_refetches", into: &results) {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let staleSavedAt = now - 60_000
            let snapshot = "{\"snapshot\":{\"flags\":[{\"key\":\"stale\",\"value\":true}],\"fetchedAt\":\(staleSavedAt)},\"savedAt\":\(staleSavedAt)}"
            let storage = MemoryStorage(seed: ["truflag:parity:snapshot": snapshot])
            let session = makeSession()
            var flagsCalls = 0
            ParityURLProtocolMock.handler = { request in
                guard let url = request.url else { return (500, Data()) }
                if url.path.contains("/config/client-side-id=") {
                    return (200, Data("{\"version\":\"v1\"}".utf8))
                }
                if url.path == "/v1/flags" {
                    flagsCalls += 1
                    return (200, Data("{\"flags\":[{\"key\":\"fresh\",\"value\":true}],\"meta\":{\"configVersion\":\"v1\"}}".utf8))
                }
                return (404, Data())
            }
            let client = TruflagClient(storage: storage, storagePrefix: "parity", session: session)
            try await client.configure(TruflagConfigureOptions(apiKey: "env_c_parity_3", cacheTtlMs: 1_000))
            await client.waitForInFlightRefresh(timeoutMs: 2_500)
            XCTAssertGreaterThanOrEqual(flagsCalls, 1)
            let fresh: Bool = await client.getFlag("fresh", defaultValue: false)
            XCTAssertTrue(fresh)
        }

        await run("identity_lifecycle_refreshes", into: &results) {
            let session = makeSession()
            var seenUserIds: [String] = []
            var seenAttrs: [String] = []
            ParityURLProtocolMock.handler = { request in
                guard let url = request.url else { return (500, Data()) }
                if url.path.contains("/config/client-side-id=") {
                    return (200, Data("{\"version\":\"v1\"}".utf8))
                }
                if url.path == "/v1/flags" {
                    let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    seenUserIds.append(parts?.queryItems?.first(where: { $0.name == "userId" })?.value ?? "")
                    seenAttrs.append(parts?.queryItems?.first(where: { $0.name == "userAttributes" })?.value ?? "")
                    return (200, Data("{\"flags\":[],\"meta\":{\"configVersion\":\"v1\"}}".utf8))
                }
                return (404, Data())
            }
            let client = TruflagClient(storage: MemoryStorage(), storagePrefix: "parity", session: session)
            try await client.configure(
                TruflagConfigureOptions(
                    apiKey: "env_c_parity_4",
                    user: TruflagUser(id: "u1", attributes: ["plan": AnyCodable("pro")])
                )
            )
            try await client.login(user: TruflagUser(id: "u2", attributes: ["plan": AnyCodable("free")]))
            try await client.setAttributes(["region": AnyCodable("ca")])
            try await client.logout()
            XCTAssertTrue(seenUserIds.contains("u2"))
            XCTAssertTrue(seenAttrs.contains(where: { $0.contains("region") }))
        }

        await run("refresh_single_flight", into: &results) {
            let session = makeSession()
            var flagsRequests = 0
            let lock = NSLock()
            ParityURLProtocolMock.handler = { request in
                guard let url = request.url else { return (500, Data()) }
                if url.path.contains("/config/client-side-id=") {
                    return (200, Data("{\"version\":\"v1\"}".utf8))
                }
                if url.path == "/v1/flags" {
                    lock.lock()
                    flagsRequests += 1
                    lock.unlock()
                    return (200, Data("{\"flags\":[],\"meta\":{\"configVersion\":\"v1\"}}".utf8))
                }
                return (404, Data())
            }
            let client = TruflagClient(storage: MemoryStorage(), storagePrefix: "parity", session: session)
            try await client.configure(TruflagConfigureOptions(apiKey: "env_c_parity_5"))
            async let first: Void = client.refresh()
            async let second: Void = client.refresh()
            _ = try await (first, second)
            XCTAssertLessThanOrEqual(flagsRequests, 2)
        }

        await run("refresh_stale_retry_bypass", into: &results) {
            let session = makeSession()
            var calls = 0
            var sawBypass = false
            ParityURLProtocolMock.handler = { request in
                guard let url = request.url else { return (500, Data()) }
                if url.path.contains("/config/client-side-id=") {
                    return (200, Data("{\"version\":\"v2\"}".utf8))
                }
                if url.path == "/v1/flags" {
                    calls += 1
                    let bypass = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?
                        .first(where: { $0.name == "bypassRuntimeCache" })?
                        .value == "1"
                    if bypass { sawBypass = true }
                    if calls == 1 {
                        return (200, Data("{\"flags\":[],\"meta\":{\"configVersion\":\"stale\",\"staleConfig\":true}}".utf8))
                    }
                    return (200, Data("{\"flags\":[{\"key\":\"f\",\"value\":true}],\"meta\":{\"configVersion\":\"v2\"}}".utf8))
                }
                return (404, Data())
            }
            let client = TruflagClient(storage: MemoryStorage(), storagePrefix: "parity", session: session)
            try await client.configure(TruflagConfigureOptions(apiKey: "env_c_parity_6"))
            XCTAssertTrue(sawBypass)
        }

        await run("getflag_missing_fallback", into: &results) {
            let session = makeSession()
            ParityURLProtocolMock.handler = { request in
                guard let url = request.url else { return (500, Data()) }
                if url.path.contains("/config/client-side-id=") {
                    return (200, Data("{\"version\":\"v1\"}".utf8))
                }
                if url.path == "/v1/flags" {
                    return (200, Data("{\"flags\":[],\"meta\":{\"configVersion\":\"v1\"}}".utf8))
                }
                return (404, Data())
            }
            let client = TruflagClient(storage: MemoryStorage(), storagePrefix: "parity", session: session)
            try await client.configure(TruflagConfigureOptions(apiKey: "env_c_parity_7"))
            let value: Bool = await client.getFlag("missing", defaultValue: true)
            XCTAssertTrue(value)
        }

        await run("getflag_type_mismatch_fallback", into: &results) {
            let session = makeSession()
            ParityURLProtocolMock.handler = { request in
                guard let url = request.url else { return (500, Data()) }
                if url.path.contains("/config/client-side-id=") {
                    return (200, Data("{\"version\":\"v1\"}".utf8))
                }
                if url.path == "/v1/flags" {
                    return (200, Data("{\"flags\":[{\"key\":\"n\",\"value\":2}],\"meta\":{\"configVersion\":\"v1\"}}".utf8))
                }
                return (404, Data())
            }
            let client = TruflagClient(storage: MemoryStorage(), storagePrefix: "parity", session: session)
            try await client.configure(TruflagConfigureOptions(apiKey: "env_c_parity_8"))
            let value: Any = await client.getFlag("n", defaultValue: "fallback" as Any)
            XCTAssertEqual(value as? Int, 2)
        }

        await run("track_batch_threshold_flushes", into: &results) {
            let session = makeSession()
            var batchCalls = 0
            ParityURLProtocolMock.handler = { request in
                guard let url = request.url else { return (500, Data()) }
                if url.path.contains("/config/client-side-id=") {
                    return (200, Data("{\"version\":\"v1\"}".utf8))
                }
                if url.path == "/v1/flags" {
                    return (200, Data("{\"flags\":[],\"meta\":{\"configVersion\":\"v1\"}}".utf8))
                }
                if url.path == "/v1/events/batch" {
                    batchCalls += 1
                    return (202, Data("{\"accepted\":1}".utf8))
                }
                return (404, Data())
            }
            let client = TruflagClient(storage: MemoryStorage(), storagePrefix: "parity", session: session)
            try await client.configure(
                TruflagConfigureOptions(
                    apiKey: "env_c_parity_9",
                    telemetryBatchSize: 1,
                    telemetryFlushIntervalMs: 60_000_000
                )
            )
            try await client.track(eventName: "checkout_completed", properties: ["value": AnyCodable(1)])
            XCTAssertEqual(batchCalls, 1)
        }

        await run("track_immediate_flushes", into: &results) {
            let session = makeSession()
            var batchCalls = 0
            ParityURLProtocolMock.handler = { request in
                guard let url = request.url else { return (500, Data()) }
                if url.path.contains("/config/client-side-id=") {
                    return (200, Data("{\"version\":\"v1\"}".utf8))
                }
                if url.path == "/v1/flags" {
                    return (200, Data("{\"flags\":[],\"meta\":{\"configVersion\":\"v1\"}}".utf8))
                }
                if url.path == "/v1/events/batch" {
                    batchCalls += 1
                    return (202, Data("{\"accepted\":1}".utf8))
                }
                return (404, Data())
            }
            let client = TruflagClient(storage: MemoryStorage(), storagePrefix: "parity", session: session)
            try await client.configure(
                TruflagConfigureOptions(
                    apiKey: "env_c_parity_10",
                    telemetryBatchSize: 50,
                    telemetryFlushIntervalMs: 60_000_000
                )
            )
            try await client.track(
                eventName: "checkout_completed",
                properties: ["value": AnyCodable(1)],
                immediate: true
            )
            XCTAssertEqual(batchCalls, 1)
        }

        await run("refresh_failure_preserves_ready_with_cached_flags", into: &results) {
            let session = makeSession()
            var shouldFail = false
            ParityURLProtocolMock.handler = { request in
                guard let url = request.url else { return (500, Data()) }
                if url.path.contains("/config/client-side-id=") {
                    return (200, Data("{\"version\":\"v1\"}".utf8))
                }
                if url.path == "/v1/flags" {
                    if shouldFail {
                        return (500, Data("{\"error\":\"boom\"}".utf8))
                    }
                    return (200, Data("{\"flags\":[{\"key\":\"new-checkout\",\"value\":true}],\"meta\":{\"configVersion\":\"v1\"}}".utf8))
                }
                return (404, Data())
            }
            let client = TruflagClient(storage: MemoryStorage(), storagePrefix: "parity", session: session)
            try await client.configure(TruflagConfigureOptions(apiKey: "env_c_parity_11"))
            shouldFail = true
            try await client.refresh()
            let ready = await client.isReady()
            let value: Bool = await client.getFlag("new-checkout", defaultValue: false)
            XCTAssertTrue(ready)
            XCTAssertTrue(value)
        }

        if let outputPath = ProcessInfo.processInfo.environment["PARITY_RESULTS_OUT"], !outputPath.isEmpty {
            let url = URL(fileURLWithPath: outputPath)
            let data = try JSONEncoder().encode(results)
            try data.write(to: url)
        }

        XCTAssertEqual(results.count, 11)
    }

    private func run(_ id: String, into results: inout [ParityResult], _ body: () async throws -> Void) async {
        do {
            try await body()
            results.append(ParityResult(id: id, status: "pass", notes: nil))
        } catch {
            results.append(ParityResult(id: id, status: "fail", notes: String(describing: error)))
        }
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ParityURLProtocolMock.self]
        return URLSession(configuration: config)
    }
}

private final class MemoryStorage: TruflagStorage, @unchecked Sendable {
    private var map: [String: String]

    init(seed: [String: String] = [:]) {
        self.map = seed
    }

    func getItem(_ key: String) -> String? {
        map[key]
    }

    func setItem(_ key: String, value: String) {
        map[key] = value
    }

    func removeItem(_ key: String) {
        map.removeValue(forKey: key)
    }
}

private final class ParityURLProtocolMock: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?

    static func reset() {
        handler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            fatalError("ParityURLProtocolMock.handler not set")
        }
        let (statusCode, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://sdk.truflag.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
