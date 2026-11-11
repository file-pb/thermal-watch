import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var baseline: UInt64 = 0
    private var samples: [Sample] = []
    private var lastSpeed: Double?

    private let alerter = Alerter()
    private var config = Config.load()
    private let chart = ChartView(frame: NSRect(x: 0, y: 0, width: 340, height: 118))
    private let headline = NSMenuItem(title: "…", action: nil, keyEquivalent: "")
    private let sensors = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var blockItems: [String: NSMenuItem] = [:]
    private let detail = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let summary = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    /// Interval vzorkování. Jeden vzorek = Sampler.warmups + Sampler.bursts = 40 dávek
    /// po ~0,4 ms, tedy ~16 ms práce jednoho jádra každých 5 s: 0,3 % jednoho jádra,
    /// 0,03 % stroje s deseti jádry.
    private let interval: TimeInterval = 5

    /// Drží App Nap od těla – bez toho systém procesu na pozadí utlumí plánování
    /// a měření rychlosti by vycházelo falešně nízké.
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ n: Notification) {
        alerter.onEvent = { line in
            let stamp = Report.ts.string(from: Date())
            let data = Data("\(stamp)  \(line)\n".utf8)
            let url = Store.dir.appendingPathComponent("alerts.log")
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated, reason: "thermal sampling")
        Sampler.isGUI = true
        Store.trim()
        Stats.catchUp()
        baseline = Store.reference()
        samples = Store.recent(minutes: 30)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusItem.button?.imagePosition = .imageTrailing
        statusItem.button?.imageHugsTitle = true

        let menu = NSMenu()
        let chartItem = NSMenuItem()
        chartItem.view = chart
        menu.addItem(headline)
        menu.addItem(detail)
        menu.addItem(chartItem)
        menu.addItem(.separator())
        menu.addItem(summary)
        menu.addItem(.separator())
        menu.addItem(sensors)
        menu.addItem(.separator())
        for (title, key) in [("V liště: rychlost", "speed"),
                             ("V liště: teplota", "heat"),
                             ("V liště: CPU", "cpu"),
                             ("V liště: paměť", "mem"),
                             ("V liště: síť", "net")] {
            let item = NSMenuItem(title: title, action: #selector(toggleBlock(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            blockItems[key] = item
            menu.addItem(item)
        }
        syncBlockStates()
        let who = NSMenuItem(title: "Co mě teď hřeje…", action: #selector(showWho), keyEquivalent: "")
        who.target = self
        menu.addItem(who)
        let stats = NSMenuItem(title: "Zkopírovat statistiku za 7 dní",
                               action: #selector(copyStats), keyEquivalent: "")
        stats.target = self
        menu.addItem(stats)
        let copy = NSMenuItem(title: "Zkopírovat report za 30 min",
                              action: #selector(copyReport), keyEquivalent: "c")
        copy.target = self
        menu.addItem(copy)
        let reveal = NSMenuItem(title: "Otevřít adresář s logem",
                                action: #selector(revealLog), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        let test = NSMenuItem(title: "Zkusit upozornění",
                              action: #selector(testAlert), keyEquivalent: "")
        test.target = self
        menu.addItem(test)
        let conf = NSMenuItem(title: "Otevřít nastavení (config.json)",
                              action: #selector(openConfig), keyEquivalent: "")
        conf.target = self
        menu.addItem(conf)
        let recal = NSMenuItem(title: "Překalibrovat 100 %",
                               action: #selector(recalibrate), keyEquivalent: "")
        recal.target = self
        menu.addItem(recal)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Ukončit ThermalWatch",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        NotificationCenter.default.addObserver(
            self, selector: #selector(tick),
            name: ProcessInfo.thermalStateDidChangeNotification, object: nil)

        tick()
        timer = Timer.scheduledTimer(timeInterval: interval, target: self,
                                     selector: #selector(tick), userInfo: nil, repeats: true)
        timer?.tolerance = 1
        // Hodinové souhrny jsou to jediné, co přežije mazání syrových vzorků.
        let agg = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Stats.catchUp()
            // Referenci přepočítat, ať se usazuje podle toho, co stroj opravdu umí.
            self?.baseline = Store.reference()
        }
        agg.tolerance = 60
    }

    @objc private func tick() {
        let s = Sampler.sample(baseline: baseline)
        Store.append(s)
        samples.append(s)
        let cutoff = Date().timeIntervalSince1970 - 30 * 60
        samples.removeAll { $0.t < cutoff }
        render(s)
        // Alert se rozhoduje z vyhlazené řady, ne z jednoho vzorku.
        if let smoothed = Verdict.smoothSeries(samples).last { alerter.consider(smoothed) }
    }

    private func render(_ raw: Sample) {
        let smooth = Verdict.smoothSeries(samples)
        let s = smooth.last ?? raw
        // Rychlost se měří jednou za minutu, takže většina vzorků ji nemá. Drží se
        // proto poslední známá hodnota – jinak by číslo v liště každou minutu
        // probliklo a zase zmizelo.
        if let fresh = samples.last(where: { $0.speedPct != nil }),
           Date().timeIntervalSince1970 - fresh.t < 5 * 60 {
            lastSpeed = fresh.speedPct
        }
        statusItem.button?.title = ""
        statusItem.button?.image = AppDelegate.menuBarImage(smooth, config: config, speed: lastSpeed)

        headline.title = Report.statusLine(s)
        let measured = raw.nanos.map {
            String(format: "poslední měření %.0f µs → %.0f %% · 100 %% = %.0f µs",
                   Double($0) / 1000, raw.speedPct ?? 0, Double(baseline) / 1000)
        } ?? "rychlost se měří jednou za minutu"
        detail.title = "tlak \(Pressure.name(raw.pressure)) · \(measured)"
            + (raw.lowPower ? " · Low Power Mode" : "")

        var bits: [String] = [String(format: "CPU %.0f %%", Verdict.busy(raw))]
        if let m = raw.mem { bits.append(String(format: "RAM %.0f %%", m)) }
        if let t = raw.tempC { bits.append(String(format: "%.0f °C", t)) }
        if let i = raw.netIn, let o = raw.netOut {
            func fmt(_ v: Double) -> String {
                v >= 1024 ? String(format: "%.1f MB/s", v / 1024) : String(format: "%.0f kB/s", v)
            }
            bits.append("↓ \(fmt(i))  ↑ \(fmt(o))")
        }
        sensors.title = bits.joined(separator: "  ·  ")

        chart.samples = smooth
        chart.needsDisplay = true

        if smooth.isEmpty {
            summary.title = ""
        } else {
            let bad = smooth.filter { Verdict.overall($0) != .ok }.count
            let worstPct = smooth.compactMap(\.speedPct).min() ?? 100
            summary.title = String(
                format: "30 min: %d vzorků · omezení v %.0f %% času · minimum %.0f %%",
                smooth.count, 100 * Double(bad) / Double(smooth.count), worstPct)
        }
    }

    @objc private func copyReport() {
        let text = Report.retrospective(minutes: 30)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Jeden sloupec mini grafu: hodnota 0–1, volitelná druhá série a barva.
    private struct Col {
        var v: CGFloat
        var v2: CGFloat?
        var color: NSColor
    }

    /// Blok v liště = hodnota a hned za ní její grafík.
    private struct Block {
        let label: String
        let dot: NSColor?
        let cols: [Col?]
    }

    private static let graphWidth: CGFloat = 26
    private static let barWidth: CGFloat = 2
    private static let blockGap: CGFloat = 7
    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    private static func columns(_ samples: [Sample],
                                value: (Sample) -> (CGFloat, CGFloat?, NSColor)?) -> [Col?] {
        let count = Int(graphWidth / barWidth)
        var out = [Col?](repeating: nil, count: count)
        let window: Double = 30 * 60
        let now = Date().timeIntervalSince1970
        for s in samples {
            let age = now - s.t
            guard age >= 0, age <= window, let (v, v2, c) = value(s) else { continue }
            let i = min(count - 1, Int((1 - age / window) * Double(count)))
            if out[i] == nil || v > out[i]!.v { out[i] = Col(v: v, v2: v2, color: c) }
        }
        return out
    }

    private static func blocks(_ samples: [Sample], config: Config,
                               speed: Double?) -> [Block] {
        var out: [Block] = []
        let last = samples.last

        if config.blockSpeed {
            let sev = last.map { Verdict.overall($0) } ?? .ok
            out.append(Block(
                label: speed.map { "\(Int($0.rounded())) %" } ?? "–",
                dot: ChartView.colors[sev.rawValue],
                cols: columns(samples) { s in
                    guard let p = s.speedPct else { return nil }
                    // 50–110 % na celou výšku
                    return (CGFloat((p - 50) / 60), nil, ChartView.colors[Verdict.overall(s).rawValue])
                }))
        }
        if config.blockHeat {
            out.append(Block(
                label: last?.tempC.map { String(format: "%.0f°", $0) } ?? "–",
                dot: nil,
                cols: columns(samples) { s in
                    let color = ChartView.colors[Verdict.pressureLevel(s.pressure).rawValue]
                    guard let t = s.tempC else {
                        return (max(0.08, CGFloat(s.pressure ?? 0) / 3), nil, color)
                    }
                    return (CGFloat((t - 35) / 60), nil, color)   // 35–95 °C
                }))
        }
        if config.blockCpu {
            out.append(Block(
                label: last.map { String(format: "%.0f %%", Verdict.busy($0)) } ?? "–",
                dot: nil,
                cols: columns(samples) { (CGFloat(Verdict.busy($0) / 100), nil, .systemBlue) }))
        }
        if config.blockMem {
            out.append(Block(
                label: last?.mem.map { String(format: "%.0f %%", $0) } ?? "–",
                dot: nil,
                cols: columns(samples) { s in
                    s.mem.map { (CGFloat($0 / 100), nil, NSColor.systemPurple) }
                }))
        }
        if config.blockNet {
            // Logaritmicky: 1 kB/s až 10 MB/s se vejde do třinácti bodů výšky.
            func scale(_ v: Double) -> CGFloat { v > 1 ? CGFloat(min(1, log10(v) / 4)) : 0 }
            func short(_ v: Double) -> String {
                v >= 1024 ? String(format: "%.1fM", v / 1024) : String(format: "%.0fk", v)
            }
            out.append(Block(
                label: last.flatMap { $0.netIn.map { i in "↓" + short(i) } } ?? "–",
                dot: nil,
                cols: columns(samples) { s in
                    guard let i = s.netIn, let o = s.netOut else { return nil }
                    return (scale(i), scale(o), NSColor.systemTeal)
                }))
        }
        return out
    }

    /// Celá lišta jako jeden obrázek: dvojice „hodnota + grafík“ vedle sebe.
    /// Kreslí se to ručně, protože `NSStatusItem` umí jen jeden text a jeden
    /// obrázek – prokládat je jinak nejde.
    static func menuBarImage(_ samples: [Sample], config: Config,
                             speed: Double?, height: CGFloat = 18) -> NSImage? {
        let bl = blocks(samples, config: config, speed: speed)
        guard !bl.isEmpty else { return nil }

        let attrs: [NSAttributedString.Key: Any] = [.font: labelFont]
        func labelWidth(_ b: Block) -> CGFloat {
            (b.label as NSString).size(withAttributes: attrs).width.rounded(.up)
                + (b.dot == nil ? 0 : 12)
        }
        let width = bl.reduce(0) { $0 + labelWidth($1) + 3 + graphWidth }
            + CGFloat(bl.count - 1) * blockGap

        let img = NSImage(size: NSSize(width: width, height: height))
        img.lockFocus()
        defer { img.unlockFocus() }

        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            var x: CGFloat = 0
            let textY = (height - labelFont.capHeight) / 2 - labelFont.descender / 2 - 4
            for b in bl {
                if let dot = b.dot {
                    dot.setFill()
                    NSBezierPath(ovalIn: NSRect(x: x, y: height / 2 - 3.5, width: 7, height: 7)).fill()
                    x += 12
                }
                (b.label as NSString).draw(
                    at: NSPoint(x: x, y: textY),
                    withAttributes: [.font: labelFont, .foregroundColor: NSColor.labelColor])
                x += (b.label as NSString).size(withAttributes: attrs).width.rounded(.up) + 3

                NSColor.tertiaryLabelColor.setFill()
                NSRect(x: x, y: 2, width: graphWidth, height: 1).fill()
                for (i, col) in b.cols.enumerated() {
                    guard let col else { continue }
                    let h = max(1, min(height - 4, col.v * (height - 5) + 1))
                    col.color.withAlphaComponent(0.9).setFill()
                    NSRect(x: x + CGFloat(i) * barWidth, y: 2, width: barWidth, height: h).fill()
                    if let v2 = col.v2 {
                        let y = 2 + max(1, min(height - 4, v2 * (height - 5) + 1))
                        col.color.blended(withFraction: 0.5, of: .labelColor)?.setFill()
                        NSRect(x: x + CGFloat(i) * barWidth, y: y, width: barWidth, height: 1).fill()
                    }
                }
                x += graphWidth + blockGap
            }
        }
        return img
    }

    private func syncBlockStates() {
        blockItems["speed"]?.state = config.blockSpeed ? .on : .off
        blockItems["heat"]?.state = config.blockHeat ? .on : .off
        blockItems["cpu"]?.state = config.blockCpu ? .on : .off
        blockItems["mem"]?.state = config.blockMem ? .on : .off
        blockItems["net"]?.state = config.blockNet ? .on : .off
    }

    @objc private func toggleBlock(_ sender: NSMenuItem) {
        switch sender.representedObject as? String {
        case "speed": config.blockSpeed.toggle()
        case "heat": config.blockHeat.toggle()
        case "cpu": config.blockCpu.toggle()
        case "mem": config.blockMem.toggle()
        case "net": config.blockNet.toggle()
        default: return
        }
        config.save()
        syncBlockStates()
        tick()
    }

    @objc private func showWho() {
        alerter.showInfo(title: "Co mě teď hřeje", body: Pressure.whoIsHeating())
    }

    @objc private func copyStats() {
        Stats.catchUp()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Stats.report(days: 7), forType: .string)
    }

    @objc private func revealLog() {
        NSWorkspace.shared.selectFile(Store.logURL.path,
                                      inFileViewerRootedAtPath: Store.dir.path)
    }

    @objc private func testAlert() {
        let base = baseline > 0 ? baseline : 1
        alerter.reloadConfig()
        config = Config.load()
        alerter.fireThrottleAlert(Sampler.sample(baseline: base, force: true))
    }

    @objc private func openConfig() {
        config = Config.load() // vytvoří soubor, když ještě není
        NSWorkspace.shared.selectFile(Config.url.path, inFileViewerRootedAtPath: Store.dir.path)
    }

    @objc private func recalibrate() {
        baseline = Sampler.calibrate()
        tick()
    }
}
