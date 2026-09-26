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

extension Application.Servers.Provider {
    public static var ws: Self {
        .init {
            $0.servers.use { $0.ws.server.shared }
        }
    }

    public static func ws(host: String, port: Int) -> Self {
        .init {
            $0.ws.server.configuration = WSServer.Configuration(address: .hostname(host, port: port), logger: $0.logger)
            $0.servers.use {
                $0.ws.server.shared
            }
        }
    }
}

extension Application.WS {
    public var server: Server {
        .init(application: self.application)
    }

    public struct Server {
        let application: Application

        public var shared: WSServer {
            // Hold the lock for the entire call
            let lock = self.application.locks.lock(for: Key.self)
            lock.lock()
            defer { lock.unlock() }

            if let existing = self.application.storage[Key.self] {
                return existing
            }
            let new = WSServer(
                application: self.application,
                responder: self.application.responder.current,
                configuration: self.configuration,
                on: self.application.eventLoopGroup
            )
            // Release the listening socket on shutdown.
            self.application.storage.set(Key.self, to: new) { $0.shutdown() }
            return new
        }

        struct Key: StorageKey, LockKey {
            typealias Value = WSServer
        }

        public var configuration: WSServer.Configuration {
            get {
                self.application.storage[ConfigurationKey.self]
                    ?? .init(
                        logger: self.application.logger
                    )
            }
            nonmutating set {
                if self.application.storage.contains(Key.self) {
                    self.application.logger.warning("Cannot modify server configuration after server has been used.")
                } else {
                    self.application.storage[ConfigurationKey.self] = newValue
                }
            }
        }

        struct ConfigurationKey: StorageKey {
            typealias Value = WSServer.Configuration
        }
    }
}
