import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var baseline: UInt64 = 0
    private var samples: [Sample] = []

    private let alerter = Alerter()
    private let chart = ChartView(frame: NSRect(x: 0, y: 0, width: 340, height: 118))
    private let headline = NSMenuItem(title: "…", action: nil, keyEquivalent: "")
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
        Store.trim()
        baseline = Store.baseline()
        samples = Store.recent(minutes: 30)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        let menu = NSMenu()
        let chartItem = NSMenuItem()
        chartItem.view = chart
        menu.addItem(headline)
        menu.addItem(detail)
        menu.addItem(chartItem)
        menu.addItem(.separator())
        menu.addItem(summary)
        menu.addItem(.separator())
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
    }

    @objc private func tick() {
        let s = Sampler.sample(baseline: baseline)
        // 100 % se zpřesňuje na nejlepší kdy viděný čas
        if s.nanos < baseline {
            baseline = s.nanos
            Store.saveBaseline(baseline)
        }
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
        let lvl = Verdict.overall(s)
        let glyph = ["●", "●", "●"][lvl.rawValue]
        let title = NSMutableAttributedString(
            string: "\(glyph) \(Int(s.speedPct.rounded())) %",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ])
        title.addAttribute(.foregroundColor, value: ChartView.colors[lvl.rawValue],
                           range: NSRange(location: 0, length: 1))
        statusItem.button?.attributedTitle = title

        headline.title = Report.statusLine(s)
        detail.title = String(
            format: "tlak %@ · poslední měření %.0f µs → %.0f %% · 100 %% = %.0f µs%@",
            Pressure.name(raw.pressure), Double(raw.nanos) / 1000, raw.speedPct,
            Double(baseline) / 1000,
            raw.lowPower ? " · Low Power Mode" : "")

        chart.samples = smooth
        chart.needsDisplay = true

        if smooth.isEmpty {
            summary.title = ""
        } else {
            let bad = smooth.filter { Verdict.overall($0) != .ok }.count
            let worstPct = smooth.map(\.speedPct).min() ?? 100
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

    @objc private func revealLog() {
        NSWorkspace.shared.selectFile(Store.logURL.path,
                                      inFileViewerRootedAtPath: Store.dir.path)
    }

    @objc private func testAlert() {
        let base = baseline > 0 ? baseline : 1
        alerter.reloadConfig()
        alerter.fireThrottleAlert(Sampler.sample(baseline: base))
    }

    @objc private func openConfig() {
        _ = Config.load() // vytvoří soubor, když ještě není
        NSWorkspace.shared.selectFile(Config.url.path, inFileViewerRootedAtPath: Store.dir.path)
    }

    @objc private func recalibrate() {
        baseline = Sampler.calibrate()
        Store.saveBaseline(baseline)
        tick()
    }
}
