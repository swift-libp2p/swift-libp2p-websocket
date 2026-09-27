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
import Logging
import Multiaddr
import NIOCore
import NIOEmbedded
import NIOPosix
import NIOWebSocket
import Testing

@testable import LibP2PWebSocket

@Suite("WebSocket Handler Tests")
struct WebSocketHandlerTests {

    /// An active EmbeddedChannel with a WebSocketDuplexHandler installed
    private func makeChannel(mode: LibP2P.Mode) throws -> EmbeddedChannel {
        let channel = EmbeddedChannel(handler: WebSocketDuplexHandler(mode: mode, logger: Logger(label: "test")))
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
        return channel
    }

    @Test(arguments: [LibP2P.Mode.listener, .initiator])
    func testPingIsAnsweredWithPong(mode: LibP2P.Mode) throws {
        let channel = try makeChannel(mode: mode)
        defer { _ = try? channel.finish() }

        let payload = ByteBuffer(string: "ping!")
        try channel.writeInbound(WebSocketFrame(fin: true, opcode: .ping, data: payload))

        // - Note: Outbound frames carry plaintext `data`, the WebSocketFrameEncoder applies the `maskKey` on the wire
        let pong = try #require(try channel.readOutbound(as: WebSocketFrame.self))
        #expect(pong.opcode == .pong)
        #expect(pong.data == payload)
        // Only the initiator (client) masks its frames
        #expect((pong.maskKey != nil) == (mode == .initiator))

        // Control frames are never passed along the pipeline
        #expect(try channel.readInbound(as: ByteBuffer.self) == nil)
    }

    @Test func testBinaryFramesArePassedAlong() throws {
        let channel = try makeChannel(mode: .listener)
        defer { _ = try? channel.finish() }

        let payload = ByteBuffer(string: "hello")
        try channel.writeInbound(WebSocketFrame(fin: true, opcode: .binary, data: payload))
        #expect(try channel.readInbound(as: ByteBuffer.self) == payload)
    }

    @Test func testWritePromiseCompletes() throws {
        let channel = try makeChannel(mode: .initiator)
        defer { _ = try? channel.finish() }

        let payload = ByteBuffer(string: "hello")
        let write = channel.writeAndFlush(payload)
        channel.embeddedEventLoop.run()
        try write.wait()

        let frame = try #require(try channel.readOutbound(as: WebSocketFrame.self))
        #expect(frame.opcode == .binary)
        #expect(frame.maskKey != nil)
        #expect(frame.data == payload)
    }

    @Test func testLargeWritesAreSplitIntoFrames() throws {
        let channel = try makeChannel(mode: .listener)
        defer { _ = try? channel.finish() }

        let bytes = (0..<(1 << 20) + 5).map { UInt8(truncatingIfNeeded: $0) }
        let write = channel.writeAndFlush(ByteBuffer(bytes: bytes))
        channel.embeddedEventLoop.run()
        try write.wait()

        var received: [UInt8] = []
        var frameCount = 0
        while let frame = try channel.readOutbound(as: WebSocketFrame.self) {
            #expect(frame.opcode == .binary)
            #expect(frame.data.readableBytes <= WebSocketDuplexHandler.maxOutboundFrameSize)
            received.append(contentsOf: frame.data.readableBytesView)
            frameCount += 1
        }
        #expect(frameCount == 17)
        #expect(received == bytes)
    }

    @Test func testCloseFrameIsEchoedThenChannelCloses() throws {
        let channel = try makeChannel(mode: .listener)

        var data = channel.allocator.buffer(capacity: 2)
        data.write(webSocketErrorCode: .goingAway)
        try channel.writeInbound(WebSocketFrame(fin: true, opcode: .connectionClose, data: data))
        channel.embeddedEventLoop.run()

        let close = try #require(try channel.readOutbound(as: WebSocketFrame.self))
        #expect(close.opcode == .connectionClose)
        var echoed = close.data
        #expect(echoed.readWebSocketErrorCode() == .goingAway)

        #expect(!channel.isActive)
    }

    @Test func testConfigurationCopiesDontShareAddress() {
        let original = WSServer.Configuration(hostname: "127.0.0.1", port: 1234)
        var copy = original
        copy.address = .hostname("0.0.0.0", port: 4321)

        #expect(original.address == .hostname("127.0.0.1", port: 1234))
        #expect(copy.address == .hostname("0.0.0.0", port: 4321))
    }

    /// A remote that accepts the TCP connection but never completes the WebSocket upgrade should fail the dial,
    /// and de-register the connection.
    @Test func testFailedUpgradeFailsDial() async throws {
        // A TCP listener that closes every connection it accepts
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.close()
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()

        let client = try await Application.make(.testing)
        client.transports.use(.ws)
        try await client.startup()

        let port = try #require(listener.localAddress?.port)
        let address = try Multiaddr("/ip4/127.0.0.1/tcp/\(port)/ws")
        let ws = WebSocket(application: client, protocols: [], proxy: false, uuid: UUID())

        await #expect(throws: WebSocket.Errors.upgradeFailed) {
            _ = try await ws.dial(address: address)
        }
        #expect(try await client.connections.getConnections().isEmpty)

        try await client.asyncShutdown()
        try await listener.close()
    }
}
