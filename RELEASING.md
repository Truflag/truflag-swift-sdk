# Releasing Truflag Swift SDK (SwiftPM + CocoaPods)

This SDK is installable via SwiftPM and CocoaPods once it is published from a standalone git repository (with `Package.swift` at repo root).

## 1) Export to standalone repo

From monorepo root:

```bash
git subtree split --prefix sdk/native/ios/TruflagSDK -b swift-sdk-release
git push git@github.com:truflag/truflag-swift-sdk.git swift-sdk-release:main --force
git branch -D swift-sdk-release
```

Alternative local export script:

```bash
bash sdk/native/ios/TruflagSDK/scripts/export-standalone-repo.sh ../truflag-swift-sdk
```

```powershell
powershell -ExecutionPolicy Bypass -File .\sdk\native\ios\TruflagSDK\scripts\export-standalone-repo.ps1 -TargetPath ..\truflag-swift-sdk
```

## 2) Prepare a release in standalone repo

1. Update `TruflagSDK.podspec`:
   - `s.version` must match release tag (for example `0.2.0`).
   - `s.source[:tag]` already uses `s.version.to_s`.
2. Commit the version bump.
3. Validate:

```bash
swift test
pod lib lint TruflagSDK.podspec --allow-warnings
```

## 3) Publish

From standalone repo:

```bash
git tag 0.2.0
git push origin main
git push origin 0.2.0
pod trunk push TruflagSDK.podspec --allow-warnings
```

## 4) Consumer install

SwiftPM:

```swift
.package(url: "https://github.com/truflag/truflag-swift-sdk.git", from: "0.2.0")
```

CocoaPods:

```ruby
pod 'TruflagSDK', '~> 0.2'
```

## Notes

- SwiftPM uses git tags; no package index submission is required.
- CocoaPods requires a valid trunk account (`pod trunk register ...` once per machine/account).
- If `pod trunk push` fails, run `pod spec lint TruflagSDK.podspec --allow-warnings --verbose` for deeper diagnostics.
