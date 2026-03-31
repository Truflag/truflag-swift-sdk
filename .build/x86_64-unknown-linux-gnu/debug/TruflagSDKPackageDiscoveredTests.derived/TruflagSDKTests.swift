import XCTest
@testable import TruflagSDKTests

fileprivate extension TruflagClientTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__TruflagClientTests = [
        ("testBlockedAttributeKeysRejected", asyncTest(testBlockedAttributeKeysRejected)),
        ("testCachedSnapshotWarmStartAvailableOnRefreshFailure", asyncTest(testCachedSnapshotWarmStartAvailableOnRefreshFailure)),
        ("testConfigureDedupesSameInFlightOptions", asyncTest(testConfigureDedupesSameInFlightOptions)),
        ("testConfigureFetchesFlagsAndReadsTypedValue", asyncTest(testConfigureFetchesFlagsAndReadsTypedValue)),
        ("testExposeSendsExposureEventPayload", asyncTest(testExposeSendsExposureEventPayload)),
        ("testGetFlagReturnsCallerFallbackWhenMissingOrTypeMismatch", asyncTest(testGetFlagReturnsCallerFallbackWhenMissingOrTypeMismatch)),
        ("testReadExposureDedupesForSameAssignmentIdentity", asyncTest(testReadExposureDedupesForSameAssignmentIdentity)),
        ("testRefreshFailureKeepsPreviouslyLoadedFlags", asyncTest(testRefreshFailureKeepsPreviouslyLoadedFlags)),
        ("testRefreshQueueDrainsPendingExpectedVersions", asyncTest(testRefreshQueueDrainsPendingExpectedVersions)),
        ("testRefreshRetriesWithBypassForStaleConfig", asyncTest(testRefreshRetriesWithBypassForStaleConfig)),
        ("testTrackSendsBatch", asyncTest(testTrackSendsBatch))
    ]
}

fileprivate extension TruflagLiveIntegrationTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__TruflagLiveIntegrationTests = [
        ("testLiveConfigureAndTrackAgainstRelay", asyncTest(testLiveConfigureAndTrackAgainstRelay))
    ]
}
@available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
func __TruflagSDKTests__allTests() -> [XCTestCaseEntry] {
    return [
        testCase(TruflagClientTests.__allTests__TruflagClientTests),
        testCase(TruflagLiveIntegrationTests.__allTests__TruflagLiveIntegrationTests)
    ]
}