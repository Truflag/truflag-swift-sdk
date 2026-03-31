import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import TruflagSDK

final class TruflagClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocolMock.reset()
    }

    func testConfigureFetchesFlagsAndReadsTypedValue() async throws {
        let session = makeSession()
        URLProtocolMock.handler = { request in
            guard let url = request.url else {
                return (500, Data())
            }
            if url.path.contains("/config/client-side-id=") {
                return (200, Data("{\"version\":\"v1\"}".utf8))
            }
            if url.path == "/v1/flags" {
                return (
                    200,
                    Data(
                        "{\"flags\":[{\"key\":\"new-checkout\",\"value\":true,\"payload\":{\"reason\":\"targeting\"}}],\"meta\":{\"configVersion\":\"v1\"}}".utf8
                    )
                )
            }
            return (404, Data())
        }

        let client = TruflagClient(storage: MemoryStorage(), session: session)
        try await client.configure(TruflagConfigureOptions(apiKey: "env_c_test"))

        let value: Bool = await client.getFlag("new-checkout", defaultValue: false)
        let ready = await client.isReady()
        XCTAssertTrue(value)
        XCTAssertTrue(ready)
        await client.destroy()
    }

    func testRefreshRetriesWithBypassForStaleConfig() async throws {
        var flagCalls = 0
        let session = makeSession()
        URLProtocolMock.handler = { request in
            guard let url = request.url else {
                return (500, Data())
            }
            if url.path.contains("/config/client-side-id=") {
                return (200, Data("{\"version\":\"v2\"}".utf8))
            }
            if url.path == "/v1/flags" {
                flagCalls += 1
                if flagCalls == 1 {
                    return (
                        200,
                        Data(
                            "{\"flags\":[],\"meta\":{\"configVersion\":\"stale\",\"staleConfig\":true}}".utf8
                        )
                    )
                }
                return (
                    200,
                    Data(
                        "{\"flags\":[{\"key\":\"new-checkout\",\"value\":false}],\"meta\":{\"configVersion\":\"v2\"}}".utf8
                    )
                )
            }
            return (404, Data())
        }

        let client = TruflagClient(storage: MemoryStorage(), session: session)
        try await client.configure(TruflagConfigureOptions(apiKey: "env_c_test"))

        XCTAssertEqual(flagCalls, 2)
        let value: Bool = await client.getFlag("new-checkout", defaultValue: true)
        XCTAssertFalse(value)
        await client.destroy()
    }

    func testTrackSendsBatch() async throws {
        var sawEventsBatch = false
        let session = makeSession()
        URLProtocolMock.handler = { request in
            guard let url = request.url else {
                return (500, Data())
            }
            if url.path.contains("/config/client-side-id=") {
                return (200, Data("{\"version\":\"v1\"}".utf8))
            }
            if url.path == "/v1/flags" {
                return (
                    200,
                    Data("{\"flags\":[{\"key\":\"new-checkout\",\"value\":true}],\"meta\":{\"configVersion\":\"v1\"}}".utf8)
                )
            }
            if url.path == "/v1/events/batch" {
                if let body = request.httpBody,
                   let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                   object["events"] != nil {
                    sawEventsBatch = true
                }
                return (202, Data("{\"accepted\":1}".utf8))
            }
            return (404, Data())
        }

        let client = TruflagClient(storage: MemoryStorage(), session: session)
        try await client.configure(TruflagConfigureOptions(apiKey: "env_c_test", telemetryBatchSize: 1))
        try await client.track(eventName: "checkout_completed", properties: ["value": AnyCodable(1)])

        XCTAssertTrue(sawEventsBatch)
        await client.destroy()
    }

    func testGetFlagReturnsCallerFallbackWhenMissingOrTypeMismatch() async throws {
        let session = makeSession()
        URLProtocolMock.handler = { request in
            guard let url = request.url else {
                return (500, Data())
            }
            if url.path.contains("/config/client-side-id=") {
                return (200, Data("{\"version\":\"v1\"}".utf8))
            }
            if url.path == "/v1/flags" {
                return (
                    200,
                    Data("{\"flags\":[{\"key\":\"numeric-flag\",\"value\":2}],\"meta\":{\"configVersion\":\"v1\"}}".utf8)
                )
            }
            return (404, Data())
        }

        let client = TruflagClient(storage: MemoryStorage(), session: session)
        try await client.configure(TruflagConfigureOptions(apiKey: "env_c_test"))

        let missing: Bool = await client.getFlag("missing-flag", defaultValue: false)
        let typeMismatch: String = await client.getFlag("numeric-flag", defaultValue: "fallback")

        XCTAssertFalse(missing)
        XCTAssertEqual(typeMismatch, "fallback")
        await client.destroy()
    }

    func testRefreshFailureKeepsPreviouslyLoadedFlags() async throws {
        var shouldFailRefresh = false
        let session = makeSession()
        URLProtocolMock.handler = { request in
            guard let url = request.url else {
                return (500, Data())
            }
            if url.path.contains("/config/client-side-id=") {
                return (200, Data("{\"version\":\"v1\"}".utf8))
            }
            if url.path == "/v1/flags" {
                if shouldFailRefresh {
                    return (500, Data("{\"error\":\"boom\"}".utf8))
                }
                return (
                    200,
                    Data("{\"flags\":[{\"key\":\"new-checkout\",\"value\":true}],\"meta\":{\"configVersion\":\"v1\"}}".utf8)
                )
            }
            return (404, Data())
        }

        let client = TruflagClient(storage: MemoryStorage(), session: session)
        try await client.configure(TruflagConfigureOptions(apiKey: "env_c_test"))

        shouldFailRefresh = true
        do {
            try await client.refresh()
            XCTFail("Expected refresh to fail")
        } catch {
            // expected
        }

        let stillAvailable: Bool = await client.getFlag("new-checkout", defaultValue: false)
        XCTAssertTrue(stillAvailable)
        await client.destroy()
    }

    func testExposeSendsExposureEventPayload() async throws {
        var receivedExposureEvent = false
        let session = makeSession()
        URLProtocolMock.handler = { request in
            guard let url = request.url else {
                return (500, Data())
            }
            if url.path.contains("/config/client-side-id=") {
                return (200, Data("{\"version\":\"v1\"}".utf8))
            }
            if url.path == "/v1/flags" {
                return (
                    200,
                    Data(
                        "{\"flags\":[{\"key\":\"economyvariation\",\"value\":\"coins\",\"payload\":{\"reason\":\"experimentArm\",\"variationId\":\"var_1\"}}],\"meta\":{\"configVersion\":\"v1\"}}".utf8
                    )
                )
            }
            if url.path == "/v1/events/batch" {
                if let body = request.httpBody,
                   let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                   let events = object["events"] as? [[String: Any]],
                   let first = events.first,
                   first["name"] as? String == "truflag.system.exposure",
                   let properties = first["properties"] as? [String: Any],
                   properties["flagKey"] as? String == "economyvariation",
                   properties["reason"] as? String == "experimentArm" {
                    receivedExposureEvent = true
                }
                return (202, Data("{\"accepted\":1}".utf8))
            }
            return (404, Data())
        }

        let client = TruflagClient(storage: MemoryStorage(), session: session)
        try await client.configure(TruflagConfigureOptions(apiKey: "env_c_test", telemetryBatchSize: 1))
        try await client.expose(flagKey: "economyvariation")

        XCTAssertTrue(receivedExposureEvent)
        await client.destroy()
    }

    func testConfigureDedupesSameInFlightOptions() async throws {
        var flagsRequests = 0
        let session = makeSession()
        URLProtocolMock.handler = { request in
            guard let url = request.url else { return (500, Data()) }
            if url.path.contains("/config/client-side-id=") {
                return (200, Data("{\"version\":\"v1\"}".utf8))
            }
            if url.path == "/v1/flags" {
                flagsRequests += 1
                return (200, Data("{\"flags\":[],\"meta\":{\"configVersion\":\"v1\"}}".utf8))
            }
            return (404, Data())
        }

        let client = TruflagClient(storage: MemoryStorage(), session: session)
        async let first: Void = client.configure(TruflagConfigureOptions(apiKey: "env_c_test"))
        async let second: Void = client.configure(TruflagConfigureOptions(apiKey: "env_c_test"))
        _ = try await (first, second)

        XCTAssertEqual(flagsRequests, 1)
        await client.destroy()
    }

    func testBlockedAttributeKeysRejected() async throws {
        let session = makeSession()
        URLProtocolMock.handler = { request in
            guard let url = request.url else { return (500, Data()) }
            if url.path.contains("/config/client-side-id=") {
                return (200, Data("{\"version\":\"v1\"}".utf8))
            }
            if url.path == "/v1/flags" {
                return (200, Data("{\"flags\":[],\"meta\":{\"configVersion\":\"v1\"}}".utf8))
            }
            return (404, Data())
        }

        let client = TruflagClient(storage: MemoryStorage(), session: session)
        await XCTAssertThrowsErrorAsync {
            try await client.configure(
                TruflagConfigureOptions(
                    apiKey: "env_c_test",
                    user: TruflagUser(id: "u1", attributes: ["id": AnyCodable("not-allowed")])
                )
            )
        } errorHandler: { error in
            guard case TruflagError.blockedAttributeKeys(let keys) = error else {
                XCTFail("Expected blockedAttributeKeys error")
                return
            }
            XCTAssertEqual(keys, ["id"])
        }
        await client.destroy()
    }

    func testCachedSnapshotWarmStartAvailableOnRefreshFailure() async throws {
        let storage = MemoryStorage()
        let seedSession = makeSession()
        URLProtocolMock.handler = { request in
            guard let url = request.url else { return (500, Data()) }
            if url.path.contains("/config/client-side-id=") {
                return (200, Data("{\"version\":\"v1\"}".utf8))
            }
            if url.path == "/v1/flags" {
                return (200, Data("{\"flags\":[{\"key\":\"new-checkout\",\"value\":true}],\"meta\":{\"configVersion\":\"v1\"}}".utf8))
            }
            return (404, Data())
        }

        let seedClient = TruflagClient(storage: storage, session: seedSession)
        try await seedClient.configure(TruflagConfigureOptions(apiKey: "env_c_test"))
        let seededValue: Bool = await seedClient.getFlag("new-checkout", defaultValue: false)
        XCTAssertTrue(seededValue)
        await seedClient.destroy()

        let failSession = makeSession()
        URLProtocolMock.handler = { request in
            guard let url = request.url else { return (500, Data()) }
            if url.path.contains("/config/client-side-id=") {
                return (200, Data("{\"version\":\"v1\"}".utf8))
            }
            return (500, Data("{\"error\":\"down\"}".utf8))
        }

        let failClient = TruflagClient(storage: storage, session: failSession)
        do {
            try await failClient.configure(TruflagConfigureOptions(apiKey: "env_c_test"))
            XCTFail("Expected configure to fail when refresh fails")
        } catch {
            // expected
        }

        let warmValue: Bool = await failClient.getFlag("new-checkout", defaultValue: false)
        let ready = await failClient.isReady()
        XCTAssertTrue(ready)
        XCTAssertTrue(warmValue)
        await failClient.destroy()
    }

    func testRefreshQueueDrainsPendingExpectedVersions() async throws {
        var expectedVersions: [String?] = []
        let session = makeSession()
        URLProtocolMock.handler = { request in
            guard let url = request.url else { return (500, Data()) }
            if url.path.contains("/config/client-side-id=") {
                return (200, Data("{\"version\":\"v1\"}".utf8))
            }
            if url.path == "/v1/flags" {
                let expected = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "expectedConfigVersion" })?
                    .value
                expectedVersions.append(expected)
                let configVersion = expected ?? "v1"
                return (200, Data("{\"flags\":[],\"meta\":{\"configVersion\":\"\(configVersion)\"}}".utf8))
            }
            return (404, Data())
        }

        let client = TruflagClient(storage: MemoryStorage(), session: session)
        try await client.configure(TruflagConfigureOptions(apiKey: "env_c_test"))

        async let first: Void = client.refresh(expectedConfigVersion: "v2")
        async let second: Void = client.refresh(expectedConfigVersion: "v3")
        _ = try await (first, second)

        XCTAssertGreaterThanOrEqual(expectedVersions.count, 2)
        XCTAssertEqual(expectedVersions.first, "v1")
        let drained = Array(expectedVersions.dropFirst())
        let drainedSet = Set(drained.compactMap { $0 })
        XCTAssertFalse(drainedSet.isEmpty)
        XCTAssertTrue(drainedSet.isSubset(of: Set(["v2", "v3"])))
        await client.destroy()
    }

    func testReadExposureDedupesForSameAssignmentIdentity() async throws {
        var exposureCount = 0
        let session = makeSession()
        URLProtocolMock.handler = { request in
            guard let url = request.url else { return (500, Data()) }
            if url.path.contains("/config/client-side-id=") {
                return (200, Data("{\"version\":\"v1\"}".utf8))
            }
            if url.path == "/v1/flags" {
                return (
                    200,
                    Data("{\"flags\":[{\"key\":\"new-checkout\",\"value\":true,\"payload\":{\"variationId\":\"var_1\",\"assignmentId\":\"assign_1\",\"reason\":\"targeting\"}}],\"meta\":{\"configVersion\":\"v1\"}}".utf8)
                )
            }
            if url.path == "/v1/events/batch" {
                if let body = request.httpBody,
                   let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                   let events = object["events"] as? [[String: Any]] {
                    exposureCount += events.filter { $0["name"] as? String == "truflag.system.exposure" }.count
                }
                return (202, Data("{\"accepted\":1}".utf8))
            }
            return (404, Data())
        }

        let client = TruflagClient(storage: MemoryStorage(), session: session)
        try await client.configure(TruflagConfigureOptions(apiKey: "env_c_test", telemetryFlushIntervalMs: 60_000_000, telemetryBatchSize: 1))
        let _: Bool = await client.getFlag("new-checkout", defaultValue: false)
        let _: Bool = await client.getFlag("new-checkout", defaultValue: false)
        try await client.track(eventName: "flush_queue")

        XCTAssertEqual(exposureCount, 1)
        await client.destroy()
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolMock.self]
        return URLSession(configuration: config)
    }
}

private final class MemoryStorage: TruflagStorage {
    private var map: [String: String] = [:]

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

private final class URLProtocolMock: URLProtocol {
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
        guard let handler = URLProtocolMock.handler else {
            fatalError("URLProtocolMock.handler not set")
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

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    errorHandler: (_ error: Error) -> Void = { _ in }
) async {
    do {
        try await expression()
        XCTFail(message(), file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
