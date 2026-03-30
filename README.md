# Truflag iOS SDK (Swift)

## Path

`sdk/native/ios/TruflagSDK`

## Features

- Relay-backed flag evaluation fetches (`/v1/flags`)
- Telemetry batching endpoint (`/v1/events/batch`)
- Identity lifecycle (`configure`, `login`, `setAttributes`, `logout`)
- Startup `current.json` prefetch and stale-config retry

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
