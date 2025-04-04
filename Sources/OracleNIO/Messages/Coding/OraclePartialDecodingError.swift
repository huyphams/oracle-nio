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

struct OraclePartialDecodingError: Error {
    enum Category {
        case expectedAtLeastNRemainingBytes
        case fieldNotDecodable
        case unsupportedDataType
        case unknownMessageID
        case unknownControlType
    }

    let category: Category

    /// A textual description of the error.
    let description: String

    /// The file this error was thrown in.
    let file: String

    /// The line in ``file`` this error was thrown in.
    let line: Int

    static func expectedAtLeastNRemainingBytes(
        _ expected: Int, actual: Int,
        file: String = #fileID, line: Int = #line
    ) -> Self {
        OraclePartialDecodingError(
            category: .expectedAtLeastNRemainingBytes,
            description: "Expected at least '\(expected)' remaining bytes. But found \(actual).",
            file: file, line: line
        )
    }

    static func fieldNotDecodable(
        type: Any.Type, file: String = #fileID, line: Int = #line
    ) -> Self {
        OraclePartialDecodingError(
            category: .fieldNotDecodable,
            description: "Could not read '\(type)' from ByteBuffer.", file: file, line: line)
    }

    static func unsupportedDataType(
        type: _TNSDataType, file: String = #fileID, line: Int = #line
    ) -> Self {
        OraclePartialDecodingError(
            category: .unsupportedDataType,
            description: "Could not process unsupported data type '\(type)'.",
            file: file, line: line
        )
    }

    static func unknownMessageID(
        messageID: UInt8,
        file: String = #fileID,
        line: Int = #line
    ) -> Self {
        OraclePartialDecodingError(
            category: .unknownMessageID,
            description: """
                Received a message with messageID '\(messageID)'. There is no \
                message type associated with this message identifier.
                """,
            file: file,
            line: line
        )
    }

    static func unknownControlType(
        controlType: UInt16,
        file: String = #fileID,
        line: Int = #line
    ) -> Self {
        OraclePartialDecodingError(
            category: .unknownControlType,
            description: """
                Received a control packet with control type '\(controlType)'. 
                This is unhandled and should be reported, please file an issue.
                """,
            file: file,
            line: line
        )
    }
}
