import SwiftUI

// Soprano — controle de fan estilo "barra de volume" na menu bar, com
// leitura de temperatura do CPU e curva automatica temp -> rotacao.
//
// Leitura: direto do SMC (nao precisa root).
// Escrita:  chama /usr/local/bin/smcfan via `sudo -n` (regra NOPASSWD do install.sh).

let smcfanPath = "/usr/local/bin/smcfan"

// MARK: - Modelo de um fan

struct Fan: Identifiable {
    let id: Int
    var actual: Int
    var min: Int
    var max: Int
    var target: Int
    var forced: Bool     // mode == 1
}

// MARK: - Curva automatica (pontos temperatura -> rotacao)

struct CurvePoint: Codable, Identifiable, Equatable {
    var id = UUID()
    var temp: Int   // graus C
    var rpm: Int    // rotacao-alvo
}

enum Curve {
    /// Intervalos padrao "interessantes": silencioso frio, sobe firme no calor.
    static let `default`: [CurvePoint] = [
        CurvePoint(temp: 50, rpm: 2300),   // frio -> minimo, silencioso
        CurvePoint(temp: 65, rpm: 3200),   // uso normal
        CurvePoint(temp: 75, rpm: 4400),   // carga media
        CurvePoint(temp: 85, rpm: 5600),   // carga pesada
        CurvePoint(temp: 95, rpm: 6500),   // limite -> maximo
    ]

    /// Interpola a rotacao para uma temperatura, entre os pontos da curva.
    static func rpm(for temp: Double, using points: [CurvePoint]) -> Int {
        let pts = points.sorted { $0.temp < $1.temp }
        guard let first = pts.first, let last = pts.last else { return 0 }
        if temp <= Double(first.temp) { return first.rpm }
        if temp >= Double(last.temp)  { return last.rpm }
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            if temp >= Double(a.temp) && temp <= Double(b.temp) {
                let f = (temp - Double(a.temp)) / Double(b.temp - a.temp)
                return Int((Double(a.rpm) + f * Double(b.rpm - a.rpm)).rounded())
            }
        }
        return last.rpm
    }
}

// MARK: - Leitor de temperatura (conexao SMC propria, roda fora da main thread)

actor TempReader {
    private let smc: SMC?
    init() { smc = try? SMC() }
    func average() -> Double? { smc?.cpuTemperature() }
}

// MARK: - Modo de operacao

enum FanMode: String, CaseIterable, Identifiable {
    case system = "Automatico"
    case manual = "Manual"
    case curve  = "Curva"
    var id: String { rawValue }
}

// MARK: - ViewModel

@MainActor
final class FanController: ObservableObject {
    @Published var fans: [Fan] = []
    @Published var cpuTemp: Double?
    @Published var lastError: String?
    @Published var conflictWarning: String?

    @Published var autoCurveEnabled: Bool {
        didSet { defaults.set(autoCurveEnabled, forKey: "autoCurveEnabled") }
    }
    @Published var curve: [CurvePoint] {
        didSet { persistCurve() }
    }

    private let defaults = UserDefaults.standard
    private var smc: SMC?
    private let tempReader = TempReader()
    private var timer: Timer?

    // Evita martelar o SMC: guarda a ultima rotacao pedida pelo slider.
    private var pendingWrites: [Int: Int] = [:]
    private var writeTimer: Timer?
    private var lastAutoRpm: Int?

    // Alvo manual "segurado": enquanto != nil, o app reafirma esse valor a cada
    // ciclo para manter o modo forcado e impedir o fan de cair pro estado 3
    // (a mesma estrategia do Macs Fan Control: nunca soltar o controle).
    private var manualTarget: Int?

    init() {
        smc = try? SMC()
        autoCurveEnabled = defaults.bool(forKey: "autoCurveEnabled")
        if let data = defaults.data(forKey: "fanCurve"),
           let saved = try? JSONDecoder().decode([CurvePoint].self, from: data),
           !saved.isEmpty {
            curve = saved
        } else {
            curve = Curve.default
        }

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func persistCurve() {
        if let data = try? JSONEncoder().encode(curve) {
            defaults.set(data, forKey: "fanCurve")
        }
    }

    func resetCurve() { curve = Curve.default }

    // MARK: leitura periodica

    /// Avisa se houver outro controlador de fan aberto (o conflito trava o SMC).
    private func checkConflicts() {
        let apps = NSWorkspace.shared.runningApplications
        let clash = apps.first {
            let bid = $0.bundleIdentifier ?? ""
            let name = $0.localizedName ?? ""
            return bid.localizedCaseInsensitiveContains("macsfancontrol")
                || name.localizedCaseInsensitiveContains("fan control")
        }
        conflictWarning = clash.map {
            "\($0.localizedName ?? "Outro controlador") esta aberto — feche-o: dois controladores brigando travam o fan."
        }
    }

    private func tick() {
        refresh()
        checkConflicts()
        Task {
            let t = await tempReader.average()
            await MainActor.run {
                self.cpuTemp = t
                if self.autoCurveEnabled {
                    self.applyCurveIfNeeded()
                } else if let mt = self.manualTarget {
                    // Keep-alive: reafirma o alvo manual pra segurar o modo forcado.
                    self.run(["set", "0", "\(mt)"])
                }
            }
        }
    }

    /// Le o estado atual dos fans direto do SMC.
    func refresh() {
        guard let smc else { lastError = "SMC indisponivel"; return }
        let count = Int((try? smc.read("FNum").double) ?? 1)
        var result: [Fan] = []
        for i in 0..<count {
            func g(_ s: String) -> Int? { (try? smc.read("F\(i)\(s)").double).map { Int($0.rounded()) } }
            let mn = g("Mn") ?? 0
            let mx = g("Mx") ?? 6000
            let md = g("Md") ?? 0
            result.append(Fan(id: i,
                              actual: g("Ac") ?? 0,
                              min: mn, max: mx,
                              target: g("Tg") ?? mn,
                              forced: md == 1))
        }
        fans = result
    }

    // MARK: curva automatica

    private func applyCurveIfNeeded() {
        guard autoCurveEnabled, let temp = cpuTemp, let fan = fans.first else { return }
        var rpm = Curve.rpm(for: temp, using: curve)
        rpm = min(max(rpm, fan.min), fan.max)          // trava no min/max do fan
        // Reescreve quando o alvo muda de forma relevante OU quando o modo caiu
        // (fan.forced == false): assim a curva reafirma o controle e segura o modo.
        if fan.forced, let last = lastAutoRpm, abs(last - rpm) < 40 { return }
        lastAutoRpm = rpm
        run(["set", "\(fan.id)", "\(rpm)"])
        if let idx = fans.firstIndex(where: { $0.id == fan.id }) {
            fans[idx].target = rpm
            fans[idx].forced = true
        }
    }

    // MARK: acoes do usuario

    /// Slider manual: desliga a curva e assume controle direto (e segura).
    func setTarget(_ rpm: Int, forFan index: Int) {
        autoCurveEnabled = false
        lastAutoRpm = nil
        manualTarget = rpm
        if let idx = fans.firstIndex(where: { $0.id == index }) {
            fans[idx].target = rpm
            fans[idx].forced = true
        }
        pendingWrites[index] = rpm
        writeTimer?.invalidate()
        writeTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushWrites() }
        }
    }

    private func flushWrites() {
        let writes = pendingWrites
        pendingWrites.removeAll()
        for (index, rpm) in writes { run(["set", "\(index)", "\(rpm)"]) }
    }

    func toggleAutoCurve(_ on: Bool) {
        autoCurveEnabled = on
        lastAutoRpm = nil
        manualTarget = nil
        if on {
            applyCurveIfNeeded()
        } else {
            // Desligar a curva devolve o(s) fan(s) ao controle do macOS.
            for f in fans { setSystemAuto(f.id) }
        }
    }

    /// Devolve o fan ao controle automatico do macOS e desliga a curva.
    func setSystemAuto(_ index: Int) {
        autoCurveEnabled = false
        lastAutoRpm = nil
        manualTarget = nil
        run(["auto", "\(index)"])
        if let idx = fans.firstIndex(where: { $0.id == index }) {
            fans[idx].forced = false
        }
    }

    /// Devolve TODOS os fans ao controle automatico do macOS.
    func setSystemAutoAll() {
        let ids = fans.map(\.id)
        for i in (ids.isEmpty ? [0] : ids) { setSystemAuto(i) }
    }

    /// Indica se algum fan esta sob controle do app (manual ou curva).
    var isControlling: Bool {
        autoCurveEnabled || manualTarget != nil || fans.contains { $0.forced }
    }

    /// Modo atual, derivado do estado.
    var mode: FanMode {
        if autoCurveEnabled { return .curve }
        if manualTarget != nil || (fans.first?.forced ?? false) { return .manual }
        return .system
    }

    /// Troca de modo a partir do segmented control.
    func setMode(_ m: FanMode) {
        switch m {
        case .system:
            setSystemAutoAll()
        case .manual:
            let fan = fans.first
            let t = fan?.target ?? fan?.min ?? 2300
            setTarget(t, forFan: fan?.id ?? 0)
        case .curve:
            toggleAutoCurve(true)
        }
    }

    /// Executa o smcfan com privilegio (sudo -n, sem senha via regra sudoers).
    private func run(_ smcArgs: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", smcfanPath] + smcArgs
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                lastError = msg.isEmpty
                    ? "escrita falhou (rode o install.sh para liberar o sudo sem senha)"
                    : msg.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                lastError = nil
            }
        } catch {
            lastError = "nao foi possivel executar o smcfan: \(error.localizedDescription)"
        }
    }
}

// MARK: - Formatacao

func tempLabel(_ t: Double?) -> String {
    guard let t else { return "-- C" }
    return String(format: "%.0f C", t)
}

// MARK: - UI: menu principal

struct FanRow: View {
    @ObservedObject var controller: FanController
    let fan: Fan

    private var targetBinding: Binding<Double> {
        Binding(get: { Double(fan.target) },
                set: { controller.setTarget(Int($0), forFan: fan.id) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "fanblades.fill")
                Text(controller.fans.count > 1 ? "Fan \(fan.id + 1)" : "Fan").font(.headline)
                Spacer()
                Text("\(fan.actual) rpm")
                    .font(.system(.body, design: .rounded)).bold()
            }

            HStack(spacing: 8) {
                Image(systemName: "tortoise.fill").foregroundStyle(.secondary)
                // Sempre ativo: arrastar assume o controle manual na hora
                // (setTarget desliga a curva e forca o modo).
                Slider(value: targetBinding,
                       in: Double(fan.min)...Double(fan.max), step: 50)
                Image(systemName: "hare.fill").foregroundStyle(.secondary)
            }
            .padding(.top, 6)   // respiro entre o cabecalho e a barra

            HStack {
                Text(controller.autoCurveEnabled ? "Curva: alvo \(fan.target) rpm"
                     : (fan.forced ? "Forcado: \(fan.target) rpm" : "Automatico (macOS)"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

struct MenuContent: View {
    @ObservedObject var controller: FanController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Soprano").font(.title3).bold()
                Spacer()
                Label(tempLabel(controller.cpuTemp), systemImage: "thermometer.medium")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(tempColor(controller.cpuTemp))
            }

            if controller.fans.isEmpty {
                Text("Nenhum fan detectado").foregroundStyle(.secondary)
            } else {
                ForEach(controller.fans) { fan in
                    FanRow(controller: controller, fan: fan)
                    if fan.id != controller.fans.last?.id { Divider() }
                }
            }

            Divider()
            Picker("", selection: Binding(get: { controller.mode },
                                          set: { controller.setMode($0) })) {
                ForEach(FanMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)

            if let warn = controller.conflictWarning {
                Divider()
                Label(warn, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let err = controller.lastError {
                Divider()
                Text(err).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Text("Cuidado: rotacao baixa sob carga pode superaquecer.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button("Sair") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
                Spacer()
                Button {
                    openWindow(id: "config")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.borderless)
                .help("Configurar curva")
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func tempColor(_ t: Double?) -> Color {
        guard let t else { return .secondary }
        switch t {
        case ..<70: return .green
        case ..<85: return .orange
        default:    return .red
        }
    }
}

// MARK: - UI: janela de configuracao da curva

struct ConfigWindow: View {
    @ObservedObject var controller: FanController

    // Faixas de edicao. rpmMax vem do fan (fallback 6600).
    private var rpmMax: Double { Double(controller.fans.first?.max ?? 6600) }
    private var rpmMin: Double { Double(controller.fans.first?.min ?? 1200) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Curva automatica").font(.title2).bold()
            Text("Para cada temperatura do CPU, defina a rotacao-alvo. Entre os pontos o valor e interpolado.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Temperatura").frame(width: 130, alignment: .leading)
                Text("Rotacao").frame(maxWidth: .infinity, alignment: .leading)
                Spacer().frame(width: 30)
            }
            .font(.caption).foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach($controller.curve) { $point in
                        HStack {
                            Stepper(value: $point.temp, in: 20...105, step: 1) {
                                Text("\(point.temp) C").monospacedDigit()
                            }
                            .frame(width: 130, alignment: .leading)

                            Slider(value: Binding(get: { Double(point.rpm) },
                                                  set: { point.rpm = Int($0) }),
                                   in: rpmMin...rpmMax, step: 50)
                            Text("\(point.rpm)").monospacedDigit()
                                .frame(width: 52, alignment: .trailing)

                            Button {
                                controller.curve.removeAll { $0.id == point.id }
                            } label: { Image(systemName: "minus.circle.fill") }
                                .buttonStyle(.borderless)
                                .disabled(controller.curve.count <= 2)
                        }
                    }
                }
            }
            .frame(minHeight: 160)

            HStack {
                Button {
                    let t = (controller.curve.map(\.temp).max() ?? 60) + 5
                    controller.curve.append(CurvePoint(temp: min(t, 105), rpm: Int(rpmMax)))
                } label: { Label("Adicionar ponto", systemImage: "plus") }

                Spacer()

                Button(role: .destructive) {
                    controller.resetCurve()
                } label: { Label("Resetar para o padrao", systemImage: "arrow.counterclockwise") }
            }

            Divider()
            HStack(spacing: 6) {
                Image(systemName: controller.autoCurveEnabled ? "checkmark.circle.fill" : "pause.circle")
                    .foregroundStyle(controller.autoCurveEnabled ? .green : .secondary)
                Text(controller.autoCurveEnabled
                     ? "Curva ativa — temp atual \(tempLabel(controller.cpuTemp))"
                     : "Curva desligada (ative no menu da barra)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 460, height: 380)
    }
}

// MARK: - App

@main
struct SopranoApp: App {
    @StateObject private var controller = FanController()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            let rpm = controller.fans.first?.actual ?? 0
            Image(systemName: "fanblades.fill")
            if rpm > 0 { Text("\(rpm) · \(tempLabel(controller.cpuTemp))") }
        }
        .menuBarExtraStyle(.window)

        Window("Configurar curva", id: "config") {
            ConfigWindow(controller: controller)
        }
        .windowResizability(.contentSize)
    }
}
