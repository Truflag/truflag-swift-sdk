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
