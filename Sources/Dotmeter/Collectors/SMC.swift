import CDotmeter
import Foundation
import IOKit

/// Minimal AppleSMC client: enough to enumerate keys and read fans and temperature sensors. No root needed.
final class SMC {
    enum Selector: UInt8 {
        case handleYPCEvent = 2
        case readKey = 5
        case keyByIndex = 8
        case keyInfo = 9
    }

    struct KeyInfo {
        let size: UInt32
        let type: String
    }

    private var connection: io_connect_t = 0
    private var infoCache: [String: KeyInfo] = [:]

    init?() {
        precondition(MemoryLayout<SMCParamStruct>.size == 80, "SMCParamStruct layout drifted")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    static func code(_ key: String) -> UInt32 {
        key.utf8.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    static func string(_ code: UInt32) -> String {
        let bytes = [UInt8(code >> 24), UInt8((code >> 16) & 0xff), UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    private func call(_ input: SMCParamStruct) -> SMCParamStruct? {
        var input = input
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.size
        let kr = IOConnectCallStructMethod(connection, UInt32(Selector.handleYPCEvent.rawValue), &input, MemoryLayout<SMCParamStruct>.size, &output, &outputSize)
        guard kr == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    func info(for key: String) -> KeyInfo? {
        if let cached = infoCache[key] { return cached }
        var p = SMCParamStruct()
        p.key = Self.code(key)
        p.data8 = Selector.keyInfo.rawValue
        guard let out = call(p) else { return nil }
        let info = KeyInfo(size: out.keyInfo.dataSize, type: Self.string(out.keyInfo.dataType))
        infoCache[key] = info
        return info
    }

    func readBytes(_ key: String) -> (bytes: [UInt8], type: String)? {
        guard let info = info(for: key), info.size > 0, info.size <= 32 else { return nil }
        var p = SMCParamStruct()
        p.key = Self.code(key)
        p.keyInfo.dataSize = info.size
        p.data8 = Selector.readKey.rawValue
        guard let out = call(p) else { return nil }
        let bytes = withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(info.size))) }
        return (bytes, info.type)
    }

    func readDouble(_ key: String) -> Double? {
        guard let (bytes, type) = readBytes(key) else { return nil }
        return Self.decode(bytes: bytes, type: type)
    }

    static func decode(bytes b: [UInt8], type: String) -> Double? {
        switch type {
        case "flt ":
            guard b.count == 4 else { return nil }
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            let value = Float(bitPattern: bits)
            return value.isFinite ? Double(value) : nil
        case "fpe2":
            guard b.count == 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4.0
        case "sp78":
            guard b.count == 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256.0
        case "ui8 ":
            return b.count >= 1 ? Double(b[0]) : nil
        case "ui16":
            return b.count == 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) : nil
        case "ui32":
            guard b.count == 4 else { return nil }
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        default:
            return nil
        }
    }

    func keyCount() -> Int {
        Int(readDouble("#KEY") ?? 0)
    }

    func key(at index: Int) -> String? {
        var p = SMCParamStruct()
        p.data8 = Selector.keyByIndex.rawValue
        p.data32 = UInt32(index)
        guard let out = call(p) else { return nil }
        return Self.string(out.key)
    }

    func allKeys() -> [String] {
        (0..<keyCount()).compactMap { key(at: $0) }
    }
}
