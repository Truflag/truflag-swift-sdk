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

        let client = TruflagClient(
            storage: MemoryStorage(),
            session: session
        )
        try await client.configure(TruflagConfigureOptions(apiKey: "env_c_test"))

        let value: Bool = await client.getFlag("new-checkout", defaultValue: false)
        let ready = await client.isReady()
        XCTAssertTrue(value)
        XCTAssertTrue(ready)
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
        try await client.configure(TruflagConfigureOptions(apiKey: "env_c_test"))
        try await client.track(eventName: "checkout_completed", properties: ["value": AnyCodable(1)])

        XCTAssertTrue(sawEventsBatch)
    }

    func testTrackAttachesExperimentContextsAndStripsLegacyExperimentScalarFields() async throws {
        var capturedProperties: [String: Any]?
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
                        """
                        {
                          "flags":[
                            {
                              "key":"paywall-copy",
                              "value":"v1",
                              "payload":{
                                "experimentId":"exp-paywall",
                                "experimentArmId":"arm-a",
                                "assignmentId":"assign-a",
                                "variationId":"var-a"
                              }
                            },
                            {
                              "key":"discount-level",
                              "value":50,
                              "payload":{
                                "experimentId":"exp-discount",
                                "experimentArmId":"arm-b",
                                "assignmentId":"assign-b",
                                "variationId":"var-b"
                              }
                            }
                          ],
                          "meta":{"configVersion":"v1"}
                        }
                        """.utf8
                    )
                )
            }
            if url.path == "/v1/events/batch" {
                if let body = request.httpBody,
                   let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                   let events = object["events"] as? [[String: Any]],
                   let first = events.first,
                   let properties = first["properties"] as? [String: Any] {
                    capturedProperties = properties
                }
                return (202, Data("{\"accepted\":1}".utf8))
            }
            return (404, Data())
        }

        let client = TruflagClient(storage: MemoryStorage(), session: session)
        try await client.configure(TruflagConfigureOptions(apiKey: "env_c_test"))
        try await client.track(
            eventName: "checkout_completed",
            properties: [
                "value": AnyCodable(1),
                "experimentId": AnyCodable("legacy-exp"),
                "experimentArmId": AnyCodable("legacy-arm"),
                "armId": AnyCodable("legacy-arm"),
                "assignmentId": AnyCodable("legacy-assignment"),
                "flagKey": AnyCodable("legacy-flag"),
                "variationId": AnyCodable("legacy-var"),
            ],
            immediate: true
        )

        guard let properties = capturedProperties else {
            XCTFail("Expected /v1/events/batch payload")
            return
        }
        XCTAssertNil(properties["experimentId"])
        XCTAssertNil(properties["experimentArmId"])
        XCTAssertNil(properties["armId"])
        XCTAssertNil(properties["assignmentId"])
        XCTAssertNil(properties["flagKey"])
        XCTAssertNil(properties["variationId"])
        XCTAssertEqual(properties["attributionVersion"] as? String, "2")
        guard let contexts = properties["experimentContexts"] as? [[String: Any]] else {
            XCTFail("Expected experimentContexts on tracked event")
            return
        }
        XCTAssertEqual(contexts.count, 2)
        let byExperiment = Dictionary(
            uniqueKeysWithValues: contexts.map { context in
                ((context["experimentId"] as? String) ?? "", context)
            }
        )
        XCTAssertEqual(byExperiment["exp-paywall"]?["armId"] as? String, "arm-a")
        XCTAssertEqual(byExperiment["exp-discount"]?["armId"] as? String, "arm-b")
    }

    func testTrackImmediateFlushesEvenWhenBelowBatchSize() async throws {
        var eventsBatchCalls = 0
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
                eventsBatchCalls += 1
                return (202, Data("{\"accepted\":1}".utf8))
            }
            return (404, Data())
        }

        let client = TruflagClient(storage: MemoryStorage(), session: session)
        try await client.configure(
            TruflagConfigureOptions(
                apiKey: "env_c_test",
                telemetryBatchSize: 50,
                telemetryFlushIntervalMs: 60_000_000
            )
        )

        try await client.track(
            eventName: "checkout_completed",
            properties: ["value": AnyCodable(1)],
            immediate: true
        )

        XCTAssertEqual(eventsBatchCalls, 1)
    }

    func testGetFlagReturnsMissingFallbackAndRawValueForTypeMismatch() async throws {
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
        let typeMismatch: Any = await client.getFlag("numeric-flag", defaultValue: "fallback" as Any)

        XCTAssertFalse(missing)
        XCTAssertEqual(typeMismatch as? Int, 2)
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
        try await client.refresh()

        let stillAvailable: Bool = await client.getFlag("new-checkout", defaultValue: false)
        XCTAssertTrue(stillAvailable)
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
        try await client.configure(TruflagConfigureOptions(apiKey: "env_c_test"))
        try await client.expose(flagKey: "economyvariation")

        XCTAssertTrue(receivedExposureEvent)
    }

    func testExposeThrowsWhenFlagMissing() async throws {
        let session = makeSession()
        URLProtocolMock.handler = { request in
            guard let url = request.url else {
                return (500, Data())
            }
            if url.path.contains("/config/client-side-id=") {
                return (200, Data("{\"version\":\"v1\"}".utf8))
            }
            if url.path == "/v1/flags" {
                return (200, Data("{\"flags\":[],\"meta\":{\"configVersion\":\"v1\"}}".utf8))
            }
            return (404, Data())
        }

        let client = TruflagClient(storage: MemoryStorage(), session: session)
        try await client.configure(TruflagConfigureOptions(apiKey: "env_c_test"))

        do {
            try await client.expose(flagKey: "missing-flag")
            XCTFail("Expected expose to throw for missing flag")
        } catch let error as TruflagError {
            XCTAssertEqual(error, .missingFlag("missing-flag"))
        }
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolMock.self]
        return URLSession(configuration: config)
    }
}

private final class MemoryStorage: TruflagStorage, @unchecked Sendable {
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
