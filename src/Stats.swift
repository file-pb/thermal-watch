import Foundation

/// Hodinový souhrn. Syrové vzorky se po týdnu mažou, tyhle zůstávají –
/// rok vyjde na jednotky MB a je to jediné, z čeho jde dívat se zpátky dál.
struct HourStat: Codable {
    var hour: Double          // začátek hodiny, unix epoch
    var n = 0                 // vzorků
    var ok = 0, mild = 0, bad = 0
    var pNominal = 0, pModerate = 0, pHeavy = 0, pWorse = 0
    var causeHeat = 0, causeLoad = 0, causeLowPower = 0, causeOther = 0
    var speedSum = 0.0
    var speedMin = 999.0
    var speedN = 0
    var loadSum = 0.0
    var loadMax = 0.0
    /// Kolikrát byl proces mezi třemi nejžravějšími ve chvíli zpomalení.
    var culprits: [String: Int] = [:]
    /// Kolik takových odečtů celkem – jmenovatel pro podíly výše.
    var culpritReads = 0
}

enum Stats {
    static let hourSeconds: Double = 3600

    // MARK: - agregace

    static func hourStart(_ t: Double) -> Double { (t / hourSeconds).rounded(.down) * hourSeconds }

    /// Složí vzorky jedné hodiny. Vyhlazení je stejné jako v UI, aby statistika
    /// říkala totéž co indikátor.
    static func fold(_ raw: [Sample]) -> HourStat {
        var h = HourStat(hour: hourStart(raw.first?.t ?? 0))
        for s in Verdict.smoothSeries(raw) {
            h.n += 1
            switch Verdict.overall(s) {
            case .ok: h.ok += 1
            case .mild: h.mild += 1
            case .throttling: h.bad += 1
            }
            switch s.pressure ?? 0 {
            case 0: h.pNominal += 1
            case 1: h.pModerate += 1
            case 2: h.pHeavy += 1
            default: h.pWorse += 1
            }
            switch Verdict.causeKind(s) {
            case .heat: h.causeHeat += 1
            case .load: h.causeLoad += 1
            case .lowPower: h.causeLowPower += 1
            case .other: h.causeOther += 1
            case .none: break
            }
            if let pct = s.speedPct {
                h.speedN += 1
                h.speedSum += pct
                h.speedMin = min(h.speedMin, pct)
            }
            h.loadSum += s.load1
            h.loadMax = max(h.loadMax, s.load1)
            if let top = s.top, !top.isEmpty {
                h.culpritReads += 1
                for proc in top { h.culprits[proc.n, default: 0] += 1 }
            }
        }
        return h
    }

    /// Zapíše do hours.jsonl všechny hodiny, které už skončily a ještě nejsou uložené.
    /// Běží při startu a jednou za hodinu; je idempotentní, takže pád nic nerozbije.
    static func catchUp() {
        var state = Store.loadState()
        let currentHour = hourStart(Date().timeIntervalSince1970)
        let from = state.lastAggregatedHour ?? 0
        let raw = Store.read(since: from)
        guard !raw.isEmpty else { return }

        var byHour: [Double: [Sample]] = [:]
        for s in raw {
            let h = hourStart(s.t)
            guard h > from, h < currentHour else { continue }
            byHour[h, default: []].append(s)
        }
        guard !byHour.isEmpty else { return }

        let enc = JSONEncoder()
        var out = Data()
        for h in byHour.keys.sorted() {
            guard let line = try? enc.encode(fold(byHour[h]!)) else { continue }
            out.append(line); out.append(0x0a)
        }
        if let fh = try? FileHandle(forWritingTo: Store.hoursURL) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: out)
        } else {
            try? out.write(to: Store.hoursURL)
        }
        state.lastAggregatedHour = byHour.keys.max()
        Store.saveState(state)
    }

    // MARK: - čtení

    /// Uložené hodiny za posledních `days` dní plus rozpracovaná aktuální hodina.
    static func load(days: Double) -> [HourStat] {
        let cutoff = Date().timeIntervalSince1970 - days * 86_400
        var out: [HourStat] = []
        if let data = try? Data(contentsOf: Store.hoursURL) {
            let dec = JSONDecoder()
            for line in data.split(separator: 0x0a) {
                guard let h = try? dec.decode(HourStat.self, from: line), h.hour >= cutoff else { continue }
                out.append(h)
            }
        }
        let lastStored = out.map(\.hour).max() ?? 0
        let fresh = Store.read(since: lastStored).filter { hourStart($0.t) > lastStored }
        var byHour: [Double: [Sample]] = [:]
        for s in fresh { byHour[hourStart(s.t), default: []].append(s) }
        for h in byHour.keys.sorted() { out.append(fold(byHour[h]!)) }
        return out.sorted { $0.hour < $1.hour }
    }

    // MARK: - report

    static func report(days: Double) -> String {
        let hours = load(days: days)
        let total = hours.reduce(0) { $0 + $1.n }
        guard total > 0 else {
            return "Zatím žádná data. Běží agent? (`launchctl list | grep thermalwatch`)"
        }

        let interval = 5.0 // sekund na vzorek, viz App.interval
        func dur(_ samples: Int) -> String {
            let m = Double(samples) * interval / 60
            return m >= 60 ? String(format: "%.1f h", m / 60) : String(format: "%.0f min", m)
        }
        func pct(_ part: Int) -> String { String(format: "%.0f %%", 100 * Double(part) / Double(total)) }

        let df = DateFormatter(); df.dateFormat = "d. M. HH:mm"
        var out: [String] = []
        out.append("ThermalWatch — statistika za \(Int(days)) dní")
        out.append("od \(df.string(from: Date(timeIntervalSince1970: hours.first!.hour))) · \(total) vzorků ≈ \(dur(total)) měřeného času")
        out.append("")

        let ok = hours.reduce(0) { $0 + $1.ok }
        let mild = hours.reduce(0) { $0 + $1.mild }
        let bad = hours.reduce(0) { $0 + $1.bad }
        out.append("stav:   OK \(pct(ok)) · mírné \(pct(mild)) · zpomaleno \(pct(bad))")

        let nom = hours.reduce(0) { $0 + $1.pNominal }
        let mod = hours.reduce(0) { $0 + $1.pModerate }
        let hvy = hours.reduce(0) { $0 + $1.pHeavy }
        let wrs = hours.reduce(0) { $0 + $1.pWorse }
        out.append("tlak:   Nominal \(pct(nom)) · Moderate \(pct(mod)) · Heavy \(pct(hvy)) · horší \(pct(wrs))")
        out.append("        Heavy a horší = \(dur(hvy + wrs)) skutečného omezení výkonu")

        let heat = hours.reduce(0) { $0 + $1.causeHeat }
        let load = hours.reduce(0) { $0 + $1.causeLoad }
        let lpm = hours.reduce(0) { $0 + $1.causeLowPower }
        let other = hours.reduce(0) { $0 + $1.causeOther }
        let causeTotal = max(1, heat + load + lpm + other)
        func cp(_ v: Int) -> String { String(format: "%.0f %%", 100 * Double(v) / Double(causeTotal)) }
        out.append("")
        out.append("co za to mohlo (z \(dur(heat + load + lpm + other)) nad stavem OK):")
        out.append("        teplo \(cp(heat)) · zátěž CPU \(cp(load)) · Low Power \(cp(lpm)) · jen pokles rychlosti \(cp(other))")

        var culprits: [String: Int] = [:]
        var reads = 0
        for h in hours {
            reads += h.culpritReads
            for (k, v) in h.culprits { culprits[k, default: 0] += v }
        }
        out.append("")
        if reads == 0 {
            out.append("viníci: zatím žádný odečet — stroj nebyl horký (sbírá se jen při tlaku ≥ Moderate)")
        } else {
            out.append("když byl stroj horký, nejčastěji u toho byly (\(reads) odečtů):")
            for (name, c) in culprits.sorted(by: { $0.value > $1.value }).prefix(8) {
                out.append(String(format: "   %5.0f %%  %@", 100 * Double(c) / Double(reads), name))
            }
        }

        // nejhorší hodiny dne
        var byHourOfDay = [Int](repeating: 0, count: 24)
        var totalByHourOfDay = [Int](repeating: 0, count: 24)
        let cal = Calendar.current
        for h in hours {
            let hod = cal.component(.hour, from: Date(timeIntervalSince1970: h.hour))
            byHourOfDay[hod] += h.bad + h.mild
            totalByHourOfDay[hod] += h.n
        }
        let ranked = (0..<24)
            .filter { totalByHourOfDay[$0] > 0 }
            .map { ($0, Double(byHourOfDay[$0]) / Double(totalByHourOfDay[$0])) }
            .sorted { $0.1 > $1.1 }
            .prefix(3)
        if let worst = ranked.first, worst.1 > 0 {
            out.append("")
            out.append("nejhorší hodiny dne:")
            for (h, share) in ranked where share > 0 {
                out.append(String(format: "   %02d:00  %.0f %% času nad stavem OK", h, 100 * share))
            }
        }

        out.append("")
        out.append("souhrny: \(Store.hoursURL.path)")
        return out.joined(separator: "\n")
    }
}
