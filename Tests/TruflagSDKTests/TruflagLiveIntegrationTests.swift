import Foundation
import XCTest
@testable import TruflagSDK

final class TruflagLiveIntegrationTests: XCTestCase {
    func testLiveConfigureAndTrackAgainstRelay() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["TRUFLAG_CLIENT_SIDE_ID"], !apiKey.isEmpty else {
            throw XCTSkip("Missing TRUFLAG_CLIENT_SIDE_ID for live iOS integration test")
        }

        let baseURL = URL(string: ProcessInfo.processInfo.environment["TRUFLAG_BASE_URL"] ?? "https://sdk.truflag.com")!
        let userId = "ios-live-smoke-\(UUID().uuidString.prefix(8))"

        let client = TruflagClient(storagePrefix: "ios_live_smoke")
        try await client.configure(
            TruflagConfigureOptions(
                apiKey: apiKey,
                user: TruflagUser(id: String(userId)),
                baseURL: baseURL,
                requestTimeoutMs: 12000
            )
        )

        let ready = await client.isReady()
        XCTAssertTrue(ready)

        let _: Bool = await client.getFlag("ios_live_smoke_flag", defaultValue: false)
        try await client.track(
            eventName: "ios_live_smoke_opened",
            properties: [
                "source": AnyCodable("swift-test"),
                "sdk": AnyCodable("ios")
            ]
        )
    }
}
