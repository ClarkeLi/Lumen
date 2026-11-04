// Claude Code Ampel – schwebende Ampel + Menüleisten-Symbol für den Claude-Code-Status.
//
// Funktionsweise:
//   1. Beim Start trägt die App Hooks in ~/.claude/settings.json ein.
//   2. Claude Code ruft bei jedem Ereignis dieses Binary mit `--hook` auf;
//      es schreibt den Status pro Session nach ~/.claude/traffic-light/sessions/<id>.json.
//   3. Die laufende App liest diese Dateien und zeigt den Gesamtstatus an.
//
//   🔴 rot   = arbeitet
//   🔴 + blauer Ring = Zug beendet, aber Hintergrundaufgaben (Bash/Monitor/Agent) laufen noch
//   🟡 gelb  = braucht menschliches Eingreifen (Berechtigung, Plan, Auswahlfrage …)
//   🟢 grün  = Aufgabe beendet, wartet auf neue Eingabe
//   ⚪️ grau  = keine aktive Claude-Code-Session

import AppKit
import Darwin
import ServiceManagement

// MARK: - Lokalisierung (zh / en / de, folgt der Systemsprache)

enum Lang: String { case zh, en, de }

enum I18n {
    private(set) static var lang: Lang = detect()

    /// Erste unterstützte Sprache aus den Systemeinstellungen; sonst Englisch.
    static func detect() -> Lang {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let prefs = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                           kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
            ?? Locale.preferredLanguages
        for id in prefs {
            let code = id.lowercased()
            if code.hasPrefix("zh") { return .zh }
            if code.hasPrefix("de") { return .de }
            if code.hasPrefix("en") { return .en }
        }
        return .en
    }

    /// Liest die Systemsprache neu ein; true, wenn sie sich geändert hat.
    @discardableResult
    static func refresh() -> Bool {
        let new = detect()
        defer { lang = new }
        return new != lang
    }

    static var locale: Locale {
        Locale(identifier: lang == .zh ? "zh_CN" : lang.rawValue)
    }
}

/// Wählt den Text passend zur aktuellen Sprache.
func tr(_ zh: String, _ en: String, _ de: String) -> String {
    switch I18n.lang {
    case .zh: return zh
    case .en: return en
    case .de: return de
    }
}

// MARK: - Gemeinsame Definitionen

enum LightState: String, Codable {
    case red, yellow, green, background, off

    var emoji: String {
        switch self {
        case .red: return "🔴"
        case .yellow: return "🟡"
        case .green: return "🟢"
        case .background: return "🔵"
        case .off: return "⚪️"
        }
    }

    var label: String {
        switch self {
        case .red: return tr("工作中", "Working", "Arbeitet")
        case .yellow: return tr("需要你介入", "Needs your attention", "Braucht dein Eingreifen")
        case .green: return tr("等待输入", "Waiting for input", "Wartet auf Eingabe")
        case .background: return tr("后台任务运行中", "Background tasks running", "Hintergrundaufgaben laufen")
        case .off: return tr("未检测到 Claude Code", "Claude Code not detected", "Claude Code nicht erkannt")
        }
    }

    // Priorität bei mehreren Sessions: gelb > rot > blau > grün
    var priority: Int {
        switch self {
        case .yellow: return 4
        case .red: return 3
        case .background: return 2
        case .green: return 1
        case .off: return 0
        }
    }
}

struct SessionRecord: Codable {
    var sessionId: String
    var state: LightState
    var event: String
    var cwd: String
    var pid: Int32
    var transcript: String
    var updated: Double
}

let appMarker = "ClaudeTrafficLight"
let baseDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/traffic-light")
let sessionsDir = baseDir.appendingPathComponent("sessions")
let settingsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")

// MARK: - Hook-Modus (wird von Claude Code aufgerufen)

/// Liefert Elternprozess-ID und Namen eines Prozesses.
func processInfo(_ pid: pid_t) -> (ppid: pid_t, name: String)? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let name = withUnsafePointer(to: &info.kp_proc.p_comm) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
    }
    return (info.kp_eproc.e_ppid, name)
}

/// Sucht im Prozessbaum nach oben den Claude-Code-Prozess, um später prüfen zu können, ob er noch lebt.
func findClaudePid() -> Int32 {
    var pid = getppid()
    for _ in 0..<6 {
        guard let info = processInfo(pid) else { break }
        let n = info.name.lowercased()
        if n.contains("claude") || n == "node" || n == "bun" { return pid }
        if info.ppid <= 1 { break }
        pid = info.ppid
    }
    return getppid()
}

func runHook() -> Never {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let sessionId = json["session_id"] as? String, !sessionId.isEmpty else { exit(0) }

    let event = json["hook_event_name"] as? String ?? ""
    let file = sessionsDir.appendingPathComponent("\(sessionId).json")
    try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

    if event == "SessionEnd" {
        try? FileManager.default.removeItem(at: file)
        exit(0)
    }

    let old = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(SessionRecord.self, from: $0) }
    var state: LightState? = nil

    switch event {
    case "SessionStart", "Stop":
        state = .green
    case "UserPromptSubmit", "PostToolUse":
        state = .red
    case "PreToolUse":
        let tool = json["tool_name"] as? String ?? ""
        state = ["AskUserQuestion", "ExitPlanMode"].contains(tool) ? .yellow : .red
    case "PermissionRequest":
        state = .yellow
    case "Notification":
        let type = json["notification_type"] as? String ?? ""
        let message = (json["message"] as? String ?? "").lowercased()
        if type == "permission_prompt" || type == "elicitation_dialog" || message.contains("permission") {
            state = .yellow
        } else if type == "idle_prompt" || message.contains("waiting for your input") {
            state = .green
        }
    default:
        break
    }

    guard let newState = state ?? old?.state else { exit(0) }
    let record = SessionRecord(
        sessionId: sessionId,
        state: newState,
        event: event,
        cwd: json["cwd"] as? String ?? old?.cwd ?? "",
        pid: old?.pid ?? findClaudePid(),
        transcript: json["transcript_path"] as? String ?? old?.transcript ?? "",
        updated: Date().timeIntervalSince1970
    )
    if let out = try? JSONEncoder().encode(record) {
        try? out.write(to: file, options: .atomic)
    }
    exit(0)
}

if CommandLine.arguments.contains("--hook") { runHook() }

// MARK: - Hooks in settings.json installieren / entfernen

enum HookInstaller {
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
                         "PostToolUse", "Notification", "Stop", "SessionEnd"]

    static var command: String {
        "\"\(Bundle.main.executablePath ?? CommandLine.arguments[0])\" --hook"
    }

    static func load() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return obj
    }

    static func save(_ settings: [String: Any]) throws {
        let backup = settingsURL.appendingPathExtension("trafficlight-backup")
        if FileManager.default.fileExists(atPath: settingsURL.path),
           !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: settingsURL, to: backup)
        }
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }

    /// Entfernt alle Hook-Einträge dieser App aus einer Event-Liste.
    static func stripOurs(_ list: [[String: Any]]) -> [[String: Any]] {
        list.compactMap { group in
            var g = group
            let hooks = (g["hooks"] as? [[String: Any]] ?? []).filter {
                !(($0["command"] as? String ?? "").contains(appMarker))
            }
            if hooks.isEmpty { return nil }
            g["hooks"] = hooks
            return g
        }
    }

    static func isInstalled() -> Bool {
        guard let hooks = load()["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { ev in
            (hooks[ev] as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String) == command }
            }
        }
    }

    static func install() throws {
        if isInstalled() { return }
        var settings = load()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for ev in events {
            var list = stripOurs(hooks[ev] as? [[String: Any]] ?? [])
            list.append(["hooks": [["type": "command", "command": command, "timeout": 5]]])
            hooks[ev] = list
        }
        settings["hooks"] = hooks
        try save(settings)
    }

    static func uninstall() throws {
        var settings = load()
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        for (ev, value) in hooks {
            let list = stripOurs(value as? [[String: Any]] ?? [])
            if list.isEmpty { hooks.removeValue(forKey: ev) } else { hooks[ev] = list }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        try save(settings)
    }
}

// MARK: - Hintergrundaufgaben (aus dem Transkript)

/// Eine von Claude Code im Hintergrund gestartete Aufgabe (Bash mit run_in_background, Monitor, Agent).
struct BGTask {
    enum Kind: String { case shell = "Shell", monitor = "Monitor", agent = "Agent" }
    var kind: Kind
    var title: String
    var started: Date
    var deadline: Date?   // Monitor laufen höchstens bis zum Timeout
}

/// Liest das Transkript einer Session inkrementell und führt Buch über laufende Hintergrundaufgaben.
/// Der Stop-Hook feuert auch dann, wenn solche Aufgaben noch laufen – nur das Transkript verrät es:
/// Start = tool_result mit backgroundTaskId / taskId / agentId, Ende = <task-notification> mit Status.
final class TranscriptScanner {
    private var pending: [String: BGTask] = [:]
    /// Zeitpunkt der letzten Benachrichtigung (Ende/Ereignis) – sie weckt das Modell wieder auf.
    private(set) var lastNotice: Double = 0
    private var path = ""
    private var offset: UInt64 = 0
    private var carry = Data()
    private var launches: [String: (kind: BGTask.Kind, title: String)] = [:]   // tool_use_id → Start

    private static let markers = ["run_in_background", "\"Monitor\"", "TaskStop", "backgroundTaskId",
                                  "\"taskId\"", "\"isAsync\"", "<task-notification>"].map { Data($0.utf8) }
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    private func reset() {
        pending = [:]; lastNotice = 0; offset = 0; carry = Data(); launches = [:]
    }

    func update(path newPath: String) {
        if newPath != path { reset(); path = newPath }
        guard !path.isEmpty, let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        if size < offset { reset() }
        guard size > offset else { return }
        var start = offset
        let maxRead: UInt64 = 64 << 20
        if size - start > maxRead { start = size - maxRead; carry = Data() }
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return }
        offset = start + UInt64(data.count)

        var buf = carry; buf.append(data)
        var lines = buf.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
        carry = Data()
        if buf.last != 0x0A, let last = lines.popLast() { carry = last }   // unvollständige Zeile später
        for line in lines where Self.markers.contains(where: { line.range(of: $0) != nil }) {
            if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { handle(obj) }
        }
    }

    /// Noch laufende Aufgaben (abgelaufene Monitore und > 24 h alte Einträge werden verworfen).
    func active() -> [BGTask] {
        let now = Date()
        pending = pending.filter { _, t in
            (t.deadline.map { $0 > now } ?? true) && now.timeIntervalSince(t.started) < 86400
        }
        return pending.values.sorted { $0.started < $1.started }
    }

    private func handle(_ obj: [String: Any]) {
        let ts = (obj["timestamp"] as? String).flatMap { Self.isoFrac.date(from: $0) } ?? Date()
        let msg = obj["message"] as? [String: Any]
        let blocks = msg?["content"] as? [[String: Any]] ?? []

        switch obj["type"] as? String {
        case "assistant":
            for b in blocks where b["type"] as? String == "tool_use" {
                let name = b["name"] as? String ?? ""
                let input = b["input"] as? [String: Any] ?? [:]
                if name == "TaskStop", let id = input["task_id"] as? String { pending.removeValue(forKey: id) }
                let bg = input["run_in_background"] as? Bool == true || input["run_in_background"] as? String == "true"
                guard let tuid = b["id"] as? String, bg || name == "Monitor" else { continue }
                let kind: BGTask.Kind = name == "Monitor" ? .monitor : (name == "Agent" || name == "Task" ? .agent : .shell)
                let raw = (input["description"] as? String) ?? (input["command"] as? String) ?? name
                launches[tuid] = (kind, String(raw.prefix(60)))
            }
        case "user":
            if let r = obj["toolUseResult"] as? [String: Any] {
                let tuid = blocks.first { $0["type"] as? String == "tool_result" }?["tool_use_id"] as? String
                let launch = tuid.flatMap { launches[$0] }
                if let id = r["backgroundTaskId"] as? String {
                    add(id, launch?.kind ?? .shell, launch?.title, ts, nil)
                } else if let id = r["taskId"] as? String {
                    var deadline: Date? = nil
                    if r["persistent"] as? Bool != true, let ms = (r["timeoutMs"] as? NSNumber)?.doubleValue {
                        deadline = ts.addingTimeInterval(ms / 1000 + 30)
                    }
                    add(id, .monitor, launch?.title, ts, deadline)
                } else if let id = r["agentId"] as? String, r["isAsync"] as? Bool == true {
                    add(id, .agent, launch?.title ?? r["description"] as? String, ts, nil)
                }
            }
            if let text = msg?["content"] as? String { notice(text, ts) }
        case "queue-operation":
            if let text = obj["content"] as? String { notice(text, ts) }
        case "attachment":
            if let text = (obj["attachment"] as? [String: Any])?["prompt"] as? String { notice(text, ts) }
        default:
            break
        }
    }

    private func add(_ id: String, _ kind: BGTask.Kind, _ title: String?, _ ts: Date, _ deadline: Date?) {
        pending[id] = BGTask(kind: kind, title: title ?? kind.rawValue, started: ts, deadline: deadline)
    }

    private func tags(_ tag: String, in text: String) -> [String] {
        var out: [String] = []
        var rest = text[...]
        while let a = rest.range(of: "<\(tag)>"), let b = rest.range(of: "</\(tag)>", range: a.upperBound..<rest.endIndex) {
            out.append(String(rest[a.upperBound..<b.lowerBound]))
            rest = rest[b.upperBound...]
        }
        return out
    }

    private func notice(_ text: String, _ ts: Date) {
        guard text.contains("<task-notification>") else { return }
        let ids = tags("task-id", in: text)
        if ids.contains(where: { !$0.hasPrefix("__orphan") }) { lastNotice = max(lastNotice, ts.timeIntervalSince1970) }
        let status = tags("status", in: text).first ?? ""
        let event = tags("event", in: text).first ?? ""
        let monitorEnded = event.hasPrefix("[Monitor") && ["expired", "ended", "exited", "stopped", "finished"].contains { event.contains($0) }
        if ["completed", "failed", "killed", "stopped"].contains(status) || monitorEnded {
            for id in ids { pending.removeValue(forKey: id) }
        }
    }
}

// MARK: - Session-Überwachung

final class SessionMonitor {
    private(set) var sessions: [SessionRecord] = []
    private var scanners: [String: TranscriptScanner] = [:]
    private(set) var background: [String: [BGTask]] = [:]   // sessionId → laufende Hintergrundaufgaben

    var aggregate: LightState {
        sessions.max { $0.state.priority < $1.state.priority }?.state ?? .off
    }

    /// Liest alle Session-Dateien, entfernt tote Sessions und erkennt Abbrüche (Esc).
    func refresh() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        var result: [SessionRecord] = []
        var bg: [String: [BGTask]] = [:]
        let now = Date().timeIntervalSince1970

        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  var rec = try? JSONDecoder().decode(SessionRecord.self, from: data) else { continue }

            // Prozess beendet (z. B. Terminal geschlossen) → Session verwerfen
            if rec.pid > 0, kill(rec.pid, 0) != 0, errno == ESRCH {
                try? fm.removeItem(at: url)
                continue
            }
            // Bei Abbruch durch den Nutzer feuert kein Stop-Hook → im Transkript nachsehen
            if rec.state != .green, now - rec.updated > 2, wasInterrupted(rec.transcript) {
                rec.state = .green
                rec.event = "Interrupted"
                rec.updated = now
                if let out = try? JSONEncoder().encode(rec) { try? out.write(to: url, options: .atomic) }
            }

            // Nur Anzeige (wird nie auf die Platte geschrieben): „grün“ stimmt nicht, solange Hintergrundaufgaben laufen
            let scanner = scanners[rec.sessionId] ?? TranscriptScanner()
            scanners[rec.sessionId] = scanner
            scanner.update(path: rec.transcript)
            let tasks = scanner.active()
            if rec.state == .green {
                if scanner.lastNotice > rec.updated, !wasInterrupted(rec.transcript) {
                    rec.state = .red   // Aufgabe fertig / Monitor-Ereignis → Modell denkt schon, aber noch kein Hook
                    rec.event = "TaskNotification"
                } else if !tasks.isEmpty {
                    rec.state = .background
                }
            }
            if !tasks.isEmpty { bg[rec.sessionId] = tasks }
            result.append(rec)
        }
        scanners = scanners.filter { id, _ in result.contains { $0.sessionId == id } }
        background = bg
        sessions = result.sorted { $0.updated > $1.updated }
    }

    /// Kurzbeschreibung der Hintergrundaufgaben, z. B. "Shell ×2 · Monitor ×1".
    func backgroundSummary(_ sessionId: String) -> String? {
        guard let tasks = background[sessionId], !tasks.isEmpty else { return nil }
        let kinds: [BGTask.Kind] = [.shell, .monitor, .agent]
        return kinds.compactMap { k in
            let n = tasks.filter { $0.kind == k }.count
            return n > 0 ? "\(k.rawValue) ×\(n)" : nil
        }.joined(separator: " · ")
    }

    private func wasInterrupted(_ path: String) -> Bool {
        guard !path.isEmpty, let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: size > 4096 ? size - 4096 : 0)
        guard let data = try? fh.readToEnd(), let text = String(data: data, encoding: .utf8) else { return false }
        let last = text.split(separator: "\n").last.map(String.init) ?? ""
        return last.contains("[Request interrupted by user")
    }
}

// MARK: - Kontingent (5h / 7d)

struct QuotaWindow {
    var used: Double          // verbrauchte Prozent (0–100)
    var resetsAt: Date?
    var remaining: Double { max(0, min(100, 100 - used)) }

    var isExpired: Bool { resetsAt.map { $0 <= Date() } ?? false }

    /// Kompakte Restzeit bis zum Reset: "42m", "2h14m", "4d3h". nil = unbekannt oder bereits abgelaufen.
    var countdown: String? {
        guard let r = resetsAt else { return nil }
        let mins = Int((r.timeIntervalSinceNow / 60).rounded(.up))
        guard mins > 0 else { return nil }
        if mins < 60 { return "\(mins)m" }
        if mins < 24 * 60 { return "\(mins / 60)h\(String(format: "%02d", mins % 60))m" }
        return "\(mins / 1440)d\((mins % 1440) / 60)h"
    }
}

struct QuotaSnapshot {
    var fiveHour: QuotaWindow?
    var sevenDay: QuotaWindow?
    var fetched: Date
    /// Länger als 10 Minuten nicht aktualisiert → gedimmt darstellen
    var isStale: Bool { Date().timeIntervalSince(fetched) > 600 }
}

/// Liest das OAuth-Token von Claude Code aus dem Schlüsselbund und fragt die Nutzungs-API ab.
/// Das Token verlässt den Rechner nur in der Anfrage an api.anthropic.com und wird nie gespeichert.
enum QuotaFetcher {
    private static func readToken() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return token
    }

    private static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        // "2026-11-01T17:10:00.298273+00:00" → Nachkommastellen entfernen
        let clean = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: clean)
    }

    private static func window(_ any: Any?) -> QuotaWindow? {
        guard let d = any as? [String: Any], let used = (d["utilization"] as? NSNumber)?.doubleValue else { return nil }
        return QuotaWindow(used: used, resetsAt: parseDate(d["resets_at"] as? String))
    }

    /// Läuft im Hintergrund; `done` wird im Main-Thread aufgerufen (nil = fehlgeschlagen).
    static func fetch(done: @escaping (QuotaSnapshot?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            func finish(_ s: QuotaSnapshot?) { DispatchQueue.main.async { done(s) } }
            guard let token = readToken(), let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return finish(nil) }
            var req = URLRequest(url: url, timeoutInterval: 10)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                guard (resp as? HTTPURLResponse)?.statusCode == 200, let data,
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return finish(nil) }
                let snap = QuotaSnapshot(fiveHour: window(obj["five_hour"]), sevenDay: window(obj["seven_day"]), fetched: Date())
                finish(snap.fiveHour == nil && snap.sevenDay == nil ? nil : snap)
            }.resume()
        }
    }
}

/// Statusfarben für Restkontingent (fest, nie themenabhängig): gut / Warnung / kritisch.
func quotaStatusColor(_ remaining: Double) -> NSColor {
    if remaining > 40 { return NSColor(srgbRed: 0x0c / 255, green: 0xa3 / 255, blue: 0x0c / 255, alpha: 1) }
    if remaining > 15 { return NSColor(srgbRed: 0xfa / 255, green: 0xb2 / 255, blue: 0x19 / 255, alpha: 1) }
    return NSColor(srgbRed: 0xd0 / 255, green: 0x3b / 255, blue: 0x3b / 255, alpha: 1)
}

// MARK: - Ampel-Darstellung

final class TrafficLightView: NSView {
    /// Höhe des Kontingent-Bereichs unter der Ampel (bei Skalierung 1.0)
    static let gaugeAreaHeight: CGFloat = 70
    /// Breite des Fensters mit / ohne Kontingent-Sockel (bei Skalierung 1.0)
    static let panelWidth: CGFloat = 58
    static let panelWidthWithQuota: CGFloat = 66
    static let panelHeight: CGFloat = 150
    static let panelHeightWithQuota: CGFloat = 220

    var state: LightState = .off { didSet { needsDisplay = true } }
    var quota: QuotaSnapshot? { didSet { needsDisplay = true } }
    var showQuota = true { didSet { needsDisplay = true } }
    var uiScale: CGFloat = 1.0 { didSet { needsDisplay = true } }
    var blinkOn = true { didSet { if state == .yellow { needsDisplay = true } } }
    /// Atmen der blauen Lampe (0…1); nur aktiv, solange Hintergrundaufgaben laufen
    var pulse: CGFloat = 1 { didSet { if state == .background { needsDisplay = true } } }
    var onRightClick: ((NSEvent) -> Void)?

    override var mouseDownCanMoveWindow: Bool { true }
    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }

    func color(for s: LightState) -> NSColor {
        switch s {
        case .red: return NSColor(calibratedRed: 1.0, green: 0.23, blue: 0.19, alpha: 1)
        case .yellow: return NSColor(calibratedRed: 1.0, green: 0.80, blue: 0.0, alpha: 1)
        case .green: return NSColor(calibratedRed: 0.20, green: 0.90, blue: 0.35, alpha: 1)
        case .background: return NSColor(calibratedRed: 0.20, green: 0.55, blue: 1.0, alpha: 1)
        case .off: return .gray
        }
    }

    /// Zeichnet die Kapsel mit den zwei Restanzeigen (5h / 7d).
    private func drawGauge(in rect: NSRect, wellRadius: CGFloat) {
        let s = uiScale
        // Eigene Karte, gleiches Material und gleiche Breite wie das Ampelgehäuse
        let card = NSBezierPath(roundedRect: rect, xRadius: wellRadius, yRadius: wellRadius)
        NSGradient(starting: NSColor(white: 0.22, alpha: 0.96), ending: NSColor(white: 0.08, alpha: 0.96))?
            .draw(in: card, angle: -90)
        NSColor(white: 0.45, alpha: 0.6).setStroke()
        card.lineWidth = 1
        card.stroke()

        let dim: CGFloat = (quota?.isStale ?? false) ? 0.5 : 1.0
        let rows: [(String, QuotaWindow?)] = [("5h", quota?.fiveHour), ("7d", quota?.sevenDay)]
        let rowH = rect.height / 2
        let x = rect.minX + 7 * s
        let w = rect.width - 14 * s
        let labelFont = NSFont.systemFont(ofSize: 8 * s, weight: .semibold)
        let pctFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5 * s, weight: .bold)
        let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 7.5 * s, weight: .medium)
        let barH = 4 * s
        let gap = 3.5 * s

        func draw(_ str: String, _ font: NSFont, _ alpha: CGFloat, baseline: CGFloat, right: Bool = false) {
            let a = NSAttributedString(string: str, attributes: [
                .font: font, .foregroundColor: NSColor(white: 1, alpha: alpha * dim)])
            a.draw(at: NSPoint(x: right ? x + w - a.size().width : x, y: baseline + font.descender))
        }

        for (i, row) in rows.enumerated() {
            let contentH = pctFont.capHeight + gap + barH + gap + smallFont.capHeight
            let top = rect.maxY - rowH * (CGFloat(i) + 0.5) + contentH / 2
            let line1 = top - pctFont.capHeight
            let barY = line1 - gap - barH
            let line3 = barY - gap - smallFont.capHeight

            draw(row.0, labelFont, 0.62, baseline: line1)
            let remaining = row.1?.remaining
            let tint = remaining.map { quotaStatusColor($0) } ?? NSColor(white: 1, alpha: 1)

            // Spur = hellere Stufe derselben Farbe, Füllung = Statusfarbe (dünn, voll gerundet)
            let track = NSRect(x: x, y: barY, width: w, height: barH)
            tint.withAlphaComponent(remaining == nil ? 0.12 : 0.22).setFill()
            NSBezierPath(roundedRect: track, xRadius: barH / 2, yRadius: barH / 2).fill()

            if let win = row.1 {
                if win.remaining > 0 {
                    let fill = NSRect(x: x, y: barY, width: max(barH, w * CGFloat(win.remaining / 100)), height: barH)
                    tint.withAlphaComponent(dim).setFill()
                    NSBezierPath(roundedRect: fill, xRadius: barH / 2, yRadius: barH / 2).fill()
                }
                draw("\(Int(win.remaining.rounded()))%", pctFont, 0.95, baseline: line1, right: true)
                draw("↻ " + (win.countdown ?? "…"), smallFont, 0.5, baseline: line3)
            } else {
                draw("--", pctFont, 0.35, baseline: line1, right: true)
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let pad: CGFloat = 6   // Platz für den Leuchtschein
        let section = showQuota ? Self.gaugeAreaHeight * uiScale : 0
        // Ampelgehäuse: symmetrisch, oben; die Karte darunter hat dieselbe Breite
        let body = NSRect(x: pad, y: section + pad, width: bounds.width - pad * 2, height: bounds.height - section - pad * 2)
        let radius = body.width * 0.32

        let housing = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
        NSGradient(starting: NSColor(white: 0.22, alpha: 0.96), ending: NSColor(white: 0.08, alpha: 0.96))?
            .draw(in: housing, angle: -90)
        NSColor(white: 0.45, alpha: 0.6).setStroke()
        housing.lineWidth = 1
        housing.stroke()

        // Blaues, atmendes Leuchten um das Gehäuse (Verlauf: innen kräftig, nach außen ausklingend)
        if state == .background {
            let blue = color(for: .background)
            let layers = 5
            for i in (0..<layers).reversed() {
                let t = CGFloat(i) / CGFloat(layers)            // 0 = am Gehäuse, → 1 = außen
                let outset = 1 + CGFloat(i)                     // 1-pt-Ringe lückenlos nebeneinander
                let alpha = CGFloat(pow(Double(1 - t), 1.6)) * (0.25 + 0.75 * pulse)
                let ring = NSBezierPath(roundedRect: body.insetBy(dx: -outset, dy: -outset),
                                        xRadius: radius + outset, yRadius: radius + outset)
                ring.lineWidth = 1
                blue.withAlphaComponent(alpha).setStroke()
                ring.stroke()
            }
        }

        if showQuota {
            let card = NSRect(x: body.minX, y: pad, width: body.width, height: section - 6 * uiScale)
            drawGauge(in: card, wellRadius: 15 * uiScale)
        }

        // Drei Lampen von oben nach unten: rot, gelb, grün
        let lamps: [LightState] = [.red, .yellow, .green]
        let slot = body.height / 3
        let d = min(body.width * 0.68, slot * 0.78)
        for (i, lamp) in lamps.enumerated() {
            let cy = body.maxY - slot * (CGFloat(i) + 0.5)
            let rect = NSRect(x: body.midX - d / 2, y: cy - d / 2, width: d, height: d)
            let circle = NSBezierPath(ovalIn: rect)
            let c = color(for: lamp)
            // Hintergrundaufgaben: die rote Lampe bleibt an, das Gehäuse bekommt einen blauen Ring
            let lit = (lamp == state || (state == .background && lamp == .red)) && (state != .yellow || blinkOn)

            // Lampenfassung
            NSColor(white: 0.03, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: -2, dy: -2)).fill()

            if lit {
                NSGraphicsContext.saveGraphicsState()
                let glow = NSShadow()
                glow.shadowColor = c.withAlphaComponent(0.95)
                glow.shadowBlurRadius = d * 0.45
                glow.shadowOffset = .zero
                glow.set()
                c.setFill()
                circle.fill()
                NSGraphicsContext.restoreGraphicsState()
                NSGradient(colors: [NSColor.white.withAlphaComponent(0.85), c, c.shadow(withLevel: 0.25) ?? c],
                           atLocations: [0, 0.45, 1], colorSpace: .deviceRGB)?
                    .draw(in: circle, relativeCenterPosition: NSPoint(x: -0.3, y: 0.35))
            } else {
                NSGradient(starting: c.withAlphaComponent(0.28), ending: c.shadow(withLevel: 0.75)?.withAlphaComponent(0.5) ?? c)?
                    .draw(in: circle, relativeCenterPosition: NSPoint(x: -0.3, y: 0.35))
            }
        }
    }
}

final class LightPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let monitor = SessionMonitor()
    private var statusItem: NSStatusItem!
    private var panel: LightPanel!
    private var lightView: TrafficLightView!
    private var timer: Timer?
    private var blinkTimer: Timer?
    private var pulseTimer: Timer?
    private let defaults = UserDefaults.standard

    private var monitoringEnabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }
    private var lightVisible: Bool {
        get { defaults.object(forKey: "visible") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "visible") }
    }
    private var showQuota: Bool {
        get { defaults.object(forKey: "showQuota") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showQuota") }
    }
    private var showStatusQuota: Bool {
        get { defaults.object(forKey: "showStatusQuota") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showStatusQuota") }
    }
    private var lastQuotaAttempt = Date.distantPast
    private var lastMinute = 0
    private var quota: QuotaSnapshot?
    private var quotaFetching = false
    private var nextQuotaFetch = Date.distantPast
    private var scale: CGFloat {
        get { CGFloat(defaults.object(forKey: "scale") as? Double ?? 1.0) }
        set { defaults.set(Double(newValue), forKey: "scale") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        do { try HookInstaller.install() } catch { showError(tr("安装 Claude Code hooks 失败", "Failed to install Claude Code hooks", "Installation der Claude-Code-Hooks fehlgeschlagen"), error) }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        setupPanel()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let v = self?.lightView else { return }
            v.blinkOn = v.state == .yellow ? !v.blinkOn : true
        }
        // Blaues Leuchten „atmet“ langsam (Periode 2,4 s) – anders als das schnelle Blinken von Gelb
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, self.lightView.state == .background else { return }
            let p = 0.5 + 0.5 * CGFloat(sin(Date().timeIntervalSinceReferenceDate * 2 * .pi / 2.4))
            self.lightView.pulse = p
            let q = (p * 6).rounded() / 6
            if q != self.statusPulse { self.statusPulse = q; self.updateStatusItem(.background) }
        }
    }

    // MARK: Schwebendes Fenster

    private var baseSize: NSSize {
        NSSize(width: (showQuota ? TrafficLightView.panelWidthWithQuota : TrafficLightView.panelWidth) * scale,
               height: (showQuota ? TrafficLightView.panelHeightWithQuota : TrafficLightView.panelHeight) * scale)
    }

    /// Fenstergröße anpassen; die Oberkante bleibt an Ort und Stelle.
    private func applyPanelSize() {
        let top = panel.frame.maxY
        let midX = panel.frame.midX   // Mitte bleibt, wenn sich die Breite ändert
        let size = baseSize
        panel.setFrame(NSRect(x: midX - size.width / 2, y: top - size.height, width: size.width, height: size.height), display: true)
        lightView.uiScale = scale
        lightView.showQuota = showQuota
    }

    private func setupPanel() {
        let size = baseSize
        var origin = NSPoint(x: 0, y: 0)
        if let s = defaults.string(forKey: "origin") {
            origin = NSPointFromString(s)
        } else if let screen = NSScreen.main?.visibleFrame {
            origin = NSPoint(x: screen.maxX - size.width - 24, y: screen.maxY - size.height - 24)
        }

        panel = LightPanel(contentRect: NSRect(origin: origin, size: size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        lightView = TrafficLightView(frame: NSRect(origin: .zero, size: size))
        lightView.autoresizingMask = [.width, .height]
        lightView.uiScale = scale
        lightView.showQuota = showQuota
        lightView.onRightClick = { [weak self] event in
            guard let self, let menu = self.statusItem.menu else { return }
            self.menuNeedsUpdate(menu)
            NSMenu.popUpContextMenu(menu, with: event, for: self.lightView)
        }
        panel.contentView = lightView
        ensureOnScreen()

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.defaults.set(NSStringFromPoint(self.panel.frame.origin), forKey: "origin")
        }
    }

    /// Falls der gespeicherte Ort außerhalb aller Bildschirme liegt (z. B. Monitor abgesteckt), zurückholen.
    private func ensureOnScreen() {
        let f = panel.frame
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(f) }), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - f.width - 24, y: screen.maxY - f.height - 24))
        }
    }

    private func updatePanelVisibility() {
        if monitoringEnabled && lightVisible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    // MARK: Zustand aktualisieren

    private var langTicks = 0

    private func tick() {
        langTicks += 1
        if langTicks % 4 == 0, I18n.refresh() { lightView.needsDisplay = true }
        monitor.refresh()
        let state = monitoringEnabled ? monitor.aggregate : .off
        if lightView.state != state {
            lightView.state = state
            lightView.blinkOn = true
            lightView.pulse = 1
        }
        updateStatusItem(state)
        let minute = Int(Date().timeIntervalSince1970 / 60)
        if minute != lastMinute { lastMinute = minute; lightView.needsDisplay = true }
        statusItem.button?.toolTip = "Claude Code – " + (monitoringEnabled ? state.label : tr("已暂停", "Paused", "Pausiert"))
        lightView.toolTip = tooltipText()
        updatePanelVisibility()
        refreshQuotaIfNeeded()
    }

    private var statusKey = ""
    /// Atemphase der Menüleiste, auf 6 Stufen gerundet (Bild wird nur bei Stufenwechsel neu gezeichnet)
    private var statusPulse: CGFloat = 1

    /// Menüleiste: Ampelpunkt + zwei Zeilen (5h oben, 7d unten) mit Balken, Rest-% und Zeit bis zum Reset.
    private func updateStatusItem(_ state: LightState) {
        guard let button = statusItem.button else { return }
        let rows: [(String, QuotaWindow)] = monitoringEnabled && showQuota && showStatusQuota
            ? [("5h", quota?.fiveHour), ("7d", quota?.sevenDay)].compactMap { n, w in w.map { (n, $0) } } : []
        let key = "\(I18n.lang)|\(monitoringEnabled)|\(state)|\(state == .background ? statusPulse : 1)|" + rows.map { "\($0.0)\(Int($0.1.remaining.rounded()))\($0.1.countdown ?? "…")" }.joined(separator: "|")
        guard key != statusKey else { return }
        statusKey = key

        let isBG = state == .background
        guard !rows.isEmpty else {   // klassisch: nur Emoji (bei Hintergrundaufgaben roter Punkt mit blauem Ring)
            if isBG && monitoringEnabled {
                button.title = ""
                button.imagePosition = .imageOnly
                button.image = dotImage(lamp: lightView.color(for: .red), ring: lightView.color(for: .background), pulse: statusPulse)
                return
            }
            button.image = nil
            button.imagePosition = .noImage
            button.attributedTitle = NSAttributedString(string: monitoringEnabled ? state.emoji : "⚫️",
                                                        attributes: [.font: NSFont.systemFont(ofSize: 13)])
            return
        }
        button.title = ""
        button.imagePosition = .imageOnly
        button.image = statusImage(lamp: lightView.color(for: isBG ? .red : state), lit: state != .off,
                                   ring: isBG ? lightView.color(for: .background) : nil, pulse: statusPulse, rows: rows)
    }

    /// Ampelpunkt, optional mit blauem Leuchten (Hintergrundaufgaben). Ringe liegen exakt auf dem Pixelraster
    /// (1-pt-Linien, Mittellinie auf halben Punkten) und sind konzentrisch zum Punkt.
    private static func drawDot(_ dot: NSRect, lamp: NSColor, lit: Bool, ring: NSColor?, pulse: CGFloat = 1) {
        if let ring {
            for (i, a) in [0.9, 0.5, 0.2].enumerated() {
                let r = NSBezierPath(ovalIn: dot.insetBy(dx: -(CGFloat(i) + 0.5), dy: -(CGFloat(i) + 0.5)))
                r.lineWidth = 1
                ring.withAlphaComponent(CGFloat(a) * (0.3 + 0.7 * pulse)).setStroke()
                r.stroke()
            }
        }
        NSGraphicsContext.saveGraphicsState()
        if lit {
            let g = NSShadow(); g.shadowColor = lamp.withAlphaComponent(0.8); g.shadowBlurRadius = 3; g.shadowOffset = .zero; g.set()
        }
        (lit ? lamp : NSColor.secondaryLabelColor).setFill()
        NSBezierPath(ovalIn: dot).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func dotImage(lamp: NSColor, ring: NSColor, pulse: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            Self.drawDot(NSRect(x: 4, y: 4, width: 10, height: 10), lamp: lamp, lit: true, ring: ring, pulse: pulse)
            return true
        }
    }

    private func statusImage(lamp: NSColor, lit: Bool, ring: NSColor?, pulse: CGFloat, rows: [(String, QuotaWindow)]) -> NSImage {
        let h: CGFloat = 22, lampD: CGFloat = 10
        let labelFont = NSFont.systemFont(ofSize: 7.5, weight: .semibold)
        let pctFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .bold)
        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .medium)
        let labelW: CGFloat = 11, barW: CGFloat = 34, barH: CGFloat = 3.5, pctW: CGFloat = 23, timeW: CGFloat = 29
        let x0: CGFloat = 4 + lampD + 6
        let width = x0 + labelW + barW + 4 + pctW + 3 + timeW + 3

        return NSImage(size: NSSize(width: width, height: h), flipped: false) { _ in
            // Ampelpunkt
            Self.drawDot(NSRect(x: 4, y: (h - lampD) / 2, width: lampD, height: lampD), lamp: lamp, lit: lit, ring: ring, pulse: pulse)

            func text(_ str: String, _ font: NSFont, _ color: NSColor, x: CGFloat, baseline: CGFloat, width: CGFloat = 0, right: Bool = false) {
                let a = NSAttributedString(string: str, attributes: [.font: font, .foregroundColor: color])
                a.draw(at: NSPoint(x: right ? x + width - a.size().width : x, y: baseline + font.descender))
            }
            for (i, row) in rows.enumerated() {
                let mid = h / 2 + (i == 0 ? 5.5 : -5.5)
                let base = mid - pctFont.capHeight / 2
                let tint = quotaStatusColor(row.1.remaining)
                text(row.0, labelFont, .secondaryLabelColor, x: x0, baseline: mid - labelFont.capHeight / 2)

                let bar = NSRect(x: x0 + labelW, y: mid - barH / 2, width: barW, height: barH)
                tint.withAlphaComponent(0.25).setFill()
                NSBezierPath(roundedRect: bar, xRadius: barH / 2, yRadius: barH / 2).fill()
                if row.1.remaining > 0 {
                    var f = bar; f.size.width = max(barH, barW * CGFloat(row.1.remaining / 100))
                    tint.setFill()
                    NSBezierPath(roundedRect: f, xRadius: barH / 2, yRadius: barH / 2).fill()
                }
                let px = x0 + labelW + barW + 4
                text("\(Int(row.1.remaining.rounded()))%", pctFont, .labelColor, x: px, baseline: base, width: pctW, right: true)
                text(row.1.countdown ?? "…", timeFont, .secondaryLabelColor, x: px + pctW + 3, baseline: mid - timeFont.capHeight / 2, width: timeW, right: true)
            }
            return true
        }
    }

    private func refreshQuotaIfNeeded() {
        guard monitoringEnabled, showQuota, !quotaFetching else { return }
        let now = Date()
        // Ein Fenster ist gerade abgelaufen → nicht auf den nächsten Takt warten
        let expired = [quota?.fiveHour, quota?.sevenDay].contains { $0?.isExpired ?? false }
        guard now >= nextQuotaFetch || (expired && now.timeIntervalSince(lastQuotaAttempt) > 30) else { return }
        lastQuotaAttempt = now
        quotaFetching = true
        QuotaFetcher.fetch { [weak self] snap in
            guard let self else { return }
            self.quotaFetching = false
            if let snap {
                self.quota = snap
                self.nextQuotaFetch = Date().addingTimeInterval(180)
            } else {
                // 失败时保留旧数据(会变暗),稍后重试
                self.nextQuotaFetch = Date().addingTimeInterval(self.quota == nil ? 60 : 300)
            }
            self.lightView.quota = self.quota
        }
    }

    private func quotaLine(_ name: String, _ w: QuotaWindow?, resetTemplate: String) -> String? {
        guard let w else { return nil }
        let pct = Int(w.remaining.rounded())
        var line = tr("\(name) 剩余 \(pct)%", "\(name): \(pct)% left", "\(name): noch \(pct)%")
        if let r = w.resetsAt {
            let f = DateFormatter()
            f.locale = I18n.locale
            f.setLocalizedDateFormatFromTemplate(resetTemplate)
            let at = f.string(from: r)
            line += "  ·  " + (w.countdown.map {
                tr("\($0) 后重置（\(at)）", "resets in \($0) (\(at))", "Reset in \($0) (\(at))")
            } ?? tr("即将重置", "resetting soon", "Reset gleich"))
        }
        return line
    }

    private var quotaLines: [String] {
        guard showQuota, let q = quota else { return [] }
        return [quotaLine(tr("5 小时", "5-hour", "5 Std."), q.fiveHour, resetTemplate: "HHmm"),
                quotaLine(tr("7 天", "7-day", "7 Tage"), q.sevenDay, resetTemplate: "MMMdHHmm")].compactMap { $0 }
    }

    private func tooltipText() -> String {
        guard monitoringEnabled else { return tr("已暂停", "Paused", "Pausiert") }
        var lines = monitor.sessions.isEmpty
            ? [LightState.off.label]
            : monitor.sessions.map { "\($0.state.emoji) \(projectName($0.cwd)) – \(stateText($0))" }
        lines += quotaLines
        return lines.joined(separator: "\n")
    }

    /// Zustandstext einer Session; bei Hintergrundaufgaben mit Art und Anzahl.
    private func stateText(_ s: SessionRecord) -> String {
        guard s.state == .background, let sum = monitor.backgroundSummary(s.sessionId) else { return s.state.label }
        return "\(s.state.label) (\(sum))"
    }

    private func projectName(_ cwd: String) -> String {
        cwd.isEmpty ? tr("未知目录", "Unknown folder", "Unbekannter Ordner") : (cwd as NSString).lastPathComponent
    }

    // MARK: Menü

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        I18n.refresh()
        let state = monitoringEnabled ? monitor.aggregate : .off

        let header = NSMenuItem(title: monitoringEnabled ? "\(state.emoji)  \(state.label)" : "⚫️  " + tr("监控已暂停", "Monitoring paused", "Überwachung pausiert"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if monitoringEnabled && !monitor.sessions.isEmpty {
            menu.addItem(.separator())
            for s in monitor.sessions {
                let item = NSMenuItem(title: "\(s.state.emoji)  \(projectName(s.cwd))  ·  \(stateText(s))", action: nil, keyEquivalent: "")
                item.toolTip = ([s.cwd] + (monitor.background[s.sessionId] ?? []).map { "• \($0.kind.rawValue): \($0.title)" }).joined(separator: "\n")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        let qLines = monitoringEnabled ? quotaLines : []
        if !qLines.isEmpty {
            menu.addItem(.separator())
            for l in qLines {
                let item = NSMenuItem(title: l, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        addItem(menu, monitoringEnabled ? tr("关闭红绿灯（暂停监控）", "Turn Off Light (Pause Monitoring)", "Ampel ausschalten (Überwachung pausieren)") : tr("开启红绿灯", "Turn On Light", "Ampel einschalten"), #selector(toggleEnabled), "e")
        addItem(menu, tr("显示悬浮红绿灯", "Show Floating Light", "Schwebende Ampel anzeigen"), #selector(toggleVisible), "", checked: lightVisible).isEnabled = monitoringEnabled

        addItem(menu, tr("显示额度（5h / 7d 剩余）", "Show Quota (5h / 7d remaining)", "Kontingent anzeigen (5h / 7d verbleibend)"), #selector(toggleQuota), "", checked: showQuota)
        addItem(menu, tr("在菜单栏显示额度和重置时间", "Show Quota and Reset Time in Menu Bar", "Kontingent und Reset-Zeit in der Menüleiste"), #selector(toggleStatusQuota), "", checked: showStatusQuota).isEnabled = showQuota
        let sizeItem = NSMenuItem(title: tr("大小", "Size", "Größe"), action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for (title, value) in [(tr("小", "Small", "Klein"), 0.75), (tr("中", "Medium", "Mittel"), 1.0), (tr("大", "Large", "Groß"), 1.35)] {
            let it = addItem(sizeMenu, title, #selector(setSize(_:)), "", checked: abs(Double(scale) - value) < 0.01)
            it.representedObject = value
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)
        addItem(menu, tr("重置位置", "Reset Position", "Position zurücksetzen"), #selector(resetPosition), "")

        menu.addItem(.separator())
        addItem(menu, tr("开机自动启动", "Launch at Login", "Beim Anmelden starten"), #selector(toggleLogin), "", checked: SMAppService.mainApp.status == .enabled)
        let installed = HookInstaller.isInstalled()
        addItem(menu, installed ? tr("Claude Code hooks：已安装 ✓", "Claude Code hooks: installed ✓", "Claude-Code-Hooks: installiert ✓") : tr("安装 Claude Code hooks", "Install Claude Code hooks", "Claude-Code-Hooks installieren"), #selector(installHooks), "").isEnabled = !installed
        addItem(menu, tr("卸载 hooks 并退出", "Uninstall Hooks and Quit", "Hooks entfernen und beenden"), #selector(uninstallAndQuit), "")

        menu.addItem(.separator())
        addItem(menu, tr("退出", "Quit", "Beenden"), #selector(quit), "q")
    }

    @discardableResult
    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, checked: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.state = checked ? .on : .off
        menu.addItem(item)
        return item
    }

    @objc private func toggleEnabled() { monitoringEnabled.toggle(); tick() }
    @objc private func toggleVisible() { lightVisible.toggle(); tick() }

    @objc private func setSize(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        scale = CGFloat(v)
        applyPanelSize()
    }

    @objc private func toggleStatusQuota() { showStatusQuota.toggle(); tick() }

    @objc private func toggleQuota() {
        showQuota.toggle()
        nextQuotaFetch = .distantPast
        applyPanelSize()
        tick()
    }

    @objc private func resetPosition() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let f = panel.frame
        panel.setFrameOrigin(NSPoint(x: screen.maxX - f.width - 24, y: screen.maxY - f.height - 24))
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { showError(tr("设置开机启动失败", "Failed to change launch at login", "Autostart konnte nicht geändert werden"), error) }
    }

    @objc private func installHooks() {
        do { try HookInstaller.install() } catch { showError(tr("安装 hooks 失败", "Failed to install hooks", "Hooks konnten nicht installiert werden"), error) }
    }

    @objc private func uninstallAndQuit() {
        do { try HookInstaller.uninstall() } catch { showError(tr("卸载 hooks 失败", "Failed to uninstall hooks", "Hooks konnten nicht entfernt werden"), error); return }
        try? FileManager.default.removeItem(at: sessionsDir)
        NSApp.terminate(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// Debug: `Lumen --scan <transcript.jsonl>` zeigt die laufenden Hintergrundaufgaben eines Transkripts.
if let i = CommandLine.arguments.firstIndex(of: "--scan"), i + 1 < CommandLine.arguments.count {
    let sc = TranscriptScanner()
    sc.update(path: CommandLine.arguments[i + 1])
    let tasks = sc.active()
    print("pending=\(tasks.count) lastNotice=\(sc.lastNotice)")
    tasks.forEach { print("  \($0.kind.rawValue)\t\($0.started)\t\($0.title)") }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
