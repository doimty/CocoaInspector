import Foundation

enum SnapshotWireCodec {
    enum CodecError: Error, Equatable {
        case invalidSize
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count <= InspectorProtocol.maximumMessageDataByteCount else {
            throw CodecError.invalidSize
        }
        return data
    }

    static func decode(_ data: Data) throws -> ProcessSnapshot {
        try decode(data, as: ProcessSnapshot.self)
    }

    static func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        guard !data.isEmpty,
              data.count <= InspectorProtocol.maximumMessageDataByteCount else {
            throw CodecError.invalidSize
        }
        return try JSONDecoder().decode(type, from: data)
    }
}
