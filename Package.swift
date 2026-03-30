// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TruflagSDK",
    platforms: [
        .iOS(.v13),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "TruflagSDK",
            targets: ["TruflagSDK"]
        )
    ],
    targets: [
        .target(
            name: "TruflagSDK"
        ),
        .testTarget(
            name: "TruflagSDKTests",
            dependencies: ["TruflagSDK"]
        )
    ]
)
