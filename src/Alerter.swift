import AppKit

/// Rozhoduje, kdy má na uživatele něco vyskočit, a posílá to ven.
///
/// Hystereze je tu důležitější než přesnost čidla: alert na každý vzorek by byl
/// k ničemu. Vstup do stavu „omezeno“ až po `enterAfter` vzorcích v řadě,
/// návrat po `exitAfter`, mezi dvěma alerty nejméně `config.cooldownSeconds`.
/// Zpráva o návratu do normálu cooldownu nepodléhá – ta musí dorazit vždy,
/// jinak uživatel neví, že může pokračovat.
final class Alerter {
    private var config = Config.load()
    private var badRun = 0
    private var goodRun = 0
    private var alerting = false
    private var lastAlertAt: Date?
    private var snoozedUntil: Date?
    private var panel: AlertPanel?
    /// Záznam o každém rozhodnutí – kvůli retrospektivě i kvůli testovatelnosti.
    var onEvent: ((String) -> Void)?

    let enterAfter = 3   // 3 vzorky po 5 s = 15 s
    let exitAfter = 6    // 30 s klidu, než prohlásím návrat

    func reloadConfig() { config = Config.load() }

    /// Pro ověření, že panel opravdu visí na obrazovce (viz `--test-alert`).
    var panelVisible: Bool { panel?.isVisible ?? false }

    /// Obsah panelu do PNG – doklad, že se vykreslil, bez snímání obrazovky.
    func consider(_ s: Sample) {
        let level = Verdict.overall(s)
        let bad = level == .throttling || (config.alertOnModerate && level == .mild)

        if bad {
            badRun += 1; goodRun = 0
        } else {
            goodRun += 1; badRun = 0
        }

        if !alerting, badRun >= enterAfter {
            alerting = true
            fireThrottleAlert(s)
        } else if alerting, goodRun >= exitAfter {
            alerting = false
            fireRecovery(s)
        }
    }

    @discardableResult
    func fireThrottleAlert(_ s: Sample) -> Bool {
        if let until = snoozedUntil, until > Date() {
            onEvent?("potlačeno – ztlumeno do \(Report.ts.string(from: until))")
            return false
        }
        if let last = lastAlertAt, Date().timeIntervalSince(last) < config.cooldownSeconds {
            onEvent?("potlačeno – cooldown běží")
            return false
        }
        lastAlertAt = Date()

        let top = Pressure.topProcesses(3)
        let topText = top.isEmpty
            ? "Žádný proces nevyčnívá."
            : "Nejvíc žere: " + top.map { String(format: "%@ %.0f %%", $0.name, $0.cpu) }
                                   .joined(separator: ", ")
        let speed = s.speedPct.map { String(format: " · rychlost %.0f %%", $0) } ?? ""
        let headline = "Tepelný tlak \(Pressure.name(s.pressure))\(speed)"
        let body = "\(headline)\n\(Verdict.cause(s))\n\(topText)"

        if config.panel {
            showPanel(title: "Mac tě teď zpomaluje", body: body, severity: .throttling)
        }
        if config.sound { NSSound(named: "Submarine")?.play() }
        sendRemote(body: "🔴 Mac tě teď zpomaluje\n\(body)", priority: "high", tags: "fire")
        onEvent?("ALERT · \(headline)")
        return true
    }

    func fireRecovery(_ s: Sample) {
        panel?.close()
        panel = nil
        guard lastAlertAt != nil else { return }
        let speed = s.speedPct.map { String(format: " · rychlost zpět na %.0f %%", $0) } ?? ""
        let body = "Tepelný tlak \(Pressure.name(s.pressure))\(speed)"
        sendRemote(body: "✅ Zpátky na plném výkonu\n\(body)", priority: "low", tags: "white_check_mark")
        onEvent?("NÁVRAT · \(body)")
    }

    /// Ukáže informační panel bez vazby na stav automatu (položka z menu).
    func showInfo(title: String, body: String) {
        let lvl = Verdict.pressureLevel(Pressure.level())
        showPanel(title: title, body: body, severity: lvl)
    }

    // MARK: - lokální panel

    private func showPanel(title: String, body: String, severity: Severity) {
        panel?.close()
        let p = AlertPanel(title: title, body: body, severity: severity,
                           onSnooze: { [weak self] in
                               self?.snoozedUntil = Date().addingTimeInterval(3600)
                           })
        p.present()
        panel = p
    }

    // MARK: - vzdálený kanál

    /// ntfy.sh: bez účtu, zdarma, stačí si v mobilní aplikaci odebírat téma.
    /// Hlavička `Title` snese jen ASCII, takže český text jde do těla zprávy.
    private func sendRemote(body: String, priority: String, tags: String) {
        guard config.remoteEnabled else { return }
        guard let url = URL(string: "\(config.ntfyServer)/\(config.ntfyTopic)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("ThermalWatch", forHTTPHeaderField: "Title")
        req.setValue(priority, forHTTPHeaderField: "Priority")
        req.setValue(tags, forHTTPHeaderField: "Tags")
        req.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.data(using: .utf8)
        URLSession.shared.dataTask(with: req) { _, resp, err in
            if let err {
                FileHandle.standardError.write(Data("ntfy: \(err.localizedDescription)\n".utf8))
            } else if let http = resp as? HTTPURLResponse, http.statusCode >= 300 {
                FileHandle.standardError.write(Data("ntfy: HTTP \(http.statusCode)\n".utf8))
            }
        }.resume()
    }
}

/// Barevný pruh u levého okraje panelu.
final class StripeView: NSView {
    var color: NSColor = .systemRed
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
    }
}

/// Plovoucí okno, které je vidět i nad aplikací na celou obrazovku.
///
/// Proč tohle a ne `display notification`: notifikace se při Focusu a při práci
/// na celou obrazovku schová do Centra oznámení a uživatel ji neuvidí – a právě
/// tehdy se vibecoduje. Panel má `.canJoinAllSpaces` + `.fullScreenAuxiliary` a
/// úroveň `.statusBar`, takže se zobrazí na aktuální ploše nad vším ostatním,
/// a jako `.nonactivatingPanel` přitom neukradne fokus z editoru.
final class AlertPanel: NSPanel {
    private let onSnooze: () -> Void

    init(title: String, body: String, severity: Severity, onSnooze: @escaping () -> Void) {
        self.onSnooze = onSnooze
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
                   styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
                   backing: .buffered, defer: false)
        self.title = "ThermalWatch"
        isFloatingPanel = true
        self.level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true

        // Bez `wantsLayer`: layer-backed strom se nedá vykreslit přes cacheDisplay,
        // což by rozbilo snímek panelu v `--test-alert`.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 260))

        let stripe = StripeView(frame: NSRect(x: 0, y: 0, width: 6, height: root.bounds.height))
        stripe.color = ChartView.colors[severity.rawValue]
        stripe.autoresizingMask = [.height]
        root.addSubview(stripe)

        let head = NSTextField(labelWithString: title)
        head.font = .systemFont(ofSize: 15, weight: .semibold)
        head.frame = NSRect(x: 20, y: root.bounds.height - 38, width: 420, height: 22)
        root.addSubview(head)

        let text = NSTextField(wrappingLabelWithString: body)
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textColor = .secondaryLabelColor
        text.frame = NSRect(x: 20, y: 46, width: 424, height: root.bounds.height - 92)
        root.addSubview(text)

        let ok = NSButton(title: "Rozumím", target: self, action: #selector(dismiss))
        ok.bezelStyle = .rounded
        ok.frame = NSRect(x: 350, y: 12, width: 94, height: 26)
        root.addSubview(ok)

        let snooze = NSButton(title: "Ztlumit na hodinu", target: self, action: #selector(snooze))
        snooze.bezelStyle = .rounded
        snooze.frame = NSRect(x: 200, y: 12, width: 146, height: 26)
        root.addSubview(snooze)

        contentView = root
    }

    func present() {
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            setFrameOrigin(NSPoint(x: v.maxX - frame.width - 16, y: v.maxY - frame.height - 16))
        }
        orderFrontRegardless()
    }

    @objc private func dismiss() { close() }

    @objc private func snooze() {
        onSnooze()
        close()
    }
}
