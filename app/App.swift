import SwiftUI
import UniformTypeIdentifiers
import Carbon.HIToolbox

// MARK: - Historico

/// Uma amostra do historico (para o grafico dos ultimos minutos).
struct FanSample: Identifiable {
    let id = UUID()
    let time: Date
    let temp: Double
    let rpm: Int
}

// MARK: - Atalho global (Carbon, sem exigir permissao de acessibilidade)

/// Registra um hotkey global e chama `action` quando pressionado.
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var action: (() -> Void)?

    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()
        guard keyCode != 0 || modifiers != 0 else { return }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            let me = Unmanaged<GlobalHotKey>.fromOpaque(userData!).takeUnretainedValue()
            me.action?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        let hkID = EventHotKeyID(signature: OSType(0x53504E31), id: 1)  // 'SPN1'
        RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        if let handlerRef { RemoveEventHandler(handlerRef); self.handlerRef = nil }
    }
}

/// Converte os modificadores do NSEvent para as flags do Carbon.
func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var m: UInt32 = 0
    if flags.contains(.command) { m |= UInt32(cmdKey) }
    if flags.contains(.option)  { m |= UInt32(optionKey) }
    if flags.contains(.control) { m |= UInt32(controlKey) }
    if flags.contains(.shift)   { m |= UInt32(shiftKey) }
    return m
}

/// Texto amigavel de um atalho (ex.: "⌃⌥⌘F"), ou "Nenhum" se vazio.
func hotKeyLabel(keyCode: UInt32, carbonMods: UInt32) -> String {
    if keyCode == 0 && carbonMods == 0 { return "Nenhum" }
    var s = ""
    if carbonMods & UInt32(controlKey) != 0 { s += "⌃" }
    if carbonMods & UInt32(optionKey)  != 0 { s += "⌥" }
    if carbonMods & UInt32(shiftKey)   != 0 { s += "⇧" }
    if carbonMods & UInt32(cmdKey)     != 0 { s += "⌘" }
    s += keyName(for: keyCode)
    return s
}

/// Nome legivel de uma tecla a partir do keyCode (Carbon).
func keyName(for keyCode: UInt32) -> String {
    let map: [UInt32: String] = [
        0:"A",11:"B",8:"C",2:"D",14:"E",3:"F",5:"G",4:"H",34:"I",38:"J",40:"K",
        37:"L",46:"M",45:"N",31:"O",35:"P",12:"Q",15:"R",1:"S",17:"T",32:"U",
        9:"V",13:"W",7:"X",16:"Y",6:"Z",
        18:"1",19:"2",20:"3",21:"4",23:"5",22:"6",26:"7",28:"8",25:"9",29:"0",
        49:"Espaço",36:"↩",48:"⇥",53:"Esc",
        122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",
        101:"F9",109:"F10",103:"F11",111:"F12"
    ]
    return map[keyCode] ?? "tecla \(keyCode)"
}

// Soprano — controle de fan estilo "barra de volume" na menu bar, com
// leitura de temperatura do CPU e curva automatica temp -> rotacao.
//
// Leitura: direto do SMC (nao precisa root).
// Escrita:  chama /usr/local/bin/smcfan via `sudo -n` (regra NOPASSWD do install.sh).

let smcfanPath = "/usr/local/bin/smcfan"
let appVersion = "0.1.1 beta"

// Checagem de atualizacao via GitHub.
let currentTag = "v0.1.1-beta"
let repoTagsURL = "https://api.github.com/repos/bellinivitor/Soprano/tags"
let repoReleasesURL = "https://github.com/bellinivitor/Soprano/releases"

/// Nucleo numerico de uma tag ("v0.1.1-beta" -> [0,1,1]), ignorando 'v' e o
/// sufixo de pre-release ('-beta').
func versionCore(_ tag: String) -> [Int] {
    var s = tag
    if s.hasPrefix("v") { s.removeFirst() }
    if let dash = s.firstIndex(of: "-") { s = String(s[..<dash]) }
    return s.split(separator: ".").map { Int($0) ?? 0 }
}

/// true se a versao `a` for mais nova que `b` (compara numero a numero).
func isNewerVersion(_ a: String, than b: String) -> Bool {
    let x = versionCore(a), y = versionCore(b)
    for i in 0..<max(x.count, y.count) {
        let xi = i < x.count ? x[i] : 0
        let yi = i < y.count ? y[i] : 0
        if xi != yi { return xi > yi }
    }
    return false   // cores iguais -> nao e "mais novo"
}

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
    case system = "Automático"
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
    @Published var safetyActive = false          // protecao termica forcando o maximo
    @Published var updateTag: String?            // tag mais recente no GitHub, se != atual
    @Published var history: [FanSample] = []     // amostras dos ultimos ~10 min

    // Atalho global que alterna 100% <-> Automatico. Vazio por padrao (0/0).
    @Published var hotKeyCode: UInt32 = 0
    @Published var hotKeyMods: UInt32 = 0
    private let hotKey = GlobalHotKey()
    static let historyWindow: TimeInterval = 600  // 10 minutos

    // Acima desta temperatura, o app forca o fan no maximo em qualquer modo.
    static let safetyTemp = 100.0

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

    // Intervalo de atualizacao (s). Limitado a uma faixa segura para nao
    // martelar o SMC nem disparar escritas rapido demais quando controlando.
    static let minRefresh = 1.0
    static let maxRefresh = 5.0
    @Published var refreshInterval: Double = 2.0 {
        didSet {
            let v = min(max(refreshInterval, Self.minRefresh), Self.maxRefresh)
            if v != refreshInterval { refreshInterval = v; return }   // reentra ja travado
            defaults.set(refreshInterval, forKey: "refreshInterval")
            startTimer()
        }
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
        if defaults.object(forKey: "refreshInterval") != nil {
            refreshInterval = min(max(defaults.double(forKey: "refreshInterval"), Self.minRefresh), Self.maxRefresh)
        }
        if defaults.object(forKey: "hotKeyCode") != nil {
            hotKeyCode = UInt32(defaults.integer(forKey: "hotKeyCode"))
            hotKeyMods = UInt32(defaults.integer(forKey: "hotKeyMods"))
        }

        hotKey.action = { [weak self] in
            Task { @MainActor in self?.boostToggle() }
        }
        hotKey.register(keyCode: hotKeyCode, modifiers: hotKeyMods)

        refresh()
        startTimer()
        checkForUpdate()
    }

    /// Redefine e re-registra o atalho global.
    func updateHotKey(keyCode: UInt32, mods: UInt32) {
        hotKeyCode = keyCode
        hotKeyMods = mods
        defaults.set(Int(keyCode), forKey: "hotKeyCode")
        defaults.set(Int(mods), forKey: "hotKeyMods")
        hotKey.register(keyCode: keyCode, modifiers: mods)
    }

    /// Guarda uma amostra e descarta o que passou da janela de 10 min.
    private func recordSample() {
        guard let temp = cpuTemp, let fan = fans.first else { return }
        history.append(FanSample(time: Date(), temp: temp, rpm: fan.actual))
        let cutoff = Date().addingTimeInterval(-Self.historyWindow)
        history.removeAll { $0.time < cutoff }
    }

    /// Ação do atalho: alterna entre 100% (manual) e Automatico.
    func boostToggle() {
        guard let fan = fans.first else { return }
        if mode == .manual && manualTarget == fan.max {
            setSystemAuto(fan.id)          // ja estava no boost -> volta ao automatico
        } else {
            setTarget(fan.max, forFan: fan.id)   // liga o boost (100%)
        }
    }

    /// Consulta as tags do repositorio no GitHub e sinaliza se a mais recente
    /// for diferente da versao instalada.
    func checkForUpdate() {
        guard let url = URL(string: repoTagsURL) else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("Soprano-app", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data,
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            let names = arr.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
            // A tag mais alta entre todas (a API nao garante ordem de versao).
            let newest = names.max { isNewerVersion($1, than: $0) }
            Task { @MainActor in
                if let newest, isNewerVersion(newest, than: currentTag) {
                    self?.updateTag = newest
                } else {
                    self?.updateTag = nil
                }
            }
        }.resume()
    }

    /// (Re)inicia o timer de leitura com o intervalo atual.
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
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
            "\($0.localizedName ?? "Outro controlador") está aberto. Feche-o: dois controladores brigando travam o fan."
        }
    }

    private func tick() {
        refresh()
        checkConflicts()
        Task {
            let t = await tempReader.average()
            await MainActor.run {
                self.cpuTemp = t
                self.recordSample()
                self.applyControl()
            }
        }
    }

    /// Decide o que aplicar a cada ciclo, por prioridade:
    /// 0) PROTECAO TERMICA  1) regra por app  2) curva  3) manual  4) automatico.
    private func applyControl() {
        guard let fan = fans.first else { return }

        // 0) FAILSAFE: acima do limite de seguranca, forca o maximo em QUALQUER
        //    modo (inclusive Automatico). O macOS as vezes deixa o fan parado
        //    mesmo muito quente; isto impede o Mac de cozinhar.
        if let t = cpuTemp, t >= Self.safetyTemp {
            safetyActive = true
            if lastAppRpm != fan.max || !fan.forced {
                lastAppRpm = fan.max
                run(["set", "\(fan.id)", "\(fan.max)"])
                if let i = fans.firstIndex(where: { $0.id == fan.id }) {
                    fans[i].target = fan.max; fans[i].forced = true
                }
            }
            return
        }
        if safetyActive {
            // Saiu do perigo: zera o marcador para o modo base reassumir.
            safetyActive = false
            lastAppRpm = nil
        }

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

        // Sem regra ativa: encerra o override (o modo base reassume abaixo).
        if appOverrideBundle != nil {
            appOverrideBundle = nil
            lastAppRpm = nil
            activeAppRuleName = nil
        }

        // 2/3/4) modo base.
        if autoCurveEnabled {
            applyCurveIfNeeded()                 // Curva: pontos do usuario
        } else if let mt = manualTarget {
            run(["set", "\(fan.id)", "\(mt)"])   // Manual: keep-alive
        } else {
            applyAutoCurve(fan)                  // Automatico: curva segura do app
        }
    }

    /// "Automatico": o proprio app gerencia com uma curva segura embutida.
    /// (O automatico do macOS nesta maquina deixa o fan parado mesmo quente,
    /// entao o app assume a responsabilidade e nunca prende o fan no minimo.)
    private func applyAutoCurve(_ fan: Fan) {
        guard let temp = cpuTemp else { return }
        var rpm = Curve.rpm(for: temp, using: Curve.default)
        rpm = min(max(rpm, fan.min), fan.max)
        if fan.forced, let last = lastAutoRpm, abs(last - rpm) < 40 { return }
        lastAutoRpm = rpm
        run(["set", "\(fan.id)", "\(rpm)"])
        if let i = fans.firstIndex(where: { $0.id == fan.id }) {
            fans[i].target = rpm; fans[i].forced = true
        }
    }

    /// Le o estado atual dos fans direto do SMC.
    func refresh() {
        guard let smc else { lastError = "SMC indisponível"; return }
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

    /// Entra no modo Automatico (curva segura gerenciada pelo app).
    func setSystemAuto(_ index: Int) {
        dismissActiveRule()      // acao manual dispensa a regra por app ativa
        autoCurveEnabled = false
        manualTarget = nil
        lastAutoRpm = nil        // forca a curva automatica a reaplicar no proximo ciclo
    }

    func setSystemAutoAll() { setSystemAuto(0) }

    /// Indica se o app esta em manual ou curva (nao no automatico).
    var isControlling: Bool {
        autoCurveEnabled || manualTarget != nil
    }

    /// Modo atual, derivado do estado.
    var mode: FanMode {
        if autoCurveEnabled { return .curve }
        if manualTarget != nil { return .manual }
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
            lastError = "não foi possível executar o smcfan: \(error.localizedDescription)"
        }
    }
}

// MARK: - Formatacao

func tempLabel(_ t: Double?) -> String {
    guard let t else { return "-- °C" }
    return String(format: "%.0f °C", t)
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
                    .foregroundStyle(fan.actual > 0 ? .primary : .secondary)
                    .opacity(fan.actual > 0 ? 1 : 0.45)
                Text(controller.fans.count > 1 ? "Fan \(fan.id + 1)" : "Fan").font(.headline)
                Spacer()
                Text(fan.actual > 0 ? "\(fan.actual) rpm" : "Desligado")
                    .font(.system(.body, design: .rounded)).bold()
                    .foregroundStyle(fan.actual > 0 ? .primary : .secondary)
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
                Text(controller.mode == .curve ? "Curva: alvo \(fan.target) rpm"
                     : (controller.mode == .manual ? "Forçado: \(fan.target) rpm" : "Automático (curva do app)"))
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

// Grafico dos ultimos 10 min: temperatura (area laranja, escala fixa 30-105C
// com faixa de perigo) e rotacao (linha azul). Valores aparecem ao passar o mouse.
struct HistoryChart: View {
    let samples: [FanSample]
    let fanMin: Int
    let fanMax: Int

    @State private var hoverX: CGFloat?
    @State private var hoverSample: FanSample?

    private let tLo = 30.0
    private let tHi = 105.0
    private let window = FanController.historyWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Label("Temperatura", systemImage: "circle.fill").foregroundStyle(.orange)
                Label("Rotação", systemImage: "circle.fill").foregroundStyle(.blue)
                Spacer()
                if let s = hoverSample {
                    Text("\(Int(s.temp.rounded()))°C · \(s.rpm) rpm")
                        .foregroundStyle(.primary).monospacedDigit()
                } else {
                    Text("últimos 10 min · passe o mouse").foregroundStyle(.secondary)
                }
            }
            .font(.caption2)

            GeometryReader { geo in
                Canvas { ctx, size in
                    let t0 = Date().addingTimeInterval(-window)
                    func x(_ d: Date) -> CGFloat { CGFloat(max(0, d.timeIntervalSince(t0)) / window) * size.width }
                    func yTemp(_ v: Double) -> CGFloat {
                        size.height * (1 - CGFloat((min(max(v, tLo), tHi) - tLo) / (tHi - tLo)))
                    }
                    func yRpm(_ v: Int) -> CGFloat {
                        let lo = Double(fanMin), hi = Double(max(fanMax, fanMin + 1))
                        return size.height * (1 - CGFloat((min(max(Double(v), lo), hi) - lo) / (hi - lo)))
                    }

                    // faixa de perigo (> 90 C)
                    let dTop = yTemp(tHi), dBot = yTemp(90)
                    ctx.fill(Path(CGRect(x: 0, y: dTop, width: size.width, height: dBot - dTop)),
                             with: .color(.red.opacity(0.10)))

                    // grade + rotulos fixos de referencia
                    for mark in [40, 60, 80, 100] {
                        let yy = yTemp(Double(mark))
                        var g = Path()
                        g.move(to: CGPoint(x: 0, y: yy)); g.addLine(to: CGPoint(x: size.width, y: yy))
                        ctx.stroke(g, with: .color(.primary.opacity(0.06)), lineWidth: 1)
                        // rotulo centrado na propria linha, travado dentro da area
                        let labelY = min(max(yy, 8), size.height - 8)
                        ctx.draw(Text("\(mark)°").font(.system(size: 8)).foregroundStyle(.secondary),
                                 at: CGPoint(x: 16, y: labelY), anchor: .center)
                    }

                    guard samples.count > 1 else { return }

                    // rotacao: linha fina de apoio
                    var rp = Path()
                    for (i, s) in samples.enumerated() {
                        let p = CGPoint(x: x(s.time), y: yRpm(s.rpm))
                        if i == 0 { rp.move(to: p) } else { rp.addLine(to: p) }
                    }
                    ctx.stroke(rp, with: .color(.blue.opacity(0.55)),
                               style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))

                    // temperatura: area + linha
                    var line = Path(), area = Path()
                    area.move(to: CGPoint(x: x(samples[0].time), y: size.height))
                    for (i, s) in samples.enumerated() {
                        let p = CGPoint(x: x(s.time), y: yTemp(s.temp))
                        if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
                        area.addLine(to: p)
                    }
                    area.addLine(to: CGPoint(x: x(samples[samples.count - 1].time), y: size.height))
                    area.closeSubpath()
                    ctx.fill(area, with: .linearGradient(
                        Gradient(colors: [.orange.opacity(0.35), .orange.opacity(0.02)]),
                        startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
                    ctx.stroke(line, with: .color(.orange),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                    // guia de hover
                    if let hx = hoverX, let s = hoverSample {
                        var v = Path()
                        v.move(to: CGPoint(x: hx, y: 0)); v.addLine(to: CGPoint(x: hx, y: size.height))
                        ctx.stroke(v, with: .color(.primary.opacity(0.3)),
                                   style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        let pT = CGPoint(x: hx, y: yTemp(s.temp))
                        let pR = CGPoint(x: hx, y: yRpm(s.rpm))
                        ctx.fill(Path(ellipseIn: CGRect(x: pR.x - 2.5, y: pR.y - 2.5, width: 5, height: 5)),
                                 with: .color(.blue))
                        ctx.fill(Path(ellipseIn: CGRect(x: pT.x - 3.5, y: pT.y - 3.5, width: 7, height: 7)),
                                 with: .color(.orange))
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let p):
                        hoverX = p.x
                        hoverSample = nearest(toX: p.x, width: geo.size.width)
                    case .ended:
                        hoverX = nil; hoverSample = nil
                    }
                }
            }
            .frame(height: 104)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        }
    }

    /// Amostra mais proxima da posicao x do cursor.
    private func nearest(toX px: CGFloat, width: CGFloat) -> FanSample? {
        guard width > 0, !samples.isEmpty else { return nil }
        let t0 = Date().addingTimeInterval(-window)
        let frac = Double(max(0, min(1, px / width)))
        let target = t0.addingTimeInterval(window * frac)
        return samples.min {
            abs($0.time.timeIntervalSince(target)) < abs($1.time.timeIntervalSince(target))
        }
    }
}

// Campo que grava um atalho global (captura a proxima combinacao com modificador).
struct HotKeyRecorderView: View {
    @ObservedObject var controller: FanController
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 10) {
            Text(hotKeyLabel(keyCode: controller.hotKeyCode, carbonMods: controller.hotKeyMods))
                .font(.system(.body, design: .rounded)).bold()
                .frame(minWidth: 90, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            Button(recording ? "Pressione as teclas…" : "Definir") { toggle() }
            if recording {
                Button("Cancelar") { stop() }.buttonStyle(.borderless)
            } else if controller.hotKeyCode != 0 || controller.hotKeyMods != 0 {
                Button("Remover") { controller.updateHotKey(keyCode: 0, mods: 0) }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func toggle() {
        if recording { stop(); return }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let mods = carbonModifiers(from: event.modifierFlags)
            guard mods != 0 else { return event }   // exige ao menos um modificador
            controller.updateHotKey(keyCode: UInt32(event.keyCode), mods: mods)
            stop()
            return nil
        }
    }
    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
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

            if controller.history.count > 1, let fan = controller.fans.first {
                HistoryChart(samples: controller.history, fanMin: fan.min, fanMax: fan.max)
            }

            Divider()
            Picker("", selection: Binding(get: { controller.mode },
                                          set: { controller.setMode($0) })) {
                ForEach(FanMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)

            if controller.safetyActive {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Proteção térmica: fan no máximo")
                    Spacer()
                }
                .font(.caption).bold().foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            }

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
            Text("Cuidado: rotação baixa sob carga pode superaquecer.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Sair") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")

                if let t = controller.updateTag {
                    Link(destination: URL(string: repoReleasesURL)!) {
                        Label("Atualizar (\(t))", systemImage: "arrow.down.circle.fill")
                            .font(.caption).bold()
                    }
                    .foregroundStyle(.orange)
                    .help("Nova versão disponível no GitHub")
                }

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
                case .sobre: AboutTab(controller: controller)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 520, height: 560)
    }
}

// Aba: sobre o app, link do repositorio e como atualizar.
struct AboutTab: View {
    @ObservedObject var controller: FanController
    private let repoURL = URL(string: "https://github.com/bellinivitor/Soprano")!
    private let releasesURL = URL(string: repoReleasesURL)!

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "fanblades.fill").font(.system(size: 34))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Soprano").font(.title).bold()
                    Text("versão \(appVersion)").font(.caption).foregroundStyle(.secondary)
                }
            }

            Text("Controle das ventoinhas do Mac na barra de menu: slider, curva por temperatura e regras por aplicativo.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            // Status de atualizacao (checado no GitHub).
            if let t = controller.updateTag {
                Link(destination: releasesURL) {
                    Label("Nova versão disponível: \(t)", systemImage: "arrow.down.circle.fill")
                }
                .foregroundStyle(.orange).bold()
            } else {
                Label("Você está na versão mais recente", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Image(systemName: "link").foregroundStyle(.secondary)
                Link("github.com/bellinivitor/Soprano", destination: repoURL)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Atualizações saem no GitHub. Acompanhe o repositório e, para atualizar, rode:")
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
        VStack(alignment: .leading, spacing: 12) {
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

            Divider()

            Text("Atualização das leituras").font(.headline)
            HStack {
                Slider(value: $controller.refreshInterval,
                       in: FanController.minRefresh...FanController.maxRefresh, step: 0.5)
                Text(String(format: "%.1f s", controller.refreshInterval))
                    .monospacedDigit().frame(width: 52, alignment: .trailing)
            }
            Text("Com que frequência a rotação e a temperatura são relidas (mín. \(String(format: "%.0f", FanController.minRefresh)) s, por segurança).")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("Atalho global (100%)").font(.headline)
            Text("Funciona em qualquer app. Aperta: fan a 100%. Aperta de novo: volta ao Automático.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HotKeyRecorderView(controller: controller)

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
            Text("Curva automática").font(.title2).bold()
            Text("Para cada temperatura do CPU, defina a rotação-alvo. Entre os pontos o valor é interpolado.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Temperatura").frame(width: 130, alignment: .leading)
                Text("Rotação").frame(maxWidth: .infinity, alignment: .leading)
                Spacer().frame(width: 30)
            }
            .font(.caption).foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach($controller.curve) { $point in
                        HStack {
                            Stepper(value: $point.temp, in: 20...105, step: 1) {
                                Text("\(point.temp) °C").monospacedDigit()
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
                } label: { Label("Resetar para o padrão", systemImage: "arrow.counterclockwise") }
            }

            Divider()
            HStack(spacing: 6) {
                Image(systemName: controller.autoCurveEnabled ? "checkmark.circle.fill" : "pause.circle")
                    .foregroundStyle(controller.autoCurveEnabled ? .green : .secondary)
                Text(controller.autoCurveEnabled
                     ? "Curva ativa · temp atual \(tempLabel(controller.cpuTemp))"
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

        Window("Configurações do Soprano", id: "config") {
            ConfigWindow(controller: controller)
        }
        .windowResizability(.contentSize)
    }
}
