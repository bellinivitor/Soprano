import Foundation
import IOKit

/// Erros da camada SMC.
enum SMCError: Error, CustomStringConvertible {
    case driverNotFound
    case openFailed(kern_return_t)
    case callFailed(kern_return_t)
    case smcError(UInt8)            // result != 0 vindo do SMC
    case keyNotFound(String)
    case unsupportedType(String)

    var description: String {
        switch self {
        case .driverNotFound:        return "AppleSMC nao encontrado"
        case .openFailed(let r):     return "falha ao abrir conexao (0x\(String(r, radix: 16)))"
        case .callFailed(let r):     return "chamada ao SMC falhou (0x\(String(r, radix: 16)))"
        case .smcError(let r):       return "SMC retornou erro (result=\(r))"
        case .keyNotFound(let k):    return "chave \(k) nao existe neste Mac"
        case .unsupportedType(let t):return "tipo de dado nao suportado: \(t)"
        }
    }
}

/// Converte "F0Ac" no FourCharCode (UInt32) que o SMC espera.
private func fourCC(_ s: String) -> UInt32 {
    precondition(s.utf8.count == 4, "chave SMC deve ter 4 caracteres: \(s)")
    var r: UInt32 = 0
    for b in s.utf8 { r = (r << 8) | UInt32(b) }
    return r
}

/// Converte um FourCharCode de volta pra string (usado pra mostrar o tipo).
private func fourCCString(_ v: UInt32) -> String {
    let bytes = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
                 UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    return String(bytes: bytes, encoding: .ascii) ?? "?"
}

/// Valor tipado lido de uma chave.
struct SMCValue {
    let type: String        // ex: "flt ", "ui8 "
    let bytes: [UInt8]      // dados crus (little-endian como o SMC entrega)

    /// Interpreta como numero, cobrindo os tipos usados por fans/temperatura.
    var double: Double {
        switch type {
        case "flt ":
            let f = bytes.prefix(4).enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << (8 * $1.offset)) }
            return Double(Float(bitPattern: f))
        case "ui8 ", "si8 ":
            return Double(bytes.first ?? 0)
        case "ui16", "si16":
            // Inteiros do SMC sao big-endian (byte mais significativo primeiro).
            let v = (UInt16(bytes.first ?? 0) << 8) | UInt16(bytes.count > 1 ? bytes[1] : 0)
            return Double(v)
        case "ui32", "si32":
            let v = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return Double(v)
        case "fpe2":  // ponto fixo 14.2 big-endian (fans em Macs Intel)
            let v = (UInt16(bytes.first ?? 0) << 8) | UInt16(bytes.count > 1 ? bytes[1] : 0)
            return Double(v) / 4.0
        default:
            return Double(bytes.first ?? 0)
        }
    }
}

/// Wrapper fino sobre o user client do AppleSMC.
final class SMC {
    private var conn: io_connect_t = 0

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.driverNotFound }
        defer { IOObjectRelease(service) }

        let r = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard r == kIOReturnSuccess else { throw SMCError.openFailed(r) }
    }

    deinit {
        if conn != 0 { IOServiceClose(conn) }
    }

    // Chamada bruta ao SMC.
    private func call(_ input: inout SMCKeyData_t) throws -> SMCKeyData_t {
        var output = SMCKeyData_t()
        var outSize = MemoryLayout<SMCKeyData_t>.stride
        let inSize = MemoryLayout<SMCKeyData_t>.stride

        let r = IOConnectCallStructMethod(conn, UInt32(kSMCHandleYPCEvent),
                                          &input, inSize, &output, &outSize)
        guard r == kIOReturnSuccess else { throw SMCError.callFailed(r) }
        guard output.result == 0 else {
            if output.result == 132 { throw SMCError.keyNotFound(fourCCString(input.key)) }
            throw SMCError.smcError(output.result)
        }
        return output
    }

    // Descobre tamanho e tipo de uma chave.
    private func keyInfo(_ key: UInt32) throws -> (size: UInt32, type: UInt32) {
        var input = SMCKeyData_t()
        input.key = key
        input.data8 = UInt8(kSMCCmdReadKeyInfo)
        let out = try call(&input)
        return (out.keyInfo.dataSize, out.keyInfo.dataType)
    }

    /// Le uma chave e devolve valor tipado.
    func read(_ keyStr: String) throws -> SMCValue {
        let key = fourCC(keyStr)
        let info = try keyInfo(key)

        var input = SMCKeyData_t()
        input.key = key
        input.keyInfo.dataSize = info.size
        input.data8 = UInt8(kSMCCmdReadBytes)
        let out = try call(&input)

        let n = Int(min(info.size, 32))
        let tuple = out.bytes
        var raw = [UInt8](repeating: 0, count: 32)
        withUnsafeBytes(of: tuple) { buf in
            for i in 0..<32 { raw[i] = buf[i] }
        }
        return SMCValue(type: fourCCString(info.type), bytes: Array(raw.prefix(n)))
    }

    /// Escreve bytes crus numa chave (respeitando o tamanho declarado pela chave).
    func write(_ keyStr: String, bytes: [UInt8]) throws {
        let key = fourCC(keyStr)
        let info = try keyInfo(key)

        var input = SMCKeyData_t()
        input.key = key
        input.keyInfo.dataSize = info.size
        input.data8 = UInt8(kSMCCmdWriteBytes)

        let n = Int(min(info.size, 32))
        withUnsafeMutableBytes(of: &input.bytes) { buf in
            for i in 0..<n { buf[i] = i < bytes.count ? bytes[i] : 0 }
        }
        _ = try call(&input)
    }

    /// Escreve um Float32 (tipo "flt ") — usado pra rotacao-alvo no Apple Silicon.
    func writeFloat(_ keyStr: String, _ value: Float) throws {
        var bits = value.bitPattern.littleEndian
        let bytes = withUnsafeBytes(of: &bits) { Array($0) }
        try write(keyStr, bytes: bytes)
    }

    /// Escreve um UInt8 (tipo "ui8 ") — usado pro modo do fan (0=auto, 1=forcado).
    func writeUInt8(_ keyStr: String, _ value: UInt8) throws {
        try write(keyStr, bytes: [value])
    }

    // MARK: - Enumeracao de chaves (para descobrir sensores de temperatura)

    /// Nome da chave no indice dado (SMC guarda todas as chaves numa lista).
    private func keyName(atIndex index: Int) throws -> String {
        var input = SMCKeyData_t()
        input.data8 = UInt8(kSMCCmdReadIndex)
        input.data32 = UInt32(index)
        let out = try call(&input)
        return fourCCString(out.key)
    }

    /// Lista todas as chaves do SMC. `#KEY` informa a quantidade total.
    func allKeys() throws -> [String] {
        let total = Int((try read("#KEY")).double)
        var keys: [String] = []
        keys.reserveCapacity(total)
        for i in 0..<total {
            if let k = try? keyName(atIndex: i) { keys.append(k) }
        }
        return keys
    }

    // Cache dos sensores de temperatura do CPU (enumerar e um trabalho caro).
    private var cachedCPUTempKeys: [String]?

    /// Temperatura media do CPU: media dos sensores de die "Tp.." (tipo float),
    /// descartando leituras fora de uma faixa plausivel.
    func cpuTemperature() -> Double? {
        if cachedCPUTempKeys == nil {
            let all = (try? allKeys()) ?? []
            // "Tp" = sensores de die dos nucleos do CPU no Apple Silicon.
            cachedCPUTempKeys = all.filter { $0.hasPrefix("Tp") }
        }
        var temps: [Double] = []
        for k in cachedCPUTempKeys ?? [] {
            guard let v = try? read(k), v.type == "flt " else { continue }
            let t = v.double
            if t > 5 && t < 115 { temps.append(t) }   // descarta 0/ruido
        }
        guard !temps.isEmpty else { return nil }
        return temps.reduce(0, +) / Double(temps.count)
    }
}
