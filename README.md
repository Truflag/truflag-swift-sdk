# Truflag iOS SDK (Swift)

## Path

`sdk/native/ios/TruflagSDK`

## Example app

- iOS sample app: `sdk/examples/ios-swift-sample`
- Internal operations guide: `sdk/native/ios/TruflagSDK/EXAMPLE_APP.md`

## Features

- Relay-backed flag evaluation fetches (`/v1/flags`)
- Telemetry batching endpoint (`/v1/events/batch`)
- Identity lifecycle (`configure`, `login`, `setAttributes`, `logout`)
- Startup `current.json` prefetch and stale-config retry

## Installation

### Swift Package Manager

Use a tagged release from the SDK repository root (the repo that contains this
`Package.swift` at its root):

```swift
dependencies: [
  .package(url: "https://github.com/truflag/truflag-swift-sdk.git", from: "0.2.2")
]
```

Then add the product dependency:

```swift
.product(name: "TruflagSDK", package: "TruflagSDK")
```

### CocoaPods

```ruby
pod 'TruflagSDK', '~> 0.2'
```

## Publishing Notes

- SwiftPM remote dependencies require `Package.swift` at repository root.
- If this SDK remains in a monorepo subdirectory, publish via:
  - a dedicated SDK repo, or
  - a subtree split mirror of `sdk/native/ios/TruflagSDK`.
- CocoaPods uses `TruflagSDK.podspec` and expects git tags that match
  `s.version`.
- CI release workflow: `.github/workflows/release-swift-sdk.yml`
  - Runs on tag push (`v*`, `*.*.*`, `sdk-ios-v*`)
  - Runs `swift test`, `pod lib lint`, then `pod trunk push`
  - Requires repository secret `COCOAPODS_TRUNK_TOKEN`

## Quickstart

```swift
import TruflagSDK

let client = TruflagClient()
try await client.configure(
  TruflagConfigureOptions(
    apiKey: "env_c_...",
    user: TruflagUser(id: "user-123")
  )
)

let enabled: Bool = await client.getFlag("new-checkout", defaultValue: false)

// Optional: flush telemetry immediately for this event
try await client.track(
  eventName: "checkout_completed",
  properties: ["value": AnyCodable(1)],
  immediate: true
)
```

## Tests

```bash
swift test
# Docker fallback:
# docker run --rm -v "<absolute-path-to>/sdk/native/ios/TruflagSDK:/work" -w /work swift:6.0 swift test

# Live relay integration test (optional):
# docker run --rm \
#   -e TRUFLAG_CLIENT_SIDE_ID=env_c_... \
#   -e TRUFLAG_BASE_URL=https://sdk.truflag.com \
#   -v "<absolute-path-to>/sdk/native/ios/TruflagSDK:/work" \
#   -w /work \
#   swift:6.0 \
#   swift test --filter TruflagLiveIntegrationTests
```
