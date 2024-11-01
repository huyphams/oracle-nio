# ``OracleNIO``

Non-blocking, event-driven Swift client for Oracle Databases built on SwiftNIO.

## Overview

It's like [PostgresNIO](https://github.com/vapor/postgres-nio), but written for Oracle Databases.

### Features

- An `OracleConnection` which allows you to connect to, authorize with, query, and retrieve results from an Oracle database server
- An async/await interface that supports back-pressure
- Automatic conversions between Swift primitive types and the Oracle wire format
- Integrated with the Swift server ecosystem, including use of [swift-log](https://github.com/apple/swift-log).
- Designed to run efficiently on all supported platforms (tested on Linux and Darwin systems)
- Support for `Network.framework` when available (e.g. on Apple platforms)
- An `OracleClient` ConnectionPool backed by DRCP (Database Resident Connection Pooling) if available

### Supported Oracle Database versions

Oracle Database 12.1 or later.

## Topics

### Guides

- <doc:connect-to-adb>
- <doc:stored-procedures>

### Connections

- ``OracleConnection``
- ``OracleClient``
- ``OracleAuthenticationMethod``
- ``AuthenticationMode``
- ``OracleAccessToken``
- ``OracleServiceMethod``
- ``OracleVersion``

### Querying

- ``OracleStatement``
- ``OracleBindings``
- ``OracleRow``
- ``OracleRowSequence``
- ``OracleRandomAccessRow``
- ``OracleCell``
- ``OracleColumn``
- ``StatementOptions``
- ``OraclePreparedStatement``
- ``Statement(_:)``
- ``OracleBatchExecutionResult``

### Encoding and Decoding

- ``OracleThrowingDynamicTypeEncodable``
- ``OracleDynamicTypeEncodable``
- ``OracleThrowingEncodable``
- ``OracleEncodable``
- ``OracleEncodingContext``
- ``OracleDecodable``
- ``OracleDecodingContext``
- ``OracleCodable``
- ``OracleDataType``
- ``OracleDataTypeNumber``
- ``OracleNumber``
- ``OracleRef``
- ``Cursor``
- ``RowID``
- ``IntervalDS``
- ``OracleJSON``
- ``OracleVectorProtocol``
- ``OracleVectorBinary``
- ``OracleVectorInt8``
- ``OracleVectorFloat32``
- ``OracleVectorFloat64``
- ``LOB``

### Errors

- ``OracleSQLError``
- ``OracleDecodingError``
- ``OracleBatchExecutionError``
