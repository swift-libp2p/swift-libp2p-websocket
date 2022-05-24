// swift-tools-version: 5.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-libp2p-websocket",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13)
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "LibP2PWebSocket",
            targets: ["LibP2PWebSocket"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
        .package(url: "https://github.com/swift-libp2p/swift-libp2p.git", .upToNextMajor(from: "0.1.0")),
        .package(url: "https://github.com/apple/swift-nio.git", .upToNextMajor(from: "2.0.0")),
        
        // Testing
        .package(url: "https://github.com/swift-libp2p/swift-libp2p-noise", .upToNextMajor(from: "0.1.0")),
        .package(url: "https://github.com/swift-libp2p/swift-libp2p-mplex", .upToNextMajor(from: "0.1.0")),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "LibP2PWebSocket",
            dependencies: [
                .product(name: "LibP2P", package: "swift-libp2p"),
                .product(name: "NIOWebSocket", package: "swift-nio")
            ]),
        .testTarget(
            name: "LibP2PWebSocketTests",
            dependencies: [
                "LibP2PWebSocket",
                .product(name: "LibP2PNoise", package: "swift-libp2p-noise"),
                .product(name: "LibP2PMPLEX", package: "swift-libp2p-mplex")
            ]),
    ]
)
