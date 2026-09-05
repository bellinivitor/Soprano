import SwiftUI
import UniformTypeIdentifiers

// Soprano — controle de fan estilo "barra de volume" na menu bar, com
// leitura de temperatura do CPU e curva automatica temp -> rotacao.
//
// Leitura: direto do SMC (nao precisa root).
// Escrita:  chama /usr/local/bin/smcfan via `sudo -n` (regra NOPASSWD do install.sh).

let smcfanPath = "/usr/local/bin/smcfan"
let appVersion = "1.0"

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

// MARK: - Regra por aplicativo

/// Quando o app de `bundleID` estiver aberto, forca o fan em `percent`% do range.
struct AppRule: Codable, Identifiable {
    var bundleID: String
    var name: String
    var percent: Int          // 0-100
    var id: String { bundleID }
}

// MARK: - ViewModel

@MainActor
final class FanController: ObservableObject {
    @Published var fans: [Fan] = []
    @Published var cpuTemp: Double?
    @Published var lastError: String?
    @Published var conflictWarning: String?
    @Published var activeAppRuleName: String?   // regra por app em vigor agora

    @Published var appRules: [AppRule] = [] {
        didSet { persistRules() }
    }

    // Liga/desliga o sistema de regras por app como um todo.
    @Published var rulesEnabled: Bool = true {
        didSet { defaults.set(rulesEnabled, forKey: "rulesEnabled") }
    }

    // Preferencias de exibicao na barra de menu (o icone fica sempre).
    @Published var showRpmInMenuBar: Bool = true {
        didSet { defaults.set(showRpmInMenuBar, forKey: "showRpm") }
    }
    @Published var showTempInMenuBar: Bool = true {
        didSet { defaults.set(showTempInMenuBar, forKey: "showTemp") }
    }

    /// Texto ao lado do icone na barra (respeita as preferencias).
    var menuBarText: String {
        var parts: [String] = []
        if showRpmInMenuBar, let a = fans.first?.actual, a > 0 { parts.append("\(a)") }
        if showTempInMenuBar { parts.append(tempLabel(cpuTemp)) }
        return parts.joined(separator: " · ")
    }

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

    // Regra por app em vigor (bundleID) e ultima rotacao aplicada por ela.
    private var appOverrideBundle: String?
    private var lastAppRpm: Int?
    // Regras dispensadas por acao manual do usuario (enquanto o app segue aberto).
    // Ao fechar o app, sai da lista e a regra volta a valer no proximo lancamento.
    private var dismissedRules: Set<String> = []

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
        if let data = defaults.data(forKey: "appRules"),
           let saved = try? JSONDecoder().decode([AppRule].self, from: data) {
            appRules = saved
        }
        if defaults.object(forKey: "showRpm") != nil { showRpmInMenuBar = defaults.bool(forKey: "showRpm") }
        if defaults.object(forKey: "showTemp") != nil { showTempInMenuBar = defaults.bool(forKey: "showTemp") }
        if defaults.object(forKey: "rulesEnabled") != nil { rulesEnabled = defaults.bool(forKey: "rulesEnabled") }

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

    private func persistRules() {
        if let data = try? JSONEncoder().encode(appRules) {
            defaults.set(data, forKey: "appRules")
        }
    }

    func resetCurve() { curve = Curve.default }

    // MARK: - Regras por app

    func addRule(bundleID: String, name: String, percent: Int = 90) {
        guard !bundleID.isEmpty else { return }
        if let i = appRules.firstIndex(where: { $0.bundleID == bundleID }) {
            appRules[i].percent = percent      // ja existe: so atualiza
        } else {
            appRules.append(AppRule(bundleID: bundleID, name: name, percent: percent))
        }
    }

    func removeRule(_ rule: AppRule) {
        appRules.removeAll { $0.bundleID == rule.bundleID }
    }

    /// Converte % (0-100) na rotacao dentro do min-max real do fan.
    private func percentToRpm(_ pct: Int, _ fan: Fan) -> Int {
        let p = Double(min(max(pct, 0), 100)) / 100.0
        return Int((Double(fan.min) + p * Double(fan.max - fan.min)).rounded())
    }

    /// Dispensa a regra ativa quando o usuario assume o controle manualmente.
    /// A regra volta a valer quando o app for fechado e reaberto.
    private func dismissActiveRule() {
        if let b = appOverrideBundle {
            dismissedRules.insert(b)
            appOverrideBundle = nil
            lastAppRpm = nil
            activeAppRuleName = nil
        }
    }

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
                self.applyControl()
            }
        }
    }

    /// Decide o que aplicar a cada ciclo, por prioridade:
    /// 1) regra por app aberto  2) curva  3) manual (keep-alive)  4) automatico.
    private func applyControl() {
        guard let fan = fans.first else { return }

        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        // Apps dispensados que ja fecharam saem da lista (reabrir volta a valer).
        dismissedRules = dismissedRules.intersection(running)

        // 1) Regra por aplicativo tem prioridade enquanto o app roda (se habilitado
        //    e nao dispensada manualmente). Entre varias, vale a de maior %.
        let candidate = rulesEnabled
            ? appRules.filter { running.contains($0.bundleID) && !dismissedRules.contains($0.bundleID) }
                      .max { $0.percent < $1.percent }
            : nil

        if let rule = candidate {
            let rpm = min(max(percentToRpm(rule.percent, fan), fan.min), fan.max)
            activeAppRuleName = "\(rule.name) · \(rule.percent)%"
            appOverrideBundle = rule.bundleID
            if lastAppRpm != rpm || !fan.forced {
                lastAppRpm = rpm
                run(["set", "\(fan.id)", "\(rpm)"])
                if let i = fans.firstIndex(where: { $0.id == fan.id }) {
                    fans[i].target = rpm; fans[i].forced = true
                }
            }
            return
        }

        // Sem regra ativa: encerra o override e restaura o modo base uma vez.
        if appOverrideBundle != nil {
            appOverrideBundle = nil
            lastAppRpm = nil
            activeAppRuleName = nil
            if !autoCurveEnabled && manualTarget == nil {
                setSystemAuto(fan.id)     // sem modo base -> devolve ao macOS
            }
        }

        // 2/3/4) modo base normal.
        if autoCurveEnabled {
            applyCurveIfNeeded()
        } else if let mt = manualTarget {
            run(["set", "\(fan.id)", "\(mt)"])   // keep-alive manual
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
        dismissActiveRule()      // acao manual dispensa a regra por app ativa
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
        dismissActiveRule()      // acao manual dispensa a regra por app ativa
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
        dismissActiveRule()      // acao manual dispensa a regra por app ativa
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

            if let active = controller.activeAppRuleName {
                HStack(spacing: 6) {
                    Image(systemName: "gamecontroller.fill")
                    Text("Regra ativa: \(active)")
                    Spacer()
                }
                .font(.caption).foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
            }

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
                .help("Configurações")
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

enum ConfigTab: String, CaseIterable, Identifiable {
    case curva = "Curva"
    case apps = "Aplicativos"
    case barra = "Barra"
    case sobre = "Sobre"
    var id: String { rawValue }
}

struct ConfigWindow: View {
    @ObservedObject var controller: FanController
    @State private var tab: ConfigTab = .curva

    var body: some View {
        VStack(spacing: 0) {
            // Segmented fixo no topo — sempre visivel, sem menu escondido.
            Picker("", selection: $tab) {
                ForEach(ConfigTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            Group {
                switch tab {
                case .curva: CurveTab(controller: controller)
                case .apps:  AppRulesTab(controller: controller)
                case .barra: MenuBarPrefsTab(controller: controller)
                case .sobre: AboutTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 520, height: 460)
    }
}

// Aba: sobre o app, link do repositorio e como atualizar.
struct AboutTab: View {
    private let repoURL = URL(string: "https://github.com/bellinivitor/Soprano")!

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "fanblades.fill").font(.system(size: 34))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Soprano").font(.title).bold()
                    Text("versão \(appVersion)").font(.caption).foregroundStyle(.secondary)
                }
            }

            Text("Controle das ventoinhas do Mac na barra de menu — slider, curva por temperatura e regras por aplicativo.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack(spacing: 6) {
                Image(systemName: "link").foregroundStyle(.secondary)
                Link("github.com/bellinivitor/Soprano", destination: repoURL)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Atualizações saem no GitHub — acompanhe o repositório. Para atualizar:")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("git pull && ./build.sh")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            }

            Spacer()
            Text("Feito por Vitor Bellini · Licença MIT")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// Aba: o que mostrar ao lado do icone na barra de menu.
struct MenuBarPrefsTab: View {
    @ObservedObject var controller: FanController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Barra de menu").font(.title2).bold()
            Text("Escolha o que aparece ao lado do ícone da ventoinha.")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Mostrar rotação (rpm)", isOn: $controller.showRpmInMenuBar)
                .toggleStyle(.switch)
            Toggle("Mostrar temperatura", isOn: $controller.showTempInMenuBar)
                .toggleStyle(.switch)

            Text("O ícone 🌀 continua sempre visível. Se desligar os dois, fica só o ícone.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// Aba: curva automatica por temperatura.
struct CurveTab: View {
    @ObservedObject var controller: FanController

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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// Aba: regras "quando o app X abrir, poe o fan em Y%".
struct AppRulesTab: View {
    @ObservedObject var controller: FanController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Regras por aplicativo").font(.title2).bold()
                Spacer()
                Toggle("", isOn: $controller.rulesEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            Text("Quando o app abrir, o fan vai pro % definido; ao fechar, volta pro modo anterior. Se vários estiverem abertos, vale o maior %. Mexer no controle manualmente dispensa a regra até o app fechar e reabrir.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !controller.rulesEnabled {
                Label("Regras desativadas", systemImage: "pause.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if controller.appRules.isEmpty {
                Spacer()
                Text("Nenhuma regra ainda.\nAdicione um app abaixo.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach($controller.appRules) { $rule in
                            HStack(spacing: 10) {
                                Text(rule.name).lineLimit(1)
                                    .frame(width: 150, alignment: .leading)
                                Slider(value: Binding(get: { Double(rule.percent) },
                                                      set: { rule.percent = Int($0) }),
                                       in: 0...100, step: 5)
                                Text("\(rule.percent)%").monospacedDigit()
                                    .frame(width: 44, alignment: .trailing)
                                Button {
                                    controller.removeRule(rule)
                                } label: { Image(systemName: "minus.circle.fill") }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }

            Divider()
            HStack {
                Menu {
                    let apps = runningApps()
                    if apps.isEmpty {
                        Text("Nenhum app aberto")
                    } else {
                        ForEach(apps, id: \.bundleID) { app in
                            Button(app.name) { controller.addRule(bundleID: app.bundleID, name: app.name) }
                        }
                    }
                } label: { Label("Adicionar app aberto", systemImage: "plus") }
                .frame(width: 210)

                Button {
                    if let app = browseForApp() {
                        controller.addRule(bundleID: app.bundleID, name: app.name)
                    }
                } label: { Label("Procurar…", systemImage: "folder") }
                Spacer()
            }

            if let active = controller.activeAppRuleName {
                Label("Ativa agora: \(active)", systemImage: "gamecontroller.fill")
                    .font(.caption).foregroundStyle(.green)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Apps "normais" abertos agora (com Dock/janela), ordenados por nome.
    private func runningApps() -> [(bundleID: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (String, String)? in
                guard let b = app.bundleIdentifier, let n = app.localizedName else { return nil }
                return (b, n)
            }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
            .map { (bundleID: $0.0, name: $0.1) }
    }

    /// Seletor de .app na pasta Aplicativos.
    private func browseForApp() -> (bundleID: String, name: String)? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == NSApplication.ModalResponse.OK, let url = panel.url else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        let bid = Bundle(url: url)?.bundleIdentifier ?? ""
        return (bundleID: bid, name: name)
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
            Image(systemName: "fanblades.fill")
            if !controller.menuBarText.isEmpty { Text(controller.menuBarText) }
        }
        .menuBarExtraStyle(.window)

        Window("Soprano — Configurações", id: "config") {
            ConfigWindow(controller: controller)
        }
        .windowResizability(.contentSize)
    }
}
