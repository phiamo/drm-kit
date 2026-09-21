// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DrmKit",
    platforms: [.iOS(.v18)],
    products: [
        .library(
            name: "DrmKit",
            targets: ["DrmKit"])
    ],
    targets: [
        .target(
            name: "DrmKit",
            path: "ios/Sources/DrmKit",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]),
        .testTarget(
            name: "DrmKitTests",
            dependencies: ["DrmKit"],
            path: "ios/Tests/DrmKitTests")
    ]
)
