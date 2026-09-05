import Foundation

// smcfan — controle minimo dos fans via SMC.
//
//   smcfan read              -> JSON com os fans (nao precisa root)
//   smcfan set <i> <rpm>     -> forca a rotacao-alvo do fan i (precisa root)
//   smcfan auto [<i>]        -> devolve o fan i (ou todos) ao controle automatico (precisa root)
//
// Chaves por fan no Apple Silicon: F{i}Ac (atual), F{i}Mn (min), F{i}Mx (max),
// F{i}Tg (alvo, tipo "flt "), F{i}Md (modo, "ui8 ": 0=auto, 1=forcado).

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("erro: " + msg + "\n").utf8))
    exit(1)
}

func fanCount(_ smc: SMC) -> Int {
    // FNum informa a quantidade de fans.
    if let v = try? smc.read("FNum") { return Int(v.double) }
    return 1
}

func readFans(_ smc: SMC) -> [[String: Any]] {
    let count = fanCount(smc)
    var fans: [[String: Any]] = []
    for i in 0..<count {
        func g(_ suffix: String) -> Double? { try? smc.read("F\(i)\(suffix)").double }
        var fan: [String: Any] = ["index": i]
        if let a = g("Ac") { fan["actual"] = Int(a.rounded()) }
        if let mn = g("Mn") { fan["min"] = Int(mn.rounded()) }
        if let mx = g("Mx") { fan["max"] = Int(mx.rounded()) }
        if let tg = g("Tg") { fan["target"] = Int(tg.rounded()) }
        if let md = g("Md") { fan["mode"] = Int(md) }  // 0=auto, 1=forcado
        fans.append(fan)
    }
    return fans
}

func cmdRead(_ smc: SMC) {
    let out: [String: Any] = ["fans": readFans(smc)]
    let data = try! JSONSerialization.data(withJSONObject: out,
                                           options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

func cmdSet(_ smc: SMC, index: Int, rpm: Int) {
    // Trava o alvo dentro do min/max que o proprio SMC declara, por seguranca.
    var target = Double(rpm)
    if let mn = try? smc.read("F\(index)Mn").double { target = max(target, mn) }
    if let mx = try? smc.read("F\(index)Mx").double { target = min(target, mx) }

    // So escreve o modo quando ainda nao esta em "forcado" (1). Evita martelar
    // o F0Md e, mantendo o modo estavel, impede o fan de cair pro estado 3.
    let mode = Int((try? smc.read("F\(index)Md").double) ?? 0)
    if mode != 1 {
        do {
            try smc.writeUInt8("F\(index)Md", 1)
        } catch {
            // A firmware recusa assumir o manual quando o fan esta em repouso
            // profundo (mode=3, fan desligado a frio). Sinaliza com codigo 3.
            if mode == 3 {
                FileHandle.standardError.write(Data("erro: fan em repouso (mode=3): só dá pra assumir com o fan girando\n".utf8))
                exit(3)
            }
            fail("não foi possível forçar o modo do fan \(index): \(error)")
        }
    }
    do {
        try smc.writeFloat("F\(index)Tg", Float(target))     // rotacao-alvo
    } catch {
        fail("não foi possível ajustar a rotação do fan \(index): \(error)")
    }
    print("fan \(index) -> \(Int(target)) rpm")
}

func cmdAuto(_ smc: SMC, index: Int?) {
    let indices = index.map { [$0] } ?? Array(0..<fanCount(smc))
    for i in indices {
        let mode = Int((try? smc.read("F\(i)Md").double) ?? 0)
        if mode != 0 {
            do { try smc.writeUInt8("F\(i)Md", 0) }          // volta ao automatico
            catch { fail("não foi possível devolver o fan \(i) ao automático (precisa de root?): \(error)") }
        }
    }
    print("fan(s) \(indices.map(String.init).joined(separator: ",")) em modo automático")
}

// --- dispatch ---

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    fail("uso: smcfan read | temp | set <i> <rpm> | auto [<i>]")
}

let smc: SMC
do { smc = try SMC() }
catch { fail("SMC indisponível: \(error)") }

switch cmd {
case "read":
    cmdRead(smc)
case "set":
    guard args.count >= 3, let i = Int(args[1]), let rpm = Int(args[2]) else {
        fail("uso: smcfan set <i> <rpm>")
    }
    cmdSet(smc, index: i, rpm: rpm)
case "auto":
    let i = args.count >= 2 ? Int(args[1]) : nil
    cmdAuto(smc, index: i)
case "temp":
    // Temperatura media do CPU (media dos sensores de die).
    if let avg = smc.cpuTemperature() {
        print(String(format: "%.1f", avg))
    } else {
        fail("não foi possível ler a temperatura do CPU")
    }
case "mode":
    // Diagnostico: escreve SO o F0Md (sem tocar no alvo). Uso: smcfan mode <n>
    guard args.count >= 2, let v = Int(args[1]) else { fail("uso: smcfan mode <n>") }
    do {
        try smc.writeUInt8("F0Md", UInt8(v))
        print("F0Md -> \((try? smc.read("F0Md").double) ?? -1)")
    } catch {
        fail("não foi possível escrever F0Md=\(v): \(error)")
    }
default:
    fail("comando desconhecido: \(cmd)")
}
