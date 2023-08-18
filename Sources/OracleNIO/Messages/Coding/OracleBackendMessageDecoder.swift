import NIOCore

struct OracleBackendMessageDecoder: ByteToMessageDecoder {

    static let headerSize = 8

    typealias InboundOut = [OracleBackendMessage]

    private var capabilities: Capabilities

    init(capabilities: Capabilities) {
        self.capabilities = capabilities
    }

    mutating func decode(
        context: ChannelHandlerContext, buffer: inout ByteBuffer
    ) throws -> DecodingState {
        while let message = try decodeMessage(from: &buffer) {
            context.fireChannelRead(self.wrapInboundOut(message))
            return .continue
        }
        return .needMoreData
    }

    func decodeMessage(from buffer: inout ByteBuffer) throws -> InboundOut? {
        let length: Int?
        if self.capabilities.protocolVersion >= Constants.TNS_VERSION_MIN_LARGE_SDU {
            length = buffer.getInteger(at: 0, as: UInt32.self).map(Int.init)
        } else {
            length = buffer.getInteger(at: 0, as: UInt16.self).map(Int.init)
        }
        guard
            let length,
            buffer.readableBytes >= Self.headerSize,
            let typeByte = buffer.getInteger(
                at: MemoryLayout<UInt32>.size,
                as: UInt8.self
            ),
            let type = OracleBackendMessage.ID(rawValue: typeByte),
            var packet = buffer.readSlice(length: length)
        else {
            return nil
        }

        // skip header
        if
            packet.readerIndex < Self.headerSize &&
            packet.capacity >= Self.headerSize
        {
            packet.moveReaderIndex(to: Self.headerSize)
        }

        let messages = try OracleBackendMessage.decode(
            from: &packet, of: type,
            capabilities: self.capabilities
        )
        return messages
    }
}

struct OracleBackendMessageDecoderOld: NIOSingleStepByteToMessageDecoder {

    static let headerSize = 8

    typealias InboundOut = OracleBackendMessage

    /// This might not be needed but lets have it in case I am wrong.
    private(set) var hasAlreadyReceivedBytes: Bool

    private var capabilities: Capabilities

    init(hasAlreadyReceivedBytes: Bool = false, capabilities: Capabilities) {
        self.hasAlreadyReceivedBytes = hasAlreadyReceivedBytes
        self.capabilities = capabilities
    }

    func decode(buffer: inout ByteBuffer) throws -> OracleBackendMessage? {
        let length: Int?
        if capabilities.protocolVersion >= Constants.TNS_VERSION_MIN_LARGE_SDU {
            length = buffer.getInteger(at: 0, as: UInt32.self).map(Int.init)
        } else {
            length = buffer.getInteger(at: 0, as: UInt16.self).map(Int.init)
        }
        guard
            let length,
            buffer.readableBytes >= Self.headerSize,
            let typeByte = buffer.getInteger(
                at: MemoryLayout<UInt32>.size,
                as: UInt8.self
            ),
            let type = OracleBackendMessage.ID(rawValue: typeByte),
            var packet = buffer.readSlice(length: length)
        else {
            return nil
        }

        // skip header
        if
            packet.readerIndex < Self.headerSize &&
            packet.capacity >= Self.headerSize
        {
            packet.moveReaderIndex(to: Self.headerSize)
        }

        return try OracleBackendMessage.decode(
            from: &packet, of: type,
            capabilities: self.capabilities
        ).first
    }

    mutating func decodeLast(
        buffer: inout NIOCore.ByteBuffer,
        seenEOF: Bool
    ) throws -> OracleBackendMessage? {
        try self.decode(buffer: &buffer)
    }
}