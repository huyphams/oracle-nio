import NIOCore

/// A representation of a cell value within a ``OracleRow`` and ``OracleRandomAccessRow``.
public struct OracleCell: Sendable, Equatable {
    /// The cell's value as raw bytes.
    public var bytes: ByteBuffer?
    /// The cell's data type. This is important metadata when decoding the cell.
    public var dataType: DBType

    /// The cell's column name within the row.
    public var columnName: String
    /// The cell's column index within the row.
    public var columnIndex: Int

    public init(
        bytes: ByteBuffer? = nil,
        dataType: DBType,
        columnName: String,
        columnIndex: Int
    ) {
        self.bytes = bytes
        self.dataType = dataType
        self.columnName = columnName
        self.columnIndex = columnIndex
    }
}

extension OracleCell {
    /// Decode the cell into a Swift type, that conforms to ``OracleDecodable``.
    ///
    /// - Parameters:
    ///   - _:  The Swift type, which conforms to ``OracleDecodable``, to decode from the cell's
    ///     ``OracleCell/bytes`` values.
    ///   - context: A ``OracleDecodingContext`` to supply a custom
    ///   ``OracleJSONDecoder`` for decoding JSON fields.
    ///   - file: The source file in which this methods was called. Used in the error case in
    ///   ``OracleDecodingError``.
    ///   - line: The source file line in which this method was called. Used in the error case in
    ///   ``OracleDecodingError``.
    /// - Returns: A decoded Swift type.
    @inlinable
    public func decode<T: OracleDecodable, JSONDecoder: OracleJSONDecoder>(
        _: T.Type,
        context: OracleDecodingContext<JSONDecoder>,
        file: String = #fileID, line: Int = #line
    ) throws -> T {
        var copy = self.bytes
        do {
            return try T._decodeRaw(
                from: &copy, type: self.dataType, context: context
            )
        } catch let code as OracleDecodingError.Code {
            throw OracleDecodingError(
                code: code,
                columnName: self.columnName,
                columnIndex: self.columnIndex,
                targetType: T.self,
                oracleType: self.dataType,
                oracleData: copy,
                file: file,
                line: line
            )
        }
    }

    @inlinable
    public func decode<T: OracleDecodable>(
        _: T.Type, file: String = #fileID, line: Int = #line
    ) throws -> T {
        try self.decode(T.self, context: .default, file: file, line: line)
    }
}