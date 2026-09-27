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
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

// Install our WS Tranport on the LibP2P Application
public struct WebSocket: Transport {
    public static let key: String = "websockets"

    let application: Application

    public var protocols: [LibP2PProtocol] {
        get { _protocols.withLockedValue { $0 } }
    }
    public let _protocols: NIOLockedValueBox<[LibP2PProtocol]>

    public var proxy: Bool {
        get { _proxy.withLockedValue { $0 } }
    }
    public let _proxy: NIOLockedValueBox<Bool>

    public let uuid: UUID

    init(application: Application, protocols: [LibP2PProtocol], proxy: Bool, uuid: UUID) {
        self.application = application
        self._protocols = .init(protocols)
        self._proxy = .init(proxy)
        self.uuid = uuid
    }

    /// How long a dial may spend in `connect` before we give up.
    public static let defaultConnectTimeout: TimeAmount = .seconds(10)

    /// How long the HTTP -> WebSocket upgrade may take once the socket is connected.
    public static let defaultUpgradeTimeout: TimeAmount = .seconds(10)

    /// The largest WebSocket frame (and reassembled message) we'll accept.
    ///
    /// NIO's upgraders default to 16 KiB, which is smaller than a single max-size Noise frame (64 KiB).
    public static let defaultMaxFrameSize: Int = 1 << 20

    public var sharedClient: ClientBootstrap {
        let lock = self.application.locks.lock(for: Key.self)
        lock.lock()
        defer { lock.unlock() }
        if let existing = self.application.storage[Key.self] {
            return existing.bootstrap
        }
        let new = ClientBootstrap(group: self.application.eventLoopGroup)
            // Enable SO_REUSEADDR.
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            // Match the accept side, which sets TCP_NODELAY on every child channel.
            .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .channelOption(ChannelOptions.connectTimeout, value: Self.defaultConnectTimeout)
            .channelInitializer { channel in
                // The HTTP / WebSocket upgrade handlers are installed per dial (see `dial(address:)`)
                channel.eventLoop.makeSucceededVoidFuture()
            }

        self.application.storage.set(Key.self, to: SharedDialBootstrap(new))

        return new
    }
    //    public var sharedClient: TCPClient {
    //        let lock = self.application.locks.lock(for: Key.self)
    //        lock.lock()
    //        defer { lock.unlock() }
    //        if let existing = self.application.storage[Key.self] {
    //            return existing
    //        }
    //        let new = TCPClient(
    //
    //        self.application.storage.set(Key.self, to: new)
    //
    //        return new
    //    }

    //    public var configuration: TCPClient.Configuration {
    //        get {
    //            self.application.storage[ConfigurationKey.self] ?? .init()
    //        }
    //        nonmutating set {
    //            if self.application.storage.contains(Key.self) {
    //                self.application.logger.warning("Cannot modify client configuration after client has been used.")
    //            } else {
    //                self.application.storage[ConfigurationKey.self] = newValue
    //            }
    //        }
    //    }

    /// For each new Dial, we connect to the desired multiaddr, then install our handlers
    /// 1) Http 1.1 initial request handler (with client upgrader config)
    /// 2) Once the upgrade completes, the WebSocket Handler
    /// 3) We then hand the upgraded channel to the ConnectionManager (`adoptOutbound`), which registers the
    ///    connection, installs the quiesce / backpressure handlers, and kicks off the security + muxer upgrade.
    ///
    /// The returned future only succeeds once the WebSocket upgrade has completed and the connection has been adopted.
    /// A failed upgrade, early close, or a timeout fails the dial.
    public func dial(address: Multiaddr) -> EventLoopFuture<Connection> {
        guard let tcp = address.tcpAddress else {
            self.application.logger.warning("Invalid Mutliaddr. WS can't dial \(address)")
            return self.application.eventLoopGroup.any().makeFailedFuture(Errors.invalidMultiaddr)
        }

        let application = self.application
        application.logger.trace("Attempting to dial \(address)")

        return sharedClient.connect(host: tcp.address, port: tcp.port).flatMap {
            channel -> EventLoopFuture<Connection> in

            let logger: Logger = {
                var logger = application.logger
                logger[metadataKey: "WS"] = .string("\(address)")
                return logger
            }()

            // Completed once the upgraded channel has been adopted by the ConnectionManager
            let adopted = channel.eventLoop.makePromise(of: Connection.self)

            // Fail the dial if the upgrade doesn't complete in time.
            let upgradeTimeout = channel.eventLoop.scheduleTask(in: Self.defaultUpgradeTimeout) {
                adopted.fail(Errors.upgradeTimedOut)
                channel.close(mode: .all, promise: nil)
            }
            // Fail the dial if the channel closes before the upgrade / adoption completes.
            // Failing an already completed promise is a no-op.
            channel.closeFuture.whenComplete { _ in
                adopted.fail(Errors.upgradeFailed)
            }
            // Cancel the upgrade timeout if we're adopted
            adopted.futureResult.whenComplete { _ in upgradeTimeout.cancel() }

            let httpHandler = HTTPInitialRequestHandler(target: address, logger: logger)

            /// - Note: The default requestKey NIO generates seems to work now!
            /// swift-nio recommends 28 char requestKey, Go supports 28 char keys
            /// JS doesn't support 28 char keys, it only seems to support 24 char keys
            /// requestKey: "dGhlIHNhbXBsZSBub25jZQ==",
            /// requestKey: "OfS0wDaT5NoxF2gqm7Zj2YtetzM=",
            let websocketUpgrader = NIOWebSocketClientUpgrader(
                maxFrameSize: Self.defaultMaxFrameSize,
                upgradePipelineHandler: { (channel: Channel, _: HTTPResponseHead) in
                    do {
                        try channel.pipeline.syncOperations.addWebSocketDuplexHandlers(
                            mode: .initiator,
                            maxFrameSize: Self.defaultMaxFrameSize,
                            logger: logger
                        )
                    } catch {
                        adopted.fail(error)
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                    /// Hand the upgraded channel to the ConnectionManager.
                    /// Outbound dials are gated pre-dial, so admission goes straight to the manager.
                    let adoption = application.connectionManager.adoptOutbound(
                        channel: channel,
                        remoteAddress: address
                    ).map { $0 as Connection }
                    adopted.completeWith(adoption)
                    return adoption.map { _ in }
                }
            )

            /// Create the Upgrader Configuration
            let config: NIOHTTPClientUpgradeConfiguration = (
                upgraders: [websocketUpgrader],
                completionHandler: { context in
                    context.pipeline.syncOperations.removeHandler(httpHandler, promise: nil)
                }
            )

            /// Install the http handlers and the WS upgrader, then wait for the upgrade + adoption to complete
            do {
                try channel.pipeline.syncOperations.addHTTPClientHandlers(withClientUpgrade: config)
                try channel.pipeline.syncOperations.addHandler(httpHandler)
            } catch {
                adopted.fail(error)
                channel.close(mode: .all, promise: nil)
            }

            return adopted.futureResult
        }
    }

    /// Parses the Multiaddr and determines if it's a valid WebSocket endpoint that can be dialed
    public func canDial(address: Multiaddr) -> Bool {
        guard let tcp = address.tcpAddress else { return false }
        // Remove once we can dial ipv6 addresses
        guard tcp.ip4 else { return false }
        // We should only dial WS multiaddr // || ma.protocols().contains(.wss))
        guard address.protocols().contains(.ws) else { return false }
        return true
    }

    struct Key: StorageKey, LockKey {
        typealias Value = SharedDialBootstrap
    }

    //    struct ConfigurationKey: StorageKey {
    //        typealias Value = TCPClient.Configuration
    //    }

    public enum Errors: Error {
        case invalidMultiaddr
        /// The remote closed the channel, or rejected the HTTP -> WebSocket upgrade, before the connection was established.
        case upgradeFailed
        /// The HTTP -> WebSocket upgrade didn't complete within ``WebSocket/defaultUpgradeTimeout``.
        case upgradeTimedOut
    }
}

/// Holds the shared dial bootstrap so it can live in `Application.storage` without
/// retroactively conforming NIO's `ClientBootstrap`.
final class SharedDialBootstrap: @unchecked Sendable {
    let bootstrap: ClientBootstrap

    init(_ bootstrap: ClientBootstrap) {
        self.bootstrap = bootstrap
    }
}

extension Application.Transports.Provider {
    public static var ws: Self {
        .init { app in
            app.transports.use(key: WebSocket.key) {
                WebSocket(application: $0, protocols: [], proxy: false, uuid: UUID())
            }
        }
    }

    //    public static func wss(_ tlsConfig:Any) -> Self {
    //        .init { app in
    //            app.transports.use(key: WebSockets.key) {
    //                WebSockets(application: $0, protocols:[], proxy: false, uuid:UUID())
    //            }
    //        }
    //    }
}
