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

import NIOCore
import NIOEmbedded
import Testing

@testable import OracleNIO

/// Values cut by a packet boundary ask for more data, and decode from the next packet, instead of trapping.
/// A binary ROWID cut just after its partition ID crashed TablePlus (TablePlus/TablePlus#3969).
@Suite(.timeLimit(.minutes(5))) struct PacketBoundaryTests {

    /// A ROWID column as a row sends it, with UB4s three bytes long
    static let rowIDColumn: [UInt8] = [
        1,  // length (not the ROWID's)
        3, 0x01, 0x02, 0x03,  // rba: UB4 in three bytes
        2, 0x00, 0x07,  // partition ID: UB2
        0,  // skipped byte
        3, 0x00, 0x12, 0x34,  // block number: UB4 in three bytes
        1, 0x05,  // slot number: UB2
    ]

    /// The row data message for one ROWID column
    static let rowDataMessage: [UInt8] =
        [OracleBackendMessage.MessageID.rowData.rawValue] + rowIDColumn

    /// The column the decoder makes of `rowIDColumn`: the ROWID's text, length prefixed
    static var decodedRowID: ByteBuffer {
        let rowID = RowID(rba: 0x01_0203, partitionID: 7, blockNumber: 0x1234, slotNumber: 5)!
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt8(rowID.description.utf8.count))
        buffer.writeString(rowID.description)
        return buffer
    }

    @Test func wholeRowIDDecodes() throws {
        var buffer = ByteBuffer(bytes: Self.rowIDColumn)
        let row = try OracleBackendMessage.RowData.decode(
            from: &buffer, context: .init(columns: .rowID))
        #expect(row == .init(columns: [.data(Self.decodedRowID)]))
        #expect(buffer.readableBytes == 0)
    }

    @Test(arguments: 0..<PacketBoundaryTests.rowIDColumn.count)
    func rowIDCutAsksForMoreData(at cut: Int) {
        var buffer = ByteBuffer(bytes: Self.rowIDColumn[..<cut])
        let error = #expect(throws: OraclePartialDecodingError.self) {
            try OracleBackendMessage.RowData.decode(from: &buffer, context: .init(columns: .rowID))
        }
        #expect(error?.category == .expectedAtLeastNRemainingBytes)
    }

    /// The row arrives in two TNS packets, cut after `cut` bytes of its message: the decoder keeps the first part
    /// and decodes the row once the second arrives. 9 is the cut of #3969, just after the partition ID.
    @Test(arguments: 1..<PacketBoundaryTests.rowDataMessage.count)
    func rowSplitAcrossPacketsDecodes(at cut: Int) throws {
        let context = OracleBackendMessageDecoder.Context(columns: .rowID)
        let channel = EmbeddedChannel(
            handler: ByteToMessageHandler(OracleBackendMessageDecoder(context: context)))
        try channel.writeInbound(Self.dataPacket(Self.rowDataMessage[..<cut], last: false))
        try channel.writeInbound(Self.dataPacket(Self.rowDataMessage[cut...], last: true))

        var rows: [OracleBackendMessage.RowData] = []
        while let containers = try channel.readInbound(as: OracleBackendMessageDecoder.InboundOut.self) {
            for container in containers {
                for message in container.messages {
                    if case .rowData(let row) = message {
                        rows.append(row)
                    }
                }
            }
        }
        #expect(rows == [.init(columns: [.data(Self.decodedRowID)])])
        #expect(try channel.finish().isClean)
    }

    @Test func threeByteUB4CutReturnsNil() {
        var buffer = ByteBuffer(bytes: [3, 0x12, 0x34, 0x56])
        #expect(buffer.readUB4() == 0x12_3456)

        buffer = ByteBuffer(bytes: [3, 0x12, 0x34])
        #expect(buffer.readUB4() == nil)

        buffer = ByteBuffer(bytes: [3, 0x12])
        #expect(buffer.readUB4() == nil)

        buffer = ByteBuffer(bytes: [3])
        #expect(buffer.readUB4() == nil)
    }

    @Test func cursorColumnCutAsksForMoreData() {
        var buffer = ByteBuffer()
        let error = #expect(throws: OraclePartialDecodingError.self) {
            try OracleBackendMessage.RowData.decode(from: &buffer, context: .init(columns: .cursor))
        }
        #expect(error?.category == .expectedAtLeastNRemainingBytes)
    }

    @Test func describeInfoCutAfterColumnCountAsksForMoreData() {
        var buffer = ByteBuffer(bytes: [
            0,  // max row size
            1, 1,  // column count
        ])
        let error = #expect(throws: OraclePartialDecodingError.self) {
            try DescribeInfo._decode(from: &buffer, context: .init(capabilities: .init()))
        }
        #expect(error?.category == .expectedAtLeastNRemainingBytes)
    }

    @Test func columnCutAfterDataTypeAsksForMoreData() {
        var buffer = ByteBuffer(bytes: [1])  // data type
        let error = #expect(throws: OraclePartialDecodingError.self) {
            try DescribeInfo.Column.decode(from: &buffer, context: .init(capabilities: .init()))
        }
        #expect(error?.category == .expectedAtLeastNRemainingBytes)
    }

    /// A TNS data packet with `payload`, its header as a server before large SDUs sends it
    static func dataPacket(_ payload: ArraySlice<UInt8>, last: Bool) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt16(OracleBackendMessageDecoder.headerSize + 2 + payload.count))
        buffer.writeInteger(UInt16(0))  // packet checksum
        buffer.writeInteger(OracleBackendMessage.ID.data.rawValue)
        buffer.writeInteger(UInt8(0))  // flags
        buffer.writeInteger(UInt16(0))  // header checksum
        buffer.writeInteger(last ? Constants.TNS_DATA_FLAGS_END_OF_REQUEST : 0)
        buffer.writeBytes(payload)
        return buffer
    }
}
