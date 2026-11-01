// Claude Code Ampel – schwebende Ampel + Menüleisten-Symbol für den Claude-Code-Status.
//
// Funktionsweise:
//   1. Beim Start trägt die App Hooks in ~/.claude/settings.json ein.
//   2. Claude Code ruft bei jedem Ereignis dieses Binary mit `--hook` auf;
//      es schreibt den Status pro Session nach ~/.claude/traffic-light/sessions/<id>.json.
//   3. Die laufende App liest diese Dateien und zeigt den Gesamtstatus an.
//
//   🔴 rot   = arbeitet
//   🟡 gelb  = braucht menschliches Eingreifen (Berechtigung, Plan, Auswahlfrage …)
//   🟢 grün  = Aufgabe beendet, wartet auf neue Eingabe
//   ⚪️ grau  = keine aktive Claude-Code-Session

import AppKit
import Darwin
import ServiceManagement

// MARK: - Gemeinsame Definitionen

enum LightState: String, Codable {
    case red, yellow, green, off

    var emoji: String {
        switch self {
        case .red: return "🔴"
        case .yellow: return "🟡"
        case .green: return "🟢"
        case .off: return "⚪️"
        }
    }

    var label: String {
        switch self {
        case .red: return "工作中"
        case .yellow: return "需要你介入"
        case .green: return "等待输入"
        case .off: return "未检测到 Claude Code"
        }
    }

    // Priorität bei mehreren Sessions: gelb > rot > grün
    var priority: Int {
        switch self {
        case .yellow: return 3
        case .red: return 2
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

// MARK: - Session-Überwachung

final class SessionMonitor {
    private(set) var sessions: [SessionRecord] = []

    var aggregate: LightState {
        sessions.max { $0.state.priority < $1.state.priority }?.state ?? .off
    }

    /// Liest alle Session-Dateien, entfernt tote Sessions und erkennt Abbrüche (Esc).
    func refresh() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        var result: [SessionRecord] = []
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
            result.append(rec)
        }
        sessions = result.sorted { $0.updated > $1.updated }
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

// MARK: - Ampel-Darstellung

final class TrafficLightView: NSView {
    /// Höhe des Kontingent-Bereichs unter der Ampel (bei Skalierung 1.0)
    static let gaugeAreaHeight: CGFloat = 48

    var state: LightState = .off { didSet { needsDisplay = true } }
    var quota: QuotaSnapshot? { didSet { needsDisplay = true } }
    var showQuota = true { didSet { needsDisplay = true } }
    var uiScale: CGFloat = 1.0 { didSet { needsDisplay = true } }
    var blinkOn = true { didSet { if state == .yellow { needsDisplay = true } } }
    var onRightClick: ((NSEvent) -> Void)?

    override var mouseDownCanMoveWindow: Bool { true }
    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }

    private func color(for s: LightState) -> NSColor {
        switch s {
        case .red: return NSColor(calibratedRed: 1.0, green: 0.23, blue: 0.19, alpha: 1)
        case .yellow: return NSColor(calibratedRed: 1.0, green: 0.80, blue: 0.0, alpha: 1)
        case .green: return NSColor(calibratedRed: 0.20, green: 0.90, blue: 0.35, alpha: 1)
        case .off: return .gray
        }
    }

    private func quotaColor(_ remaining: Double) -> NSColor {
        remaining > 40 ? color(for: .green) : remaining > 15 ? color(for: .yellow) : color(for: .red)
    }

    /// Zeichnet die Kapsel mit den zwei Restanzeigen (5h / 7d).
    private func drawGauge(in rect: NSRect) {
        let s = uiScale
        let capsule = NSBezierPath(roundedRect: rect, xRadius: 10 * s, yRadius: 10 * s)
        NSGradient(starting: NSColor(white: 0.22, alpha: 0.96), ending: NSColor(white: 0.08, alpha: 0.96))?
            .draw(in: capsule, angle: -90)
        NSColor(white: 0.45, alpha: 0.6).setStroke()
        capsule.lineWidth = 1
        capsule.stroke()

        let dim: CGFloat = (quota?.isStale ?? false) ? 0.5 : 1.0
        let rows: [(String, QuotaWindow?)] = [("5h", quota?.fiveHour), ("7d", quota?.sevenDay)]
        let rowH = rect.height / 2
        let inset = 6 * s
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8.5 * s, weight: .semibold)
        let barH = 3.5 * s

        for (i, row) in rows.enumerated() {
            let rowTop = rect.maxY - rowH * CGFloat(i)
            let contentH = font.capHeight + 3 * s + barH
            let bottom = rowTop - rowH / 2 - contentH / 2
            let x = rect.minX + inset
            let w = rect.width - inset * 2

            // Balken
            let track = NSRect(x: x, y: bottom, width: w, height: barH)
            NSColor(white: 1, alpha: 0.12).setFill()
            NSBezierPath(roundedRect: track, xRadius: barH / 2, yRadius: barH / 2).fill()

            let textY = bottom + barH + 3 * s - font.descender
            let label = NSAttributedString(string: row.0, attributes: [
                .font: font, .foregroundColor: NSColor(white: 1, alpha: 0.55 * dim)])
            label.draw(at: NSPoint(x: x, y: textY))

            if let win = row.1 {
                let c = quotaColor(win.remaining).withAlphaComponent(dim)
                let fill = NSRect(x: x, y: bottom, width: max(barH, w * CGFloat(win.remaining / 100)), height: barH)
                if win.remaining > 0 {
                    NSGraphicsContext.saveGraphicsState()
                    let glow = NSShadow()
                    glow.shadowColor = c.withAlphaComponent(0.6)
                    glow.shadowBlurRadius = 3 * s
                    glow.shadowOffset = .zero
                    glow.set()
                    c.setFill()
                    NSBezierPath(roundedRect: fill, xRadius: barH / 2, yRadius: barH / 2).fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
                let pct = NSAttributedString(string: "\(Int(win.remaining.rounded()))%", attributes: [
                    .font: font, .foregroundColor: NSColor(white: 1, alpha: 0.92 * dim)])
                pct.draw(at: NSPoint(x: x + w - pct.size().width, y: textY))
            } else {
                let pct = NSAttributedString(string: "--", attributes: [
                    .font: font, .foregroundColor: NSColor(white: 1, alpha: 0.35)])
                pct.draw(at: NSPoint(x: x + w - pct.size().width, y: textY))
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let pad: CGFloat = 6   // Platz für den Leuchtschein
        var lightsBounds = bounds
        if showQuota {
            let gaugeH = Self.gaugeAreaHeight * uiScale
            lightsBounds = NSRect(x: 0, y: gaugeH, width: bounds.width, height: bounds.height - gaugeH)
            drawGauge(in: NSRect(x: pad, y: pad, width: bounds.width - pad * 2, height: gaugeH - 4 * uiScale))
        }
        let body = lightsBounds.insetBy(dx: pad, dy: pad)
        let radius = body.width * 0.32

        // Gehäuse
        let housing = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
        NSGradient(starting: NSColor(white: 0.22, alpha: 0.96), ending: NSColor(white: 0.08, alpha: 0.96))?
            .draw(in: housing, angle: -90)
        NSColor(white: 0.45, alpha: 0.6).setStroke()
        housing.lineWidth = 1
        housing.stroke()

        // Drei Lampen von oben nach unten: rot, gelb, grün
        let lamps: [LightState] = [.red, .yellow, .green]
        let slot = body.height / 3
        let d = min(body.width * 0.68, slot * 0.78)
        for (i, lamp) in lamps.enumerated() {
            let cy = body.maxY - slot * (CGFloat(i) + 0.5)
            let rect = NSRect(x: body.midX - d / 2, y: cy - d / 2, width: d, height: d)
            let circle = NSBezierPath(ovalIn: rect)
            let c = color(for: lamp)
            let lit = lamp == state && (state != .yellow || blinkOn)

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
    private var quota: QuotaSnapshot?
    private var quotaFetching = false
    private var nextQuotaFetch = Date.distantPast
    private var scale: CGFloat {
        get { CGFloat(defaults.object(forKey: "scale") as? Double ?? 1.0) }
        set { defaults.set(Double(newValue), forKey: "scale") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        do { try HookInstaller.install() } catch { showError("安装 Claude Code hooks 失败", error) }

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
    }

    // MARK: Schwebendes Fenster

    private var baseSize: NSSize {
        NSSize(width: 58 * scale, height: (150 + (showQuota ? TrafficLightView.gaugeAreaHeight : 0)) * scale)
    }

    /// Fenstergröße anpassen; die Oberkante bleibt an Ort und Stelle.
    private func applyPanelSize() {
        let top = panel.frame.maxY
        let size = baseSize
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
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

    private func tick() {
        monitor.refresh()
        let state = monitoringEnabled ? monitor.aggregate : .off
        if lightView.state != state {
            lightView.state = state
            lightView.blinkOn = true
        }
        statusItem.button?.title = monitoringEnabled ? state.emoji : "⚫️"
        statusItem.button?.toolTip = "Claude Code 红绿灯 – " + (monitoringEnabled ? state.label : "已暂停")
        lightView.toolTip = tooltipText()
        updatePanelVisibility()
        refreshQuotaIfNeeded()
    }

    private func refreshQuotaIfNeeded() {
        guard monitoringEnabled, showQuota, !quotaFetching, Date() >= nextQuotaFetch else { return }
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

    private func quotaLine(_ name: String, _ w: QuotaWindow?, resetFormat: String) -> String? {
        guard let w else { return nil }
        var line = "\(name) 剩余 \(Int(w.remaining.rounded()))%"
        if let r = w.resetsAt {
            let f = DateFormatter()
            f.dateFormat = resetFormat
            line += "  ·  \(f.string(from: r)) 重置"
        }
        return line
    }

    private var quotaLines: [String] {
        guard showQuota, let q = quota else { return [] }
        return [quotaLine("5 小时", q.fiveHour, resetFormat: "HH:mm"),
                quotaLine("7 天", q.sevenDay, resetFormat: "M月d日 HH:mm")].compactMap { $0 }
    }

    private func tooltipText() -> String {
        guard monitoringEnabled else { return "已暂停" }
        var lines = monitor.sessions.isEmpty
            ? [LightState.off.label]
            : monitor.sessions.map { "\($0.state.emoji) \(projectName($0.cwd)) – \($0.state.label)" }
        lines += quotaLines
        return lines.joined(separator: "\n")
    }

    private func projectName(_ cwd: String) -> String {
        cwd.isEmpty ? "未知目录" : (cwd as NSString).lastPathComponent
    }

    // MARK: Menü

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = monitoringEnabled ? monitor.aggregate : .off

        let header = NSMenuItem(title: monitoringEnabled ? "\(state.emoji)  \(state.label)" : "⚫️  监控已暂停", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if monitoringEnabled && !monitor.sessions.isEmpty {
            menu.addItem(.separator())
            for s in monitor.sessions {
                let item = NSMenuItem(title: "\(s.state.emoji)  \(projectName(s.cwd))  ·  \(s.state.label)", action: nil, keyEquivalent: "")
                item.toolTip = s.cwd
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
        addItem(menu, monitoringEnabled ? "关闭红绿灯（暂停监控）" : "开启红绿灯", #selector(toggleEnabled), "e")
        addItem(menu, "显示悬浮红绿灯", #selector(toggleVisible), "", checked: lightVisible).isEnabled = monitoringEnabled

        addItem(menu, "显示额度（5h / 7d 剩余）", #selector(toggleQuota), "", checked: showQuota)
        let sizeItem = NSMenuItem(title: "大小", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for (title, value) in [("小", 0.75), ("中", 1.0), ("大", 1.35)] {
            let it = addItem(sizeMenu, title, #selector(setSize(_:)), "", checked: abs(Double(scale) - value) < 0.01)
            it.representedObject = value
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)
        addItem(menu, "重置位置", #selector(resetPosition), "")

        menu.addItem(.separator())
        addItem(menu, "开机自动启动", #selector(toggleLogin), "", checked: SMAppService.mainApp.status == .enabled)
        let installed = HookInstaller.isInstalled()
        addItem(menu, installed ? "Claude Code hooks：已安装 ✓" : "安装 Claude Code hooks", #selector(installHooks), "").isEnabled = !installed
        addItem(menu, "卸载 hooks 并退出", #selector(uninstallAndQuit), "")

        menu.addItem(.separator())
        addItem(menu, "退出", #selector(quit), "q")
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
        } catch { showError("设置开机启动失败", error) }
    }

    @objc private func installHooks() {
        do { try HookInstaller.install() } catch { showError("安装 hooks 失败", error) }
    }

    @objc private func uninstallAndQuit() {
        do { try HookInstaller.uninstall() } catch { showError("卸载 hooks 失败", error); return }
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
