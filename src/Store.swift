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

    struct State: Codable { var baselineNanos: UInt64 }

    // MARK: - kalibrace

    static func loadBaseline() -> UInt64? {
        guard let d = try? Data(contentsOf: stateURL),
              let s = try? JSONDecoder().decode(State.self, from: d),
              s.baselineNanos > 0 else { return nil }
        return s.baselineNanos
    }

    static func saveBaseline(_ ns: UInt64) {
        let d = try? JSONEncoder().encode(State(baselineNanos: ns))
        try? d?.write(to: stateURL, options: .atomic)
    }

    /// Při prvním spuštění změří referenci, dál se zpřesňuje na nejlepší viděný čas.
    static func baseline() -> UInt64 {
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

    /// Vzorky za posledních `minutes` minut. Čte jen konec souboru (max 2 MB).
    static func recent(minutes: Double) -> [Sample] {
        guard let h = try? FileHandle(forReadingFrom: logURL) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let window: UInt64 = 2 * 1024 * 1024
        let start = size > window ? size - window : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd() else { return [] }
        let cutoff = Date().timeIntervalSince1970 - minutes * 60
        let dec = JSONDecoder()
        var out: [Sample] = []
        for line in data.split(separator: 0x0a) {
            guard let s = try? dec.decode(Sample.self, from: line) else { continue }
            if s.t >= cutoff { out.append(s) }
        }
        return out
    }

    /// Zkrátí log na posledních `hours` hodin. Volá se při startu.
    static func trim(hours: Double = 48) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? Int, size > 256 * 1024 else { return }
        let keep = recent(minutes: hours * 60)
        guard !keep.isEmpty else { return }
        let enc = JSONEncoder()
        var data = Data()
        for s in keep {
            guard let l = try? enc.encode(s) else { continue }
            data.append(l); data.append(0x0a)
        }
        try? data.write(to: logURL, options: .atomic)
    }
}
