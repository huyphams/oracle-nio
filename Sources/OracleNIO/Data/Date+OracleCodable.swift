import NIOCore
import struct Foundation.Calendar
import struct Foundation.Date
import struct Foundation.DateComponents
import struct Foundation.TimeZone

extension Date: OracleEncodable {
    public static var oracleType: DBType { .timestampTZ }

    public func encode<JSONEncoder: OracleJSONEncoder>(
        into buffer: inout ByteBuffer,
        context: OracleEncodingContext<JSONEncoder>
    ) {
        var length = Self.oracleType.bufferSizeFactor
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: self
        )
        let year = components.year!
        buffer.writeInteger(UInt8(year / 100 + 100))
        buffer.writeInteger(UInt8(year % 100 + 100))
        buffer.writeInteger(UInt8(components.month!))
        buffer.writeInteger(UInt8(components.day!))
        buffer.writeInteger(UInt8(components.hour! + 1))
        buffer.writeInteger(UInt8(components.minute! + 1))
        buffer.writeInteger(UInt8(components.second! + 1))
        if length > 7 {
            let fractionalSeconds =
                UInt32(components.nanosecond! / 1_000_000_000)
            if fractionalSeconds == 0 && length <= 11 {
                length = 7
            } else {
                buffer.writeInteger(
                    fractionalSeconds, endianness: .big, as: UInt32.self
                )
            }
        }
        if length > 11 {
            buffer.writeInteger(Constants.TZ_HOUR_OFFSET)
            buffer.writeInteger(Constants.TZ_MINUTE_OFFSET)
        }
    }
}

extension Date: OracleDecodable {
    public init<JSONDecoder: OracleJSONDecoder>(
        from buffer: inout ByteBuffer,
        type: OracleDataType,
        context: OracleDecodingContext<JSONDecoder>
    ) throws {
        switch type {
        case .date, .timestamp, .timestampLTZ, .timestampTZ:
            let length = buffer.readableBytes
            guard 
                length >= 7,
                let firstSevenBytes = buffer.readBytes(length: 7)
            else {
                throw OracleDecodingError.Code.missingData
            }

            let year = (Int(firstSevenBytes[0]) - 100) * 100 + 
                Int(firstSevenBytes[1]) - 100
            let month = Int(firstSevenBytes[2])
            let day = Int(firstSevenBytes[3])
            let hour = Int(firstSevenBytes[4]) - 1
            let minute = Int(firstSevenBytes[5]) - 1
            let second = Int(firstSevenBytes[6]) - 1

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            var components = DateComponents(
                calendar: calendar,
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute,
                second: second
            )

            if length >= 11, let value = buffer.readInteger(
                endianness: .big, as: UInt32.self
            ) {
                let fsecond = Double(value) / 1000.0
                components.nanosecond = Int(fsecond * 1_000_000_000)
            }

            let (byte11, byte12) = buffer
                .readMultipleIntegers(as: (UInt8, UInt8).self) ?? (0, 0)

            if length > 11 && byte11 != 0 && byte12 != 0 {
                if byte11 & Constants.TNS_HAS_REGION_ID != 0 {
                    // Named time zones are not supported
                    throw OracleDecodingError.Code.failure
                }

                let tzHour = Int(byte11 - Constants.TZ_HOUR_OFFSET)
                let tzMinute = Int(byte12 - Constants.TZ_MINUTE_OFFSET)
                if tzHour != 0 || tzMinute != 0 {
                    guard let timeZone = TimeZone(
                        secondsFromGMT: tzHour * 3600 + tzMinute * 60
                    ) else {
                        throw OracleDecodingError.Code.failure
                    }
                    components.timeZone = timeZone
                }
            }

            guard let value = calendar.date(from: components) else {
                throw OracleDecodingError.Code.failure
            }
            self = value
        default:
            throw OracleDecodingError.Code.typeMismatch
        }
    }
}