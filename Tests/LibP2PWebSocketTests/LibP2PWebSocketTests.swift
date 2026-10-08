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

import Foundation
import LibP2P
import LibP2PTesting
import Logging
import Multiaddr
import NIOConcurrencyHelpers
import NIOCore
import Testing

@testable import LibP2PWebSocket

@Suite("Libp2p WebSocket Tests", .serialized)
struct LibP2PWebSocketTests {

    /// Exercise our transport agaist libp2p's built-in transport test harness
    @Test func testTransportConformance() async throws {
        let report = try await runTransportConformance(transportKey: WebSocket.key) { app in
            app.servers.use(.ws(host: "127.0.0.1", port: 0))
            app.transports.use(.ws)
        }
        print(report)
        try report.throwIfFailed()
    }
}

struct TestHelper {
    static var integrationTestsEnabled: Bool {
        if let b = ProcessInfo.processInfo.environment["PerformIntegrationTests"], b == "true" {
            return true
        }
        return false
    }
}

extension Trait where Self == ConditionTrait {
    /// This test is only available when the `PerformIntegrationTests` environment variable is set to `true`
    public static var externalIntegrationTestsEnabled: Self {
        enabled(
            if: TestHelper.integrationTestsEnabled,
            "This test is only available when the `PerformIntegrationTests` environment variable is set to `true`"
        )
    }
}
