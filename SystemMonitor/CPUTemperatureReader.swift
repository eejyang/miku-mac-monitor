import IOKit

final class CPUTemperatureReader {
    private enum Format: UInt32 {
        case float = 0x666C7420 // `flt `: little-endian IEEE 754
        case fixedPoint = 0x73703738 // `sp78`: big-endian signed fixed point

        var size: UInt32 {
            self == .float ? 4 : 2
        }
    }

    private let connection: io_connect_t
    private let key: UInt32
    private let format: Format

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = IO_OBJECT_NULL
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }

        // TCMz is the CPU die maximum on Apple Silicon. TC0D is the CPU diode on supported Intel Macs.
        let sensor = ["TCMz", "TC0D"].lazy.compactMap { name -> (UInt32, Format)? in
            let key = name.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard let info = Self.request(connection, key: key, command: 9), // Read key info.
                  let format = Format(rawValue: info.withUnsafeBytes({ $0.loadUnaligned(fromByteOffset: 32, as: UInt32.self) })),
                  info.withUnsafeBytes({ $0.loadUnaligned(fromByteOffset: 28, as: UInt32.self) }) == format.size else { return nil }
            return (key, format)
        }.first
        guard let (key, format) = sensor else {
            IOServiceClose(connection)
            return nil
        }
        self.connection = connection
        self.key = key
        self.format = format
    }

    deinit {
        IOServiceClose(connection)
    }

    func read() -> Double? {
        guard let result = Self.request(connection, key: key, command: 5, size: format.size) else { return nil }
        let celsius = result.withUnsafeBytes { buffer in
            switch format {
            case .float:
                let bits = buffer.loadUnaligned(fromByteOffset: 48, as: UInt32.self)
                return Double(Float(bitPattern: UInt32(littleEndian: bits)))
            case .fixedPoint:
                let bits = buffer.loadUnaligned(fromByteOffset: 48, as: Int16.self)
                return Double(Int16(bigEndian: bits)) / 256
            }
        }
        return (1...130).contains(celsius) ? celsius : nil
    }

    private static func request(_ connection: io_connect_t, key: UInt32, command: UInt8,
                                size: UInt32 = 0) -> [UInt8]? {
        // AppleSMC uses an 80-byte message with key metadata at byte 28 and data at byte 48.
        var input = [UInt8](repeating: 0, count: 80)
        input.withUnsafeMutableBytes {
            $0.storeBytes(of: key, as: UInt32.self)
            $0.storeBytes(of: size, toByteOffset: 28, as: UInt32.self)
            $0[42] = command
        }
        var output = [UInt8](repeating: 0, count: input.count)
        var outputSize = output.count
        let status = input.withUnsafeBytes { request in
            output.withUnsafeMutableBytes { reply in
                IOConnectCallStructMethod(connection, 2, request.baseAddress, request.count,
                                          reply.baseAddress, &outputSize)
            }
        }
        guard status == KERN_SUCCESS, outputSize == output.count, output[40] == 0 else { return nil }
        return output
    }
}
