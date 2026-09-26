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

import LibP2P
import Logging
import Multiaddr
import NIO
import NIOConcurrencyHelpers
import NIOExtras
import NIOHTTP1
import NIOWebSocket

public final class WSServer: Server, @unchecked Sendable {
    public static let key: String = "WS"

    public enum Errors: Error {
        /// A Multiaddr that we don't support / can't dial
        case invalidRemoteAddress
        /// We lost our reference to the underlying application
        case lostReferenceToApplication
        /// `start()` was called on a server that is already listening.
        case alreadyStarted
        /// `start()` was called on a server that has already been shut down.
        case alreadyShutdown
    }

    /// Engine server config struct.
    ///
    ///     let serverConfig = WSServer.Configuration.default(port: 8123)
    ///     services.register(serverConfig)
    ///
    public struct Configuration: Sendable {
        public static let defaultHostname = "127.0.0.1"
        public static let defaultPort = 10001
        /// NIO's own default number of `read` calls per event-loop tick, per accepted connection.
        public static let defaultMaxMessagesPerRead: UInt = 4

        /// Address the server will bind to. Configuring an address using a hostname with a nil host or port will use the default hostname or port respectively.
        ///
        /// - Note: This is a plain stored value so copies of a `Configuration` don't share (and mutate) each others address.
        public var address: BindAddress

        /// Host name the server will bind to.
        public var hostname: String {
            get {
                switch address {
                case .hostname(let hostname, _):
                    return hostname ?? Self.defaultHostname
                default:
                    return Self.defaultHostname
                }
            }
            set {
                switch address {
                case .hostname(_, let port):
                    address = .hostname(newValue, port: port)
                default:
                    address = .hostname(newValue, port: nil)
                }
            }
        }

        /// Port the server will bind to.
        public var port: Int {
            get {
                switch address {
                case .hostname(_, let port):
                    return port ?? Self.defaultPort
                default:
                    return Self.defaultPort
                }
            }
            set {
                switch address {
                case .hostname(let hostname, _):
                    address = .hostname(hostname, port: newValue)
                default:
                    address = .hostname(nil, port: newValue)
                }
            }
        }

        /// Listen backlog.
        public var backlog: Int

        /// When `true`, can prevent errors re-binding to a socket after successive server restarts.
        public var reuseAddress: Bool

        /// When `true`, OS will attempt to minimize TCP packet delay.
        public var tcpNoDelay: Bool

        /// Maximum number of `read` calls the accept side will issue per event-loop tick, per accepted connection.
        public var maxMessagesPerRead: UInt

        /// The largest WebSocket frame (and reassembled message) we'll accept from a remote peer.
        public var maxFrameSize: Int

        //public var tlsConfiguration: TLSConfiguration?

        /// If set, this name will be serialized as the `Server` header in outgoing responses.
        public var serverName: String?

        /// Any uncaught server or responder errors will go here.
        public var logger: Logger

        /// A time limit to complete a graceful shutdown
        public var shutdownTimeout: TimeAmount

        public init(
            hostname: String = Self.defaultHostname,
            port: Int = Self.defaultPort,
            backlog: Int = 256,
            reuseAddress: Bool = true,
            tcpNoDelay: Bool = true,
            maxMessagesPerRead: UInt = Self.defaultMaxMessagesPerRead,
            maxFrameSize: Int = WebSocket.defaultMaxFrameSize,
            //            responseCompression: CompressionConfiguration = .disabled,
            //            requestDecompression: DecompressionConfiguration = .disabled,
            //            supportPipelining: Bool = true,
            //            supportVersions: Set<HTTPVersionMajor>? = nil,
            //            tlsConfiguration: TLSConfiguration? = nil,
            serverName: String? = nil,
            logger: Logger? = nil,
            shutdownTimeout: TimeAmount = .seconds(10)
        ) {
            self.init(
                address: .hostname(hostname, port: port),
                backlog: backlog,
                reuseAddress: reuseAddress,
                tcpNoDelay: tcpNoDelay,
                maxMessagesPerRead: maxMessagesPerRead,
                maxFrameSize: maxFrameSize,
                //                responseCompression: responseCompression,
                //                requestDecompression: requestDecompression,
                //                supportPipelining: supportPipelining,
                //                supportVersions: supportVersions,
                //                tlsConfiguration: tlsConfiguration,
                serverName: serverName,
                logger: logger,
                shutdownTimeout: shutdownTimeout
            )
        }

        public init(
            address: BindAddress,
            backlog: Int = 256,
            reuseAddress: Bool = true,
            tcpNoDelay: Bool = true,
            maxMessagesPerRead: UInt = Self.defaultMaxMessagesPerRead,
            maxFrameSize: Int = WebSocket.defaultMaxFrameSize,
            //            responseCompression: CompressionConfiguration = .disabled,
            //            requestDecompression: DecompressionConfiguration = .disabled,
            //            supportPipelining: Bool = true,
            //            supportVersions: Set<HTTPVersionMajor>? = nil,
            //            tlsConfiguration: TLSConfiguration? = nil,
            serverName: String? = nil,
            logger: Logger? = nil,
            shutdownTimeout: TimeAmount = .seconds(10)
        ) {
            self.address = address
            self.backlog = backlog
            self.reuseAddress = reuseAddress
            self.tcpNoDelay = tcpNoDelay
            self.maxMessagesPerRead = maxMessagesPerRead
            self.maxFrameSize = maxFrameSize
            //            self.responseCompression = responseCompression
            //            self.requestDecompression = requestDecompression
            //            self.supportPipelining = supportPipelining
            //            if let supportVersions = supportVersions {
            //                self.supportVersions = supportVersions
            //            } else {
            //                self.supportVersions = tlsConfiguration == nil ? [.one] : [.one, .two]
            //            }
            //            self.tlsConfiguration = tlsConfiguration
            self.serverName = serverName
            self.logger = logger ?? Logger(label: "swift.libp2p.ws-server")
            self.shutdownTimeout = shutdownTimeout
        }
    }

    /// Our mutable server state
    private struct State {
        var connection: WSServerConnection?
        var didStart: Bool = false
        var didShutdown: Bool = false
        /// The addresses we announced with `.listen`, so `shutdown()` can post a
        /// matching `.listenClosed` for each one
        var announcedAddresses: [Multiaddr] = []
    }

    public var onShutdown: EventLoopFuture<Void> {
        guard let connection = self.state.withLockedValue({ $0.connection }) else {
            fatalError("Server has not started yet")
        }
        return connection.channel.closeFuture
    }

    private let responder: Responder
    private let configuration: Configuration
    private let eventLoopGroup: EventLoopGroup
    private let application: Application

    private let state = NIOLockedValueBox(State())

    init(
        application: Application,
        responder: Responder,
        configuration: Configuration,
        on eventLoopGroup: EventLoopGroup
    ) {
        self.application = application
        self.responder = responder
        self.configuration = configuration
        self.eventLoopGroup = eventLoopGroup
    }

    public func start(address: BindAddress?) throws {
        let configuration = try self.prepareStart(address: address)

        // Revert didStart if we fail to bind, so a recoverable failure (address already in
        // use, say) can still be retried by the caller.
        var boundSuccessfully = false
        defer {
            if !boundSuccessfully {
                self.state.withLockedValue { $0.didStart = false }
            }
        }

        // Start the actual WSServer
        let connection = try WSServerConnection.start(
            application: self.application,
            responder: self.responder,
            configuration: configuration,
            on: self.eventLoopGroup
        ).wait()

        self.completeStart(connection: connection)
        boundSuccessfully = true
    }

    public func start(address: BindAddress?) async throws {
        let configuration = try self.prepareStart(address: address)

        // Revert didStart if we fail to bind, so a recoverable failure (address already in
        // use, say) can still be retried by the caller.
        var boundSuccessfully = false
        defer {
            if !boundSuccessfully {
                self.state.withLockedValue { $0.didStart = false }
            }
        }

        // Start the actual WSServer
        let connection = try await WSServerConnection.start(
            application: self.application,
            responder: self.responder,
            configuration: configuration,
            on: self.eventLoopGroup
        ).get()

        self.completeStart(connection: connection)
        boundSuccessfully = true
    }

    /// Flips `didStart` and resolves the effective configuration for this start attempt.
    private func prepareStart(address: BindAddress?) throws -> Configuration {
        try self.state.withLockedValue { state in
            guard !state.didStart else { throw Errors.alreadyStarted }
            guard !state.didShutdown else { throw Errors.alreadyShutdown }
            state.didStart = true
        }

        var configuration = self.configuration

        switch address {
        case .none:  // use the configuration as is
            break
        case .hostname(let hostname, let port):  // override the hostname, port, neither, or both
            configuration.address = .hostname(hostname ?? configuration.hostname, port: port ?? configuration.port)
        case .unixDomainSocket(let socketPath):  // override the socket path
            configuration.address = .unixDomainSocket(path: socketPath)
        }

        // print starting message
        let addressDescription: String
        switch configuration.address {
        case .hostname(let hostname, let port):
            addressDescription = "\(hostname ?? configuration.hostname):\(port ?? configuration.port)"
        case .unixDomainSocket(let socketPath):
            addressDescription = "unix: \(socketPath)"
        }

        self.configuration.logger.notice("WS Server starting on \(addressDescription)")

        return configuration
    }

    /// Records the bound connection, then announces our listen addresses.
    private func completeStart(connection: WSServerConnection) {
        self.state.withLockedValue { $0.connection = connection }

        // `Application.listenAddresses` expands wildcard binds into one address per interface,
        // so `.listen` subscribers never observe a wildcard. We only announce our own (`/ws`) entries.
        let announced = self.application.listenAddresses.filter { $0.protocols().contains(.ws) }
        self.configuration.logger.notice("WS Server reachable at \(announced)")
        self.state.withLockedValue { $0.announcedAddresses = announced }
        for address in announced {
            self.application.events.post(.listen(self.application.peerID.b58String, address))
        }
    }

    public func shutdown() {
        guard let (connection, announced) = self.beginShutdown() else { return }

        do {
            try connection.close(timeout: self.configuration.shutdownTimeout).wait()
        } catch {
            self.configuration.logger.error("Could not stop WS server: \(error)")
        }

        self.finishShutdown(announced: announced)
    }

    public func shutdown() async {
        guard let (connection, announced) = self.beginShutdown() else { return }

        do {
            try await connection.close(timeout: self.configuration.shutdownTimeout).get()
        } catch {
            self.configuration.logger.error("Could not stop WS server: \(error)")
        }

        self.finishShutdown(announced: announced)
    }

    /// Claims the live connection and announced addresses in one step, so a second `shutdown()`
    /// is a no-op. Returns `nil` when there's nothing to shut down.
    private func beginShutdown() -> (connection: WSServerConnection, announced: [Multiaddr])? {
        let (connection, announced) = self.state.withLockedValue {
            state -> (WSServerConnection?, [Multiaddr]) in
            guard !state.didShutdown, let connection = state.connection else { return (nil, []) }
            state.didShutdown = true
            state.connection = nil
            let announced = state.announcedAddresses
            state.announcedAddresses = []
            return (connection, announced)
        }
        guard let connection else { return nil }
        self.configuration.logger.trace("Requesting WS server shutdown")
        return (connection, announced)
    }

    private func finishShutdown(announced: [Multiaddr]) {
        self.configuration.logger.trace("WS server shutting down")

        // Balance the `.listen` events posted at start-up.
        if self.application.isRunning {
            let localPeer = self.application.peerID.b58String
            for address in announced {
                self.application.events.post(.listenClosed(localPeer, address))
            }
        }
    }

    public var localAddress: SocketAddress? {
        self.state.withLockedValue { $0.connection }?.channel.localAddress
    }

    /// TODO: FIXME!
    public var listeningAddress: Multiaddr {
        // Prefer the live socket address when available (the connection is released on shutdown)
        guard let live = self.localAddress else {
            return try! Multiaddr("/ip4/\(self.configuration.hostname)/tcp/\(self.configuration.port)/ws")
        }
        return try! live.toMultiaddr().encapsulate(proto: .ws, address: nil)
    }

    deinit {
        let (didStart, didShutdown) = self.state.withLockedValue { ($0.didStart, $0.didShutdown) }
        assert(!didStart || didShutdown, "WSServer did not shutdown before deinitializing")
    }
}

private final class WSServerConnection: Sendable {
    let channel: Channel
    let quiesce: ServerQuiescingHelper

    static func start(
        application: Application,
        responder: Responder,
        configuration: WSServer.Configuration,
        on eventLoopGroup: EventLoopGroup
    ) -> EventLoopFuture<WSServerConnection> {
        let quiesce = ServerQuiescingHelper(group: eventLoopGroup)
        let bootstrap = ServerBootstrap(group: eventLoopGroup)
            // Specify backlog and enable SO_REUSEADDR for the server itself
            .serverChannelOption(ChannelOptions.backlog, value: Int32(configuration.backlog))
            .serverChannelOption(
                ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR),
                value: configuration.reuseAddress ? SocketOptionValue(1) : SocketOptionValue(0)
            )

            // Set handlers that are applied to the Server's channel
            .serverChannelInitializer { channel in
                do {
                    try channel.pipeline.syncOperations.addHandler(quiesce.makeServerChannelHandler(channel: channel))
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

            // Set the handlers that are applied to the accepted Channels
            .childChannelInitializer { [weak application] channel in
                guard let application = application else {
                    return channel.eventLoop.makeFailedFuture(WSServer.Errors.lostReferenceToApplication)
                }
                guard
                    let remoteAddress = try? channel.remoteAddress?.toMultiaddr().encapsulate(proto: .ws, address: nil)
                else { return channel.eventLoop.makeFailedFuture(WSServer.Errors.invalidRemoteAddress) }

                let logger: Logger = {
                    var logger = application.logger
                    logger[metadataKey: "WS"] = .string("\(remoteAddress)")
                    return logger
                }()

                let upgrader = NIOWebSocketServerUpgrader(
                    shouldUpgrade: { (channel: Channel, head: HTTPRequestHead) in
                        channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                    },
                    upgradePipelineHandler: { (channel: Channel, _: HTTPRequestHead) in
                        do {
                            try channel.pipeline.syncOperations.addHandler(
                                WebSocketDuplexHandler(mode: .listener, logger: logger),
                                position: .last
                            )
                        } catch {
                            return channel.eventLoop.makeFailedFuture(error)
                        }
                        /// Ask the application to adopt the connection which...
                        /// - consults the ConnectionGater
                        /// - installs the quiesce / backpressure handlers
                        /// - registers the connection with the manager
                        /// - initializes the channel.
                        /// A rejection closes the channel.
                        return application.connectionManager.adoptInbound(
                            channel: channel,
                            remoteAddress: remoteAddress
                        ).map { _ in }
                    }
                )

                let httpHandler = ServerUpgradeHandler()
                let config: NIOHTTPServerUpgradeConfiguration = (
                    upgraders: [upgrader],
                    completionHandler: { context in
                        context.pipeline.syncOperations.removeHandler(httpHandler, promise: nil)
                    }
                )

                do {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(withServerUpgrade: config)
                    try channel.pipeline.syncOperations.addHandler(httpHandler)
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
                return channel.eventLoop.makeSucceededVoidFuture()
            }

            // Enable TCP_NODELAY and SO_REUSEADDR for the accepted Channels
            .childChannelOption(
                ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY),
                value: configuration.tcpNoDelay ? SocketOptionValue(1) : SocketOptionValue(0)
            )
            .childChannelOption(
                ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR),
                value: configuration.reuseAddress ? SocketOptionValue(1) : SocketOptionValue(0)
            )
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

        let channel: EventLoopFuture<Channel>
        switch configuration.address {
        case .hostname:
            channel = bootstrap.bind(host: configuration.hostname, port: configuration.port)
        case .unixDomainSocket(let socketPath):
            channel = bootstrap.bind(unixDomainSocketPath: socketPath)
        }

        return channel.map { channel in
            .init(channel: channel, quiesce: quiesce)
        }.flatMapErrorThrowing { error -> WSServerConnection in
            quiesce.initiateShutdown(promise: nil)
            throw error
        }
    }

    init(channel: Channel, quiesce: ServerQuiescingHelper) {
        self.channel = channel
        self.quiesce = quiesce
    }

    func close(timeout: TimeAmount) -> EventLoopFuture<Void> {
        let promise = self.channel.eventLoop.makePromise(of: Void.self)
        self.channel.eventLoop.scheduleTask(in: timeout) {
            //promise.fail(Abort(.internalServerError, reason: "Server stop took too long."))
            promise.fail(Errors.serverStopTookTooLong)
        }
        self.quiesce.initiateShutdown(promise: promise)
        return promise.futureResult
    }

    var onClose: EventLoopFuture<Void> {
        self.channel.closeFuture
    }

    deinit {
        assert(!self.channel.isActive, "WSServerConnection deinitialized without calling shutdown()")
    }

    public enum Errors: Error {
        case serverStopTookTooLong
    }
}

//extension ChannelPipeline {
//    func addTCPHandlers(
//        application: Application,
//        responder: Responder,
//        configuration: TCPServer.Configuration
//    ) -> EventLoopFuture<Void> {
//        var handlers: [ChannelHandler] = []
//      ...
//    }
//}
