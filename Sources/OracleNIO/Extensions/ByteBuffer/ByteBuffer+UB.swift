//===----------------------------------------------------------------------===//
//
// This source file is part of the OracleNIO open source project
//
// Copyright (c) 2024 Timo Zacherl and the OracleNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
// See CONTRIBUTORS.md for the list of OracleNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import struct NIOCore.ByteBuffer

extension ByteBuffer {
    mutating func throwingSkipUB1(file: String = #fileID, line: Int = #line) throws {
        try self.throwingMoveReaderIndex(forwardBy: 1, file: file, line: line)
    }

    mutating func skipUB2() {
        skipUB(2)
    }

    mutating func throwingSkipUB2(file: String = #fileID, line: Int = #line) throws {
        try throwingSkipUB(4, file: file, line: line)
    }

    mutating func readUB2() -> UInt16? {
        guard let length = readUBLength() else { return nil }
        switch length {
        case 0:
            return 0
        case 1:
            return self.readInteger(as: UInt8.self).map(UInt16.init(_:))
        case 2:
            return self.readInteger(as: UInt16.self)
        default:
            preconditionFailure()
        }
    }

    mutating func throwingReadUB2(
        file: String = #fileID, line: Int = #line
    ) throws -> UInt16 {
        try self.readUB2().value(
            or: OraclePartialDecodingError.expectedAtLeastNRemainingBytes(
                MemoryLayout<UInt16>.size, actual: self.readableBytes,
                file: file, line: line
            )
        )
    }

    mutating func readUB4() -> UInt32? {
        guard let length = readUBLength() else { return nil }
        switch length {
        case 0:
            return 0
        case 1:
            return self.readInteger(as: UInt8.self).map(UInt32.init(_:))
        case 2:
            return self.readInteger(as: UInt16.self).map(UInt32.init(_:))
        case 3:
            guard let bytes = readBytes(length: Int(length)) else { fatalError() }
            return UInt32(bytes[0]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[2])
        case 4:
            return self.readInteger(as: UInt32.self)
        default:
            preconditionFailure()
        }
    }

    mutating func throwingReadUB4(
        file: String = #fileID, line: Int = #line
    ) throws -> UInt32 {
        try self.readUB4().value(
            or: OraclePartialDecodingError.expectedAtLeastNRemainingBytes(
                MemoryLayout<Int8>.size, actual: self.readableBytes,
                file: file, line: line
            )
        )
    }

    mutating func skipUB4() {
        skipUB(4)
    }

    mutating func throwingSkipUB4(file: String = #fileID, line: Int = #line) throws {
        try throwingSkipUB(4, file: file, line: line)
    }

    mutating func readUB8() -> UInt64? {
        guard let length = readUBLength() else { return nil }
        switch length {
        case 0:
            return 0
        case 1:
            return self.readInteger(as: UInt8.self).map(UInt64.init)
        case 2:
            return self.readInteger(as: UInt16.self).map(UInt64.init)
        case 3:
            guard let bytes = readBytes(length: Int(length)) else { fatalError() }
            return UInt64(bytes[0]) << 16 | UInt64(bytes[1]) << 8 | UInt64(bytes[2])
        case 4:
            return self.readInteger(as: UInt32.self).map(UInt64.init)
        case 8:
            return self.readInteger(as: UInt64.self)
        default:
            preconditionFailure()
        }
    }

    mutating func throwingReadUB8(
        file: String = #fileID, line: Int = #line
    ) throws -> UInt64 {
        try self.readUB8().value(
            or: OraclePartialDecodingError.expectedAtLeastNRemainingBytes(
                MemoryLayout<UInt8>.size, actual: self.readableBytes,
                file: file, line: line
            )
        )
    }

    mutating func skipUB8() {
        skipUB(8)
    }

    mutating func throwingSkipUB8(file: String = #fileID, line: Int = #line) throws {
        try throwingSkipUB(8, file: file, line: line)
    }

    mutating func readUBLength() -> UInt8? {
        guard var length = self.readInteger(as: UInt8.self) else { return nil }
        if length & 0x80 != 0 {
            length = length & 0x7f
        }
        return length
    }

    mutating func writeUB2(_ integer: UInt16) {
        switch integer {
        case 0:
            self.writeInteger(UInt8(0))
        case 1...UInt16(UInt8.max):
            self.writeInteger(UInt8(1))
            self.writeInteger(UInt8(integer))
        default:
            self.writeInteger(UInt8(2))
            self.writeInteger(integer)
        }
    }

    mutating func writeUB4(_ integer: UInt32) {
        switch integer {
        case 0:
            self.writeInteger(UInt8(0))
        case 1...UInt32(UInt8.max):
            self.writeInteger(UInt8(1))
            self.writeInteger(UInt8(integer))
        case (UInt32(UInt8.max) + 1)...UInt32(UInt16.max):
            self.writeInteger(UInt8(2))
            self.writeInteger(UInt16(integer))
        default:
            self.writeInteger(UInt8(4))
            self.writeInteger(integer)
        }
    }

    mutating func writeUB8(_ integer: UInt64) {
        switch integer {
        case 0:
            self.writeInteger(UInt8(0))
        case 1...UInt64(UInt8.max):
            self.writeInteger(UInt8(1))
            self.writeInteger(UInt8(integer))
        case (UInt64(UInt8.max) + 1)...UInt64(UInt16.max):
            self.writeInteger(UInt8(2))
            self.writeInteger(UInt16(integer))
        case (UInt64(UInt16.max) + 1)...UInt64(UInt32.max):
            self.writeInteger(UInt8(4))
            self.writeInteger(UInt32(integer))
        default:
            self.writeInteger(UInt8(8))
            self.writeInteger(integer)
        }
    }

    @inline(__always)
    private mutating func skipUB(_ maxLength: Int) {
        guard let length = readUBLength() else { return }
        guard length <= maxLength else { preconditionFailure() }
        self.moveReaderIndex(forwardBy: Int(length))
    }

    @inline(__always)
    private mutating func throwingSkipUB(_ maxLength: Int, file: String = #fileID, line: Int = #line) throws {
        guard let length = readUBLength().flatMap(Int.init) else {
            throw OraclePartialDecodingError.expectedAtLeastNRemainingBytes(
                MemoryLayout<UInt8>.size,
                actual: self.readableBytes,
                file: file, line: line
            )
        }
        guard length <= maxLength else { preconditionFailure() }
        try self.throwingMoveReaderIndex(forwardBy: length, file: file, line: line)
    }
}

extension ByteBuffer {
    /// Skip a number of bytes that may or may not be chunked in the buffer.
    /// The first byte gives the length. If the length is
    /// TNS_LONG_LENGTH_INDICATOR, however, chunks are read and discarded.
    /// - Returns: `true` if all bytes could be skipped,
    /// `false` if more bytes have to be retrieved from the server in order to continue.
    @discardableResult
    mutating func skipRawBytesChunked() -> Bool {
        guard
            let length = self.readInteger(as: UInt8.self),
            readableBytes >= length
        else { return false }
        if length != Constants.TNS_LONG_LENGTH_INDICATOR {
            moveReaderIndex(forwardBy: Int(length))
        } else {
            while true {
                guard let tmp = self.readUB4() else {
                    return false
                }
                if tmp == 0 { break }
                guard readableBytes > tmp else { return false }
                moveReaderIndex(forwardBy: Int(tmp))
            }
        }
        return true
    }
}

public struct CustomOracleObject: OracleDecodable {
  public let typeOID: ByteBuffer
  public let oid: ByteBuffer
  public let snapshot: ByteBuffer
  public let data: ByteBuffer

  init(
    typeOID: ByteBuffer,
    oid: ByteBuffer,
    snapshot: ByteBuffer,
    data: ByteBuffer
  ) {
    self.typeOID = typeOID
    self.oid = oid
    self.snapshot = snapshot
    self.data = data
  }

  public static func _decodeRaw(
    from buffer: inout ByteBuffer?,
    type: OracleDataType,
    context: OracleDecodingContext
  ) throws -> CustomOracleObject {
    guard var buffer else {
      throw OracleDecodingError.Code.missingData
    }
    return try self.init(from: &buffer, type: type, context: context)
  }

  public init(
    from buffer: inout ByteBuffer,
    type: OracleDataType,
    context: OracleDecodingContext
  ) throws {
    switch type {
    case .object:
      let typeOID =
      if try buffer.throwingReadUB4() > 0 {
        try buffer.throwingReadOracleSpecificLengthPrefixedSlice()
      } else { ByteBuffer() }
      let oid =
      if try buffer.throwingReadUB4() > 0 {
        try buffer.throwingReadOracleSpecificLengthPrefixedSlice()
      } else { ByteBuffer() }
      let snapshot =
      if try buffer.throwingReadUB4() > 0 {
        try buffer.throwingReadOracleSpecificLengthPrefixedSlice()
      } else { ByteBuffer() }
      buffer.skipUB2()  // version
      let dataLength = try buffer.throwingReadUB4()
      buffer.skipUB2()  // flags
      let data =
      if dataLength > 0 {
        try buffer.throwingReadOracleSpecificLengthPrefixedSlice()
      } else { ByteBuffer() }
      self.init(typeOID: typeOID, oid: oid, snapshot: snapshot, data: data)
    default:
      throw OracleDecodingError.Code.typeMismatch
    }
  }
}

public struct OracleXML {
  public enum Value {
    case string(String)
  }
  public let value: Value

  public init(from buffer: inout ByteBuffer) throws {
    var decoder = Decoder(buffer: buffer)
    self = try decoder.decode()
  }

  init(_ value: String) {
    self.value = .string(value)
  }

  enum Error: Swift.Error {
    case unexpectedXMLType(flag: UInt32)
  }

  struct Decoder {
    var buffer: ByteBuffer

    mutating func decode() throws -> OracleXML {
      _ = try readHeader()
      buffer.moveReaderIndex(forwardBy: 1)  // xml version
      let xmlFlag = try buffer.throwingReadInteger(as: UInt32.self)
      if (xmlFlag & Constants.TNS_XML_TYPE_FLAG_SKIP_NEXT_4) != 0 {
        buffer.moveReaderIndex(forwardBy: 4)
      }
      var slice = buffer.slice()
      if (xmlFlag & Constants.TNS_XML_TYPE_STRING) != 0 {
        return .init(slice.readString(length: slice.readableBytes)!)
      } else if (xmlFlag & Constants.TNS_XML_TYPE_LOB) != 0 {
        assertionFailure("LOB not yet supported")
      }
      throw Error.unexpectedXMLType(flag: xmlFlag)
    }

    mutating func readHeader() throws -> (flags: UInt8, version: UInt8) {
      let flags = try buffer.throwingReadInteger(as: UInt8.self)
      let version = try buffer.throwingReadInteger(as: UInt8.self)
      try skipLength()
      if (flags & Constants.TNS_OBJ_NO_PREFIX_SEG) != 0 {
        return (flags, version)
      }
      let prefixSegmentLength = try self.readLength()
      buffer.moveReaderIndex(forwardBy: Int(prefixSegmentLength))
      return (flags, version)
    }

    mutating func readLength() throws -> UInt32 {
      let shortLength = try buffer.throwingReadInteger(as: UInt8.self)
      if shortLength == Constants.TNS_LONG_LENGTH_INDICATOR {
        return try buffer.throwingReadInteger()
      }
      return UInt32(shortLength)
    }

    mutating func skipLength() throws {
      if try buffer.throwingReadInteger(as: UInt8.self) == Constants.TNS_LONG_LENGTH_INDICATOR {
        buffer.moveReaderIndex(forwardBy: 4)
      }
    }
  }
}
