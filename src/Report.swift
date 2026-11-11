import Foundation

/// Textové výstupy – pro terminál i pro „zkopírovat stav“ z menu.
struct Report {
    static let ts: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    static func statusLine(_ s: Sample) -> String {
        let lvl = Verdict.overall(s)
        let mark = ["✅", "🟠", "🔴"][lvl.rawValue]
        var extra = ""
        if s.lowPower { extra += " [low power]" }
        if !s.onAC { extra += " [baterie]" }
        return String(
            format: "%@ %@ — %@ · rychlost %.0f %% · load %.2f%@",
            mark, lvl.label, Verdict.cause(s), s.speedPct, s.load1, extra
        )
    }

    /// Sparkline z procent efektivní rychlosti, 50–105 % na osmi úrovních.
    static func sparkline(_ samples: [Sample], width: Int = 60) -> String {
        guard !samples.isEmpty else { return "(bez dat)" }
        let blocks = Array("▁▂▃▄▅▆▇█")
        let buckets = max(1, min(width, samples.count))
        var out = ""
        for i in 0..<buckets {
            let lo = i * samples.count / buckets
            let hi = max(lo + 1, (i + 1) * samples.count / buckets)
            let slice = samples[lo..<hi]
            let worst = slice.map(\.speedPct).min() ?? 100
            let norm = max(0.0, min(1.0, (worst - 50) / 55))
            out.append(blocks[Int(norm * 7.0 + 0.5)])
        }
        return out
    }

    /// Retrospektiva: kdy to stálo a co v tu chvíli dělala teplota.
    static func retrospective(minutes: Double) -> String {
        let all = Verdict.smoothSeries(Store.recent(minutes: minutes))
        guard !all.isEmpty else {
            return "Žádná data za posledních \(Int(minutes)) min — běží sběr? (ThermalWatch v menu baru)"
        }
        var lines: [String] = []
        lines.append("ThermalWatch — posledních \(Int(minutes)) min, \(all.count) vzorků")
        lines.append("rychlost: \(sparkline(all))   (▁ = 50 %, █ = 105 %)")
        let worst = all.min { Verdict.overall($0).rawValue == Verdict.overall($1).rawValue
            ? $0.speedPct < $1.speedPct
            : Verdict.overall($0).rawValue > Verdict.overall($1).rawValue }
        if let w = worst {
            lines.append("nejhorší: \(ts.string(from: Date(timeIntervalSince1970: w.t))) — \(statusLine(w))")
        }
        let throttled = all.filter { Verdict.overall($0) == .throttling }
        let mild = all.filter { Verdict.overall($0) == .mild }
        lines.append(String(format: "podíl času: throttling %.0f %% · mírné %.0f %% · OK %.0f %%",
                            100 * Double(throttled.count) / Double(all.count),
                            100 * Double(mild.count) / Double(all.count),
                            100 * Double(all.count - throttled.count - mild.count) / Double(all.count)))
        // minutové agregace jen tam, kde nebylo OK
        var flagged: [String] = []
        var lastMinute = ""
        for s in all where Verdict.overall(s) != .ok {
            let m = String(ts.string(from: Date(timeIntervalSince1970: s.t)).prefix(5))
            if m == lastMinute { continue }
            lastMinute = m
            flagged.append(String(format: "  %@  %.0f %%  thermal %@  load %.1f",
                                  m, s.speedPct, Verdict.thermalName(s.thermal), s.load1))
        }
        if !flagged.isEmpty {
            lines.append("minuty s omezením:")
            lines.append(contentsOf: flagged.prefix(40))
        }
        lines.append("log: \(Store.logURL.path)")
        return lines.joined(separator: "\n")
    }
}
