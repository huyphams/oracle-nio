import NIOCore

extension Double: OracleEncodable {
    public var oracleType: DBType {
        .binaryDouble
    }

    public func encode<JSONEncoder: OracleJSONEncoder>(
        into buffer: inout ByteBuffer,
        context: OracleEncodingContext<JSONEncoder>
    ) {
        var b0, b1, b2, b3, b4, b5, b6, b7: UInt8
        let allBits = self.bitPattern
        b7 = UInt8(allBits & 0xff)
        b6 = UInt8((allBits >> 8) & 0xff)
        b5 = UInt8((allBits >> 16) & 0xff)
        b4 = UInt8((allBits >> 24) & 0xff)
        b3 = UInt8((allBits >> 32) & 0xff)
        b2 = UInt8((allBits >> 40) & 0xff)
        b1 = UInt8((allBits >> 48) & 0xff)
        b0 = UInt8((allBits >> 56) & 0xff)
        if b0 & 0x80 == 0 {
            b0 = b0 | 0x80
        } else {
            b0 = ~b0
            b1 = ~b1
            b2 = ~b2
            b3 = ~b3
            b4 = ~b4
            b5 = ~b5
            b6 = ~b6
            b7 = ~b7
        }
        buffer.writeInteger(UInt8(8))
        buffer.writeBytes([b0, b1, b2, b3, b4, b5, b6, b7])
    }
}

extension Double: OracleDecodable {
    public init<JSONDecoder: OracleJSONDecoder>(
        from buffer: inout ByteBuffer,
        type: OracleDataType,
        context: OracleDecodingContext<JSONDecoder>
    ) throws {
        switch type {
        case .number, .binaryInteger:
            self = try OracleNumeric.parseFloat(from: &buffer)
        case .binaryFloat:
            self = Double(try OracleNumeric.parseBinaryFloat(from: &buffer))
        case .binaryDouble:
            self = try OracleNumeric.parseBinaryDouble(from: &buffer)
        case .intervalDS:
            self = try IntervalDS(
                from: &buffer, type: type, context: context
            ).double
        default:
            throw OracleDecodingError.Code.typeMismatch
        }
    }
}
