import NIOCore

extension OracleBackendMessage {
    struct Status: PayloadDecodable, Hashable {
        let callStatus: UInt32
        let endToEndSequenceNumber: UInt16

        static func decode(
            from buffer: inout ByteBuffer,
            capabilities: Capabilities
        ) throws -> OracleBackendMessage.Status {
            let callStatus = try buffer.throwingReadInteger(as: UInt32.self)
            let endToEndSequenceNumber = try buffer.throwingReadInteger(as: UInt16.self)
            return .init(
                callStatus: callStatus,
                endToEndSequenceNumber: endToEndSequenceNumber
            )
        }
    }
}
