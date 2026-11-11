import Foundation

/// Stav a log nástroje. Nikdy nezapisuje do repozitáře, se kterým uživatel pracuje:
/// všechno jde do ~/Library/Application Support/ThermalWatch/.
struct Store {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("ThermalWatch", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static var logURL: URL { dir.appendingPathComponent("samples.jsonl") }
    static var stateURL: URL { dir.appendingPathComponent("state.json") }
    /// Hodinové souhrny. Na rozdíl od syrových vzorků se nemažou – rok vyjde
    /// na jednotky MB a je to jediné, co umožní dívat se zpátky dál než týden.
    static var hoursURL: URL { dir.appendingPathComponent("hours.jsonl") }

    struct State: Codable {
        var baselineNanos: UInt64
        /// Začátek poslední hodiny, která je už shrnutá v hours.jsonl.
        var lastAggregatedHour: Double?
    }

    // MARK: - kalibrace

    static func loadBaseline() -> UInt64? {
        guard let d = try? Data(contentsOf: stateURL),
              let s = try? JSONDecoder().decode(State.self, from: d),
              s.baselineNanos > 0 else { return nil }
        return s.baselineNanos
    }

    static func loadState() -> State {
        guard let d = try? Data(contentsOf: stateURL),
              let s = try? JSONDecoder().decode(State.self, from: d) else {
            return State(baselineNanos: 0, lastAggregatedHour: nil)
        }
        return s
    }

    static func saveState(_ s: State) {
        try? JSONEncoder().encode(s).write(to: stateURL, options: .atomic)
    }

    static func saveBaseline(_ ns: UInt64) {
        var s = loadState()
        s.baselineNanos = ns
        saveState(s)
    }

    /// Referenční čas pro 100 %: **desátý percentil** časů naměřených ve stejných
    /// podmínkách (agent vs. CLI) za posledních 7 dní.
    ///
    /// Ne minimum. Měření agenta je dvouvrcholové – občas ~360 µs, když je jádro
    /// od jiné práce rozjeté, obvykle ~600 µs. Minimum se chytne té výjimky a pak
    /// i úplně zdravý stroj hlásí 60 %. Percentil říká „jak rychle to tady jede,
    /// když je dobře“, a to je ta správná referenční hodnota.
    ///
    /// Absolutní pravdu o omezení nese tepelný tlak, tahle metrika říká *o kolik*.
    static func reference() -> UInt64 {
        let mine = read(since: Date().timeIntervalSince1970 - 7 * 86_400)
            .filter { ($0.gui ?? false) == Sampler.isGUI }
        let measured = mine.compactMap(\.nanos)
        if measured.count >= 60 {
            let sorted = measured.sorted()
            return sorted[sorted.count / 10]
        }
        if let b = loadBaseline() { return b }
        let b = Sampler.calibrate()
        saveBaseline(b)
        return b
    }

    // MARK: - log

    static func append(_ s: Sample) {
        guard let line = try? JSONEncoder().encode(s) else { return }
        var data = line
        data.append(0x0a)
        if let h = try? FileHandle(forWritingTo: logURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }

    /// Vzorky od daného času. Okno čtení se počítá z délky dotazu: při 12 vzorcích
    /// za minutu a ~200 B na řádek stačí ~2,5 KB/min, beru 4 KB s rezervou. Pevné
    /// okno by při týdenní retenci tiše vracelo jen poslední hodiny – a `trim()`,
    /// který z toho zapisuje zpátky, by zbytek smazal.
    static func read(since: Double) -> [Sample] {
        guard let h = try? FileHandle(forReadingFrom: logURL) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let minutes = max(1, (Date().timeIntervalSince1970 - since) / 60)
        let window = min(UInt64(minutes * 4096) + 262_144, 128 * 1024 * 1024)
        let start = size > window ? size - window : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd() else { return [] }
        let dec = JSONDecoder()
        var out: [Sample] = []
        for line in data.split(separator: 0x0a) {
            guard let s = try? dec.decode(Sample.self, from: line) else { continue }
            if s.t >= since { out.append(s) }
        }
        return out
    }

    static func recent(minutes: Double) -> [Sample] {
        read(since: Date().timeIntervalSince1970 - minutes * 60)
    }

    /// Zkrátí syrový log. Tři dny stačí na detail, delší pohled jde z hours.jsonl
    /// (~3 MB/den syrově proti jednotkám MB za rok souhrnů).
    static func trim(hours: Double = 24 * 3) {
        // Vzorky bez tepelného tlaku jsou z verze před zavedením notify klíče,
        // do statistik by jen šuměly.
        let all = read(since: 0)
        let keep = all.filter { $0.pressure != nil && $0.t >= Date().timeIntervalSince1970 - hours * 3600 }
        guard !keep.isEmpty, keep.count != all.count else { return }
        let enc = JSONEncoder()
        var data = Data()
        for s in keep {
            guard let l = try? enc.encode(s) else { continue }
            data.append(l); data.append(0x0a)
        }
        try? data.write(to: logURL, options: .atomic)
    }
}
