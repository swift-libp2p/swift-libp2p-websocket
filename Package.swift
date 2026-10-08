// swift-tools-version: 6.1
//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-libp2p open source project
//
// Copyright (c) 2022-2026 swift-libp2p project authors
// Licensed under MIT
//
// See LICENSE for license information
// See CONTRIBUTORS for the list of swift-libp2p project authors
//
// SPDX-License-Identifier: MIT
//
//===----------------------------------------------------------------------===//

import PackageDescription

let package = Package(
    name: "swift-libp2p-websocket",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "LibP2PWebSocket",
            targets: ["LibP2PWebSocket"]
        )
    ],
    traits: [
        // Not enabled by default, so consumers of this package never build / link the test only dependencies.
        // Enable it to run the live networking tests: `swift test --traits TestDependencies`
        .trait(
            name: "TestDependencies",
            description: "Enables the live networking tests, which depend on swift-libp2p-noise and swift-libp2p-yamux"
        )
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(url: "https://github.com/swift-libp2p/swift-libp2p.git", .upToNextMinor(from: "0.4.0")),
        .package(url: "https://github.com/apple/swift-nio.git", .upToNextMajor(from: "2.87.0")),

        // Test dependencies (only used when the `TestDependencies` trait is enabled)
        .package(url: "https://github.com/swift-libp2p/swift-libp2p-noise", .upToNextMinor(from: "0.4.0")),
        .package(url: "https://github.com/swift-libp2p/swift-libp2p-yamux", .upToNextMinor(from: "0.4.0")),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "LibP2PWebSocket",
            dependencies: [
                .product(name: "LibP2P", package: "swift-libp2p"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "LibP2PWebSocketTests",
            dependencies: [
                "LibP2PWebSocket",
                .product(name: "LibP2PTesting", package: "swift-libp2p"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(
                    name: "LibP2PNoise",
                    package: "swift-libp2p-noise",
                    condition: .when(traits: ["TestDependencies"])
                ),
                .product(
                    name: "LibP2PYAMUX",
                    package: "swift-libp2p-yamux",
                    condition: .when(traits: ["TestDependencies"])
                ),
            ]
        ),
    ]
)
