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
import NIOCore
import NIOWebSocket

/// The web socket handler to be used once the upgrade has occurred.
///
/// It handles converting WebSocketFrames into ByteBuffers to be passed along along the pipeline
/// It also is responsible for handling various websocket frame opcodes (ex: .ping/.pong, .connectionClose, etc)
/// It also masks data when in client / .initiator mode and handles unmasking data in host / .listener mode
internal final class WebSocketDuplexHandler: ChannelDuplexHandler {
    typealias InboundIn = WebSocketFrame
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = WebSocketFrame

    var didFireChannelActive: Bool = false
    weak var _context: ChannelHandlerContext? = nil

    let mode: LibP2P.Mode
    private var logger: Logger

    /// Set once we've sent a `.connectionClose` frame, so we never send a second one
    private var sentClose: Bool = false

    internal init(mode: LibP2P.Mode, logger: Logger) {
        self.logger = logger  //Logger(label: "Transport:WS[\(logger)]:DuplexHandler")
        self.mode = mode
        self.logger[metadataKey: "WS"] = .string("DuplexHandler")
    }

    // This is being hit, channel active won't be called as it is already added.
    public func handlerAdded(context: ChannelHandlerContext) {
        self.logger.trace("WebSocket handler added.")
        _context = context
        //self.pingTestFrameData(context: context)
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        self.logger.trace("WebSocket handler removed.")
    }

    internal func fireChannelActiveIfNecessary() {
        guard didFireChannelActive == false else { return }
        //_context?.fireChannelActive()
        _context = nil
        didFireChannelActive = true
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)

        //        print("WebSocketHandler:channelRead \(frame)")
        //        print("Fin: \(frame.fin)")
        //        print("Opcode: \(frame.opcode)")
        //        print("Maks Key: \(frame.maskKey)")

        if didFireChannelActive == false {
            //context.fireChannelActive()
            didFireChannelActive = true
            _context = nil
        }

        switch frame.opcode {
        case .text, .binary:
            // Pass the received data along the pipeline
            context.fireChannelRead(self.wrapInboundOut(frame.unmaskedData))

        case .ping:
            // Every ping must be answered with a pong echoing its payload (RFC 6455 §5.5.2)
            self.pong(context: context, frame: frame)

        case .pong:
            // Unsolicited pongs are allowed and require no response
            break

        case .connectionClose:
            self.receivedClose(context: context, frame: frame)

        case .continuation:
            // Shouldn't happen, the frame aggregator reassembles fragmented messages for us
            self.logger.warning("Unexpected continuation frame received")

        default:
            // Unknown opcodes are protocol errors (RFC 6455 §5.2)
            self.logger.warning("Unknown Frame Opcode Received: \(frame.opcode)")
            self.close(context: context, code: .protocolError)
        }
    }

    private func pong(context: ChannelHandlerContext, frame: WebSocketFrame) {
        guard !self.sentClose else { return }
        let pong = WebSocketFrame(fin: true, opcode: .pong, maskKey: self.maskKey, data: frame.unmaskedData)
        context.writeAndFlush(self.wrapOutboundOut(pong), promise: nil)
    }

    private func receivedClose(context: ChannelHandlerContext, frame: WebSocketFrame) {
        self.logger.trace("Received Close instruction from remote peer")
        // Echo the status code back (RFC 6455 §5.5.1), then close the channel.
        var payload = frame.unmaskedData
        let code = payload.readWebSocketErrorCode() ?? .normalClosure
        self.close(context: context, code: code)
    }

    /// Sends a `.connectionClose` frame (if we haven't already), then closes the channel once it has been written
    private func close(context: ChannelHandlerContext, code: WebSocketErrorCode) {
        guard !self.sentClose else {
            context.close(promise: nil)
            return
        }
        self.sentClose = true

        var data = context.channel.allocator.buffer(capacity: 2)
        data.write(webSocketErrorCode: code)
        let frame = WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: self.maskKey, data: data)
        context.writeAndFlush(self.wrapOutboundOut(frame)).assumeIsolated().whenComplete { _ in
            context.close(promise: nil)
        }
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var data = self.unwrapOutboundIn(data)

        // libp2p treats a WebSocket as a byte stream, message boundaries carry no meaning. So we split
        // large writes into multiple frames to stay well under the remote's max frame size.
        while data.readableBytes > Self.maxOutboundFrameSize,
            let chunk = data.readSlice(length: Self.maxOutboundFrameSize)
        {
            context.write(self.wrapOutboundOut(self.binaryFrame(chunk)), promise: nil)
        }

        // Forward the promise, upstream handlers rely on it to learn when their write has completed.
        // Writes complete in order, so the final frame completing implies the earlier ones did too.
        context.write(self.wrapOutboundOut(self.binaryFrame(data)), promise: promise)
    }

    /// The largest frame we'll send, chosen to match the largest Noise frame (64 KiB)
    static let maxOutboundFrameSize: Int = 1 << 16

    private func binaryFrame(_ data: ByteBuffer) -> WebSocketFrame {
        WebSocketFrame(fin: true, opcode: .binary, maskKey: self.maskKey, data: data)
    }
}

extension ChannelPipeline.SynchronousOperations {
    /// Installs the handlers needed once the HTTP -> WebSocket upgrade completes.
    /// 1) A frame aggregator that reassembles fragmented messages
    /// 2) Our duplex handler which converts between WebSocketFrames and ByteBuffers
    func addWebSocketDuplexHandlers(mode: LibP2P.Mode, maxFrameSize: Int, logger: Logger) throws {
        try self.addHandlers(
            NIOWebSocketFrameAggregator(
                minNonFinalFragmentSize: 0,
                maxAccumulatedFrameCount: .max,
                maxAccumulatedFrameSize: maxFrameSize
            ),
            WebSocketDuplexHandler(mode: mode, logger: logger),
            position: .last
        )
    }
}
