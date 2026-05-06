// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SafeShareLocalApp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SafeShareLocalApp", targets: ["SafeShareLocalApp"])
    ],
    targets: [
        .executableTarget(
            name: "SafeShareLocalApp",
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "SafeShareLocalAppTests",
            dependencies: ["SafeShareLocalApp"]
        )
    ]
)
