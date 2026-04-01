import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import TruflagSDK

final class TruflagClientTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        URLProtocolMock.reset()
    }

    override func setUp() {
        super.setUp()
        URLProtocolMock.reset()
    }

    func testConfigureFetchesFlagsAndReadsTypedValue() async throws {
        let session = makeSession()
        let baseURL = makeBaseURL()
        URLProtocolMock.setHandler(for: baseURL) { request in
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

        let client = TruflagClient(
            storage: MemoryStorage(),
            session: session
        )
        try await client.configure(
            TruflagConfigureOptions(
                apiKey: "env_c_test",
                baseURL: baseURL,
                streamEnabled: false
            )
        )

        let value: Bool = await client.getFlag("new-checkout", defaultValue: false)
        let ready = await client.isReady()
        XCTAssertTrue(value)
        XCTAssertTrue(ready)
    }

    func testRefreshRetriesWithBypassForStaleConfig() async throws {
        var flagCalls = 0
        let session = makeSession()
        let baseURL = makeBaseURL()
        URLProtocolMock.setHandler(for: baseURL) { request in
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
        try await client.configure(
            TruflagConfigureOptions(
                apiKey: "env_c_test",
                baseURL: baseURL,
                streamEnabled: false
            )
        )

        XCTAssertEqual(flagCalls, 2)
        let value: Bool = await client.getFlag("new-checkout", defaultValue: true)
        XCTAssertFalse(value)
    }

    func testTrackSendsBatch() async throws {
        let eventsBatchExpectation = expectation(description: "events batch posted")
        let session = makeSession()
        let baseURL = makeBaseURL()
        URLProtocolMock.setHandler(for: baseURL) { request in
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
                    eventsBatchExpectation.fulfill()
                }
                return (202, Data("{\"accepted\":1}".utf8))
            }
            return (404, Data())
        }

        let client = TruflagClient(storage: MemoryStorage(), session: session)
        try await client.configure(
            TruflagConfigureOptions(
                apiKey: "env_c_test",
                baseURL: baseURL,
                streamEnabled: false,
                telemetryBatchSize: 1
            )
        )
        try await client.track(eventName: "checkout_completed", properties: ["value": AnyCodable(1)])
        await fulfillment(of: [eventsBatchExpectation], timeout: 1.0)
    }

    func testTrackImmediateFlushesEvenWhenBelowBatchSize() async throws {
        var eventsBatchCalls = 0
        let session = makeSession()
        let baseURL = makeBaseURL()
        URLProtocolMock.setHandler(for: baseURL) { request in
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
                eventsBatchCalls += 1
                return (202, Data("{\"accepted\":1}".utf8))
            }
            return (404, Data())
        }

        let client = TruflagClient(storage: MemoryStorage(), session: session)
        try await client.configure(
            TruflagConfigureOptions(
                apiKey: "env_c_test",
                baseURL: baseURL,
                streamEnabled: false,
                telemetryFlushIntervalMs: 60_000_000,
                telemetryBatchSize: 50
            )
        )

        try await client.track(
            eventName: "checkout_completed",
            properties: ["value": AnyCodable(1)],
            immediate: true
        )

        XCTAssertEqual(eventsBatchCalls, 1)
    }

    func testGetFlagReturnsCallerFallbackWhenMissingOrTypeMismatch() async throws {
        let session = makeSession()
        let baseURL = makeBaseURL()
        URLProtocolMock.setHandler(for: baseURL) { request in
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
        try await client.configure(
            TruflagConfigureOptions(
                apiKey: "env_c_test",
                baseURL: baseURL,
                streamEnabled: false
            )
        )

        let missing: Bool = await client.getFlag("missing-flag", defaultValue: false)
        let typeMismatch: String = await client.getFlag("numeric-flag", defaultValue: "fallback")

        XCTAssertFalse(missing)
        XCTAssertEqual(typeMismatch, "fallback")
    }

    func testRefreshFailureKeepsPreviouslyLoadedFlags() async throws {
        var shouldFailRefresh = false
        let session = makeSession()
        let baseURL = makeBaseURL()
        URLProtocolMock.setHandler(for: baseURL) { request in
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
        try await client.configure(
            TruflagConfigureOptions(
                apiKey: "env_c_test",
                baseURL: baseURL,
                streamEnabled: false
            )
        )

        shouldFailRefresh = true
        do {
            try await client.refresh()
            XCTFail("Expected refresh to fail")
        } catch {
            // expected
        }

        let stillAvailable: Bool = await client.getFlag("new-checkout", defaultValue: false)
        XCTAssertTrue(stillAvailable)
    }

    func testExposeSendsExposureEventPayload() async throws {
        let exposureEventExpectation = expectation(description: "exposure event posted")
        let session = makeSession()
        let baseURL = makeBaseURL()
        URLProtocolMock.setHandler(for: baseURL) { request in
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
                    exposureEventExpectation.fulfill()
                }
                return (202, Data("{\"accepted\":1}".utf8))
            }
            return (404, Data())
        }

        let client = TruflagClient(storage: MemoryStorage(), session: session)
        try await client.configure(
            TruflagConfigureOptions(
                apiKey: "env_c_test",
                baseURL: baseURL,
                streamEnabled: false,
                telemetryBatchSize: 1
            )
        )
        try await client.expose(flagKey: "economyvariation")
        await fulfillment(of: [exposureEventExpectation], timeout: 1.0)
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolMock.self]
        return URLSession(configuration: config)
    }

    private func makeBaseURL() -> URL {
        URL(string: "https://\(UUID().uuidString.lowercased()).test")!
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
    private static let lock = NSLock()
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var handlersByHost: [String: (URLRequest) -> (Int, Data)] = [:]

    static func setHandler(for baseURL: URL, handler: @escaping (URLRequest) -> (Int, Data)) {
        guard let host = baseURL.host else { return }
        lock.lock()
        self.handler = handler
        handlersByHost[host] = handler
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        handler = nil
        handlersByHost = [:]
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let selectedHandler: ((URLRequest) -> (Int, Data))? = {
            let host = request.url?.host
            URLProtocolMock.lock.lock()
            defer { URLProtocolMock.lock.unlock() }
            if let host, let scoped = URLProtocolMock.handlersByHost[host] {
                return scoped
            }
            return URLProtocolMock.handler
        }()

        let (statusCode, data): (Int, Data)
        if let handler = selectedHandler {
            (statusCode, data) = handler(request)
        } else {
            // Do not crash tests when an unexpected host/request leaks through.
            (statusCode, data) = (404, Data())
        }
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
