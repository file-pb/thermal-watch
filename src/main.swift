import AppKit
import Foundation

let args = Array(CommandLine.arguments.dropFirst())

func printOnce() {
    // Z CLI se měří vždycky: uživatel se ptá teď a sám.
    let s = Sampler.sample(baseline: Store.reference(), force: true)
    Store.append(s)
    // verdikt z okna, ne z jednoho vzorku (Verdict.smoothSeries)
    let w = Verdict.smoothSeries(Store.recent(minutes: 2))
    print(Report.statusLine(w.last ?? s))
}

switch args.first {
case "--once":
    printOnce()

case "--report":
    let m = Double(args.count > 1 ? args[1] : "30") ?? 30
    print(Report.retrospective(minutes: m))

case "--watch":
    let b = Store.reference()
    while true {
        let s = Sampler.sample(baseline: b, force: true)
        Store.append(s)
        let hist = Verdict.smoothSeries(Store.recent(minutes: 30))
        print("\u{1B}[2J\u{1B}[H", terminator: "")
        print("ThermalWatch — Ctrl-C ukončí\n")
        print(Report.statusLine(hist.last ?? s))
        print("\n30 min: \(Report.sparkline(hist))")
        print("        ▁ = 50 %, █ = 105 %")
        fflush(stdout)
        Thread.sleep(forTimeInterval: 5)
    }

case "--chart":
    // Vyrenderuje stejný graf jako menu, ale do PNG – na doložení stavu i na
    // ověření, že kreslení funguje, bez otevírání menu.
    let out = args.count > 1 ? args[1] : "thermalwatch.png"
    let mins = Double(args.count > 2 ? args[2] : "30") ?? 30
    let view = ChartView(frame: NSRect(x: 0, y: 0, width: 680, height: 236))
    view.samples = Verdict.smoothSeries(Store.recent(minutes: mins))
    view.windowMinutes = mins
    view.opaqueBackground = true
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try png.write(to: URL(fileURLWithPath: out))
    print("graf: \(out)  (\(view.samples.count) vzorků, \(Int(mins)) min)")

case "--test-alert":
    // Ověření obou kanálů najednou: panel i ntfy, bez čekání na skutečný throttling.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let alerter = Alerter()
    let s = Sampler.sample(baseline: Store.reference(), force: true)
    let shown = alerter.fireThrottleAlert(s)
    print("panel: \(shown ? "zobrazen" : "potlačen (cooldown/ztlumeno)")")
    print("ntfy: \(Config.load().remoteEnabled ? "odesláno na \(Config.load().ntfyServer)" : "nenakonfigurováno")")
    print("stav: \(Report.statusLine(s))")
    // Chvíli běž, ať se panel vykreslí a request odejde.
    RunLoop.main.run(until: Date().addingTimeInterval(2))
    print("panel na obrazovce: \(alerter.panelVisible)")
    RunLoop.main.run(until: Date().addingTimeInterval(8))

case "--stats":
    Stats.catchUp()
    print(Stats.report(days: Double(args.count > 1 ? args[1] : "7") ?? 7))

case "--who":
    print(Pressure.whoIsHeating())

case "--config":
    let c = Config.load()
    print("config: \(Config.url.path)")
    print("  ntfyTopic: \(c.ntfyTopic.isEmpty ? "(prázdné – vzdálený kanál vypnutý)" : c.ntfyTopic)")
    print("  ntfyServer: \(c.ntfyServer)")
    print("  panel: \(c.panel) · sound: \(c.sound) · cooldown: \(Int(c.cooldownSeconds)) s")
    print("  alertOnModerate: \(c.alertOnModerate)")

case "--help", "-h":
    print("""
    ThermalWatch — omezuje mě teplota Macu?

      thermalwatch              indikátor v menu baru (sbírá data, kreslí 30min graf)
      thermalwatch --once       jeden odečet a konec
      thermalwatch --watch      průběžně v terminálu
      thermalwatch --report [m] retrospektiva za posledních m minut (výchozí 30)
      thermalwatch --chart f.png [m]  graf do PNG
      thermalwatch --test-alert zkušební upozornění (panel + ntfy)
      thermalwatch --who        co ti právě teď hřeje stroj
      thermalwatch --stats [d]  rozpad: co tě za posledních d dní nejvíc zpomalovalo
      thermalwatch --config     vypíše nastavení a cestu ke config.json

    Data: \(Store.dir.path)
    """)

default:
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // jen menu bar, žádná ikona v Docku
    app.run()
}
