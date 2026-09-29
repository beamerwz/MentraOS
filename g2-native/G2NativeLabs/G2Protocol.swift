import Foundation

enum G2NativeProtocol {
    static let serviceUUID = "00002760-08C2-11E1-9073-0E8AC72E0000"
    static let writeUUID = "00002760-08C2-11E1-9073-0E8AC72E5401"
    static let notifyUUID = "00002760-08C2-11E1-9073-0E8AC72E5402"
    static let audioUUID = "00002760-08C2-11E1-9073-0E8AC72E6402"

    static let deviceSettingsService: UInt8 = 0x80
    static let onboardingService: UInt8 = 0x10
    static let evenHubService: UInt8 = 0xE0
    static let header: UInt8 = 0xAA
    static let sourcePhone: UInt8 = 1
    static let destinationGlasses: UInt8 = 2
    static let maxPayload = 236

    static func serial(from manufacturerData: Data) -> String? {
        guard manufacturerData.count >= 16 else { return nil }
        let sn = manufacturerData[2..<16]
        return String(data: sn, encoding: .ascii)?
            .replacingOccurrences(of: "[\\x00-\\x1F\\x7F]", with: "", options: .regularExpression)
    }

    static func auth(magic: Int32) -> Data {
        var root = PBWriter()
        root.int32(1, 4)
        root.int32(2, magic)
        var auth = PBWriter()
        auth.bool(1, true)
        auth.int32(2, 3) // PHONE_IOS
        root.message(3, auth.data)
        return root.data
    }

    static func pipeRoleChange(magic: Int32) -> Data {
        var root = PBWriter()
        root.int32(1, 5)
        root.int32(2, magic)
        var role = PBWriter()
        role.int32(1, 1) // RIGHT
        root.message(4, role.data)
        return root.data
    }

    static func timeSync(magic: Int32, now: Date = Date()) -> Data {
        var root = PBWriter()
        root.int32(1, 128)
        root.int32(2, magic)
        var ts = PBWriter()
        let seconds = Int64(now.timeIntervalSince1970)
        let tz = Int64(TimeZone.current.secondsFromGMT(for: now))
        ts.int32(1, Int32(truncatingIfNeeded: seconds + tz))
        root.message(128, ts.data)
        return root.data
    }

    static func onboardingFinish(magic: Int32) -> Data {
        var root = PBWriter()
        root.int32(1, 1)
        root.int32(2, magic)
        var config = PBWriter()
        config.int32(1, 4) // FINISH
        root.message(3, config.data)
        return root.data
    }

    static func audioControl(enabled: Bool, magic: Int32) -> Data {
        var root = PBWriter()
        root.int32(1, 15)
        root.int32(2, magic)
        var audio = PBWriter()
        audio.int32(1, enabled ? 1 : 0)
        root.message(18, audio.data)
        return root.data
    }

    static func parseAuthResponse(_ payload: Data) -> Bool? {
        var reader = PBReader(payload)
        let fields = reader.fields()
        guard (fields[1] as? Int32) == 4,
              let authData = fields[3] as? Data else { return nil }
        var authReader = PBReader(authData)
        let authFields = authReader.fields()
        guard let sec = authFields[1] as? Int32 else { return nil }
        return sec != 0
    }
}

struct PBWriter {
    private(set) var data = Data()

    mutating func varint(_ value: UInt64) {
        var v = value
        while v > 0x7F {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    mutating func int32(_ field: Int, _ value: Int32) {
        varint(UInt64(field << 3))
        if value >= 0 { varint(UInt64(value)) }
        else { varint(UInt64(bitPattern: Int64(value))) }
    }

    mutating func bool(_ field: Int, _ value: Bool) { int32(field, value ? 1 : 0) }

    mutating func message(_ field: Int, _ value: Data) {
        varint(UInt64(field << 3) | 2)
        varint(UInt64(value.count))
        data.append(value)
    }
}

struct PBReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) { self.data = data }

    mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count {
            let b = data[data.startIndex + offset]
            offset += 1
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    mutating func readBytes() -> Data? {
        guard let raw = readVarint() else { return nil }
        let n = Int(raw)
        guard offset + n <= data.count else { return nil }
        let result = Data(data[(data.startIndex + offset)..<(data.startIndex + offset + n)])
        offset += n
        return result
    }

    mutating func fields() -> [Int: Any] {
        var output: [Int: Any] = [:]
        while offset < data.count {
            guard let tag = readVarint() else { break }
            let field = Int(tag >> 3)
            let wire = Int(tag & 7)
            switch wire {
            case 0:
                if let value = readVarint() { output[field] = Int32(truncatingIfNeeded: value) }
            case 2:
                if let value = readBytes() { output[field] = value }
            case 1:
                offset = min(data.count, offset + 8)
            case 5:
                offset = min(data.count, offset + 4)
            default:
                return output
            }
        }
        return output
    }
}

private func g2CRC16(_ data: Data) -> UInt16 {
    var crc: UInt16 = 0xFFFF
    for byte in data {
        crc = ((crc >> 8) | ((crc << 8) & 0xFF00)) ^ UInt16(byte)
        crc ^= (crc & 0xFF) >> 4
        crc ^= (crc << 12) & 0xFFFF
        crc ^= ((crc & 0xFF) << 5) & 0xFFFF
    }
    return crc
}

final class G2PacketCodec {
    private var sync: UInt8 = 0
    private var magic: UInt8 = 0
    private var partials: [String: Data] = [:]

    func nextMagic() -> Int32 {
        defer { magic = magic &+ 1 }
        return Int32(magic)
    }

    func packets(service: UInt8, payload: Data, reserve: Bool = false) -> [Data] {
        defer { sync = sync &+ 1 }
        var chunks: [Data] = []
        var offset = 0
        while offset < payload.count {
            let end = min(offset + G2NativeProtocol.maxPayload, payload.count)
            chunks.append(Data(payload[offset..<end]))
            offset = end
        }
        if chunks.isEmpty { chunks = [Data()] }
        if chunks.last?.count == G2NativeProtocol.maxPayload { chunks.append(Data()) }

        let total = UInt8(chunks.count)
        let crc = g2CRC16(payload)
        return chunks.enumerated().map { index, chunk in
            let serial = UInt8(index + 1)
            let last = serial == total
            var out = Data([
                G2NativeProtocol.header,
                (G2NativeProtocol.destinationGlasses << 4) | G2NativeProtocol.sourcePhone,
                sync,
                UInt8(chunk.count + (last ? 2 : 0)),
                total,
                serial,
                service,
                reserve ? 0x20 : 0x00
            ])
            out.append(chunk)
            if last {
                out.append(UInt8(crc & 0xFF))
                out.append(UInt8((crc >> 8) & 0xFF))
            }
            return out
        }
    }

    func receive(_ raw: Data, side: String) -> (UInt8, Data)? {
        guard raw.count >= 10, raw[0] == G2NativeProtocol.header else { return nil }
        let payloadLength = Int(raw[3])
        guard raw.count >= payloadLength + 8 else { return nil }
        let total = raw[4], serial = raw[5], service = raw[6], syncId = raw[2]
        let status = raw[7]
        guard ((status >> 1) & 0x0F) == 0 else { return nil }
        let last = serial == total
        let end = 8 + payloadLength - (last ? 2 : 0)
        guard end >= 8, end <= raw.count else { return nil }
        let piece = Data(raw[8..<end])
        let key = "\(side)-\(service)-\(syncId)"
        var assembled = partials[key] ?? Data()
        assembled.append(piece)
        if last {
            partials.removeValue(forKey: key)
            return (service, assembled)
        }
        partials[key] = assembled
        return nil
    }
}
