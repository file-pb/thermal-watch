import Foundation
import IOKit.ps

/// Proces, který v okamžiku zpomalení patřil mezi nejžravější.
struct TopProc: Codable {
    let n: String
    let c: Double
}

/// Jeden odečet stavu stroje.
struct Sample: Codable {
    let t: Double        // unix epoch (s)
    /// Darwin thermal pressure level 0..4 (Nominal/Moderate/Heavy/Trapping/Sleeping).
    /// Hlavní signál. Volitelné kvůli záznamům z verze, která ho ještě neměla.
    let pressure: Int?
    /// ProcessInfo.ThermalState.rawValue – jen pro doložení rozdílu, verdikt na něm
    /// nestojí: slévá Moderate a Heavy do `fair`.
    let thermal: Int
    /// Efektivní rychlost jednoho výkonného jádra vůči referenci. `nil` znamená,
    /// že se neměřilo – na nečinném stroji nemá co zpomalovat a měření by jen
    /// topilo (viz `Sampler.shouldMeasureSpeed`).
    let speedPct: Double?
    let nanos: UInt64?   // nejlepší čas referenční smyčky, když se měřilo
    let load1: Double    // 1min load average
    /// Vytížení všech jader od minulého vzorku, v procentech. Na rozdíl od `load1`
    /// (minutový průměr, reaguje pomalu) zachytí i krátký souboj o jádra, který
    /// sráží měřenou rychlost. Volitelné kvůli starším záznamům.
    let cpu: Double?
    /// Nejteplejší místo křemíku ve °C (privátní IOHID, viz `Sensors`).
    let tempC: Double?
    /// Obsazená paměť v procentech.
    let mem: Double?
    /// Propustnost sítě v kB/s od minulého vzorku.
    let netIn: Double?
    let netOut: Double?
    let lowPower: Bool   // Low Power Mode
    let onAC: Bool       // na napájení ze sítě
    /// Měřeno z agenta na pozadí (true) nebo z jednorázového CLI běhu (false).
    /// Dvě různé podmínky: CLI proces měří rychleji, protože jádro je po startu
    /// rozjeté. Míchat je dohromady znamená porovnávat nesrovnatelné.
    let gui: Bool?
    /// Tři nejžravější procesy – ukládají se jen u zpomalených vzorků, aby šlo
    /// zpětně říct, co stroj zdržovalo. Volitelné: u stavu OK chybí schválně.
    let top: [TopProc]?
}

/// Úroveň omezení: 0 = OK, 1 = mírné, 2 = throttling.
enum Severity: Int {
    case ok = 0, mild = 1, throttling = 2

    var label: String {
        switch self {
        case .ok: return "OK"
        case .mild: return "mírné omezení"
        case .throttling: return "throttling"
        }
    }
}

enum Verdict {
    /// Tepelný tlak z notify klíče. Heavy a výš = systém reálně omezuje výkon.
    static func pressureLevel(_ p: Int?) -> Severity {
        guard let p else { return .ok }
        if p >= Pressure.heavy { return .throttling }
        if p == Pressure.moderate { return .mild }
        return .ok
    }

    /// Pás v grafu: Moderate je vidět jako náznak, Heavy a výš jako omezení.
    static func pressureTick(_ p: Int?) -> Severity? {
        guard let p, p > 0 else { return nil }
        return p >= Pressure.heavy ? .throttling : .mild
    }

    /// Měřená rychlost. `nil` = neměřeno, tedy žádný důvod k poplachu.
    static func speedLevel(_ pct: Double?) -> Severity {
        guard let pct else { return .ok }
        if pct >= 85 { return .ok }
        if pct >= 70 { return .mild }
        return .throttling
    }

    /// Vytížení CPU, od kterého je pokles rychlosti vysvětlitelný soupeřením o jádra.
    static let busyCpu = 55.0

    /// Okamžité vytížení vzorku; u starších záznamů se dopočítá z `load1`.
    static func busy(_ s: Sample) -> Double {
        if let c = s.cpu { return c }
        return 100 * s.load1 / Double(ProcessInfo.processInfo.activeProcessorCount)
    }

    /// Tepelný tlak je fakt od systému, měřená rychlost je odhad citlivý na souboj
    /// o jádra. Proto rychlost sama o sobě nikdy nedá červenou: bez tepelného tlaku
    /// se zastropuje na „mírné“. Červená znamená, že systém opravdu omezuje výkon.
    static func overall(_ s: Sample) -> Severity {
        let p = pressureLevel(s.pressure)
        var v = speedLevel(s.speedPct)
        if v == .throttling, p == .ok { v = .mild }
        return Severity(rawValue: max(p.rawValue, v.rawValue)) ?? .ok
    }

    /// Jedno měření je šumové: i na nezatíženém stroji se minimum z dávek rozptyluje
    /// o desítky procent, protože o frekvenci P-klastru a o jádro soupeří ostatní procesy.
    /// Pro verdikt se proto bere nejlepší hodnota z okna 30 s – když ani ta není dobrá,
    /// omezení je skutečné, ne jen jeden nepovedený vzorek. Graf i tak kreslí tuhle
    /// vyhlazenou řadu, surové číslo zůstává v detailu.
    static let smoothWindow: Double = 30
    static let smoothMax = 6

    static func smoothSeries(_ samples: [Sample]) -> [Sample] {
        var out: [Sample] = []
        out.reserveCapacity(samples.count)
        for (i, s) in samples.enumerated() {
            var pct = s.speedPct
            var thermal = s.thermal
            // Tepelný tlak se nevyhlazuje směrem dolů: bere se nejhorší z okna,
            // protože Heavy je fakt od systému, ne odhad zatížený šumem.
            var pressure = s.pressure
            var j = i - 1
            var used = 0
            while j >= 0, used < smoothMax - 1, s.t - samples[j].t <= smoothWindow {
                if let q = samples[j].speedPct { pct = pct.map { max($0, q) } ?? q }
                thermal = max(thermal, samples[j].thermal)
                if let q = samples[j].pressure { pressure = max(pressure ?? 0, q) }
                j -= 1; used += 1
            }
            out.append(Sample(t: s.t, pressure: pressure, thermal: thermal, speedPct: pct,
                              nanos: s.nanos, load1: s.load1, cpu: s.cpu, tempC: s.tempC,
                              mem: s.mem, netIn: s.netIn, netOut: s.netOut,
                              lowPower: s.lowPower, onAC: s.onAC, gui: s.gui, top: s.top))
        }
        return out
    }

    /// Příčina – to je ta odpověď, kterou uživatel chce: teplo, nebo zátěž?
    enum CauseKind: String, Codable {
        case heat, load, lowPower, other, none
    }

    /// Co verdikt vytáhlo nahoru. Jeden zdroj pravdy pro text i pro statistiku.
    static func causeKind(_ s: Sample) -> CauseKind {
        let p = pressureLevel(s.pressure)
        let v = speedLevel(s.speedPct)
        if p.rawValue >= v.rawValue, p != .ok { return .heat }
        if v != .ok {
            if s.lowPower { return .lowPower }
            return busy(s) >= busyCpu ? .load : .other
        }
        return .none
    }

    static func cause(_ s: Sample) -> String {
        let name = Pressure.name(s.pressure)
        switch causeKind(s) {
        case .heat:
            return pressureLevel(s.pressure) == .throttling
                ? "teplo – systém je na \(name)" : "teplo stoupá (\(name))"
        case .load:
            return String(format: "zátěž CPU (%.0f %% jader), tlak %@", busy(s), name)
        case .lowPower:
            return "Low Power Mode, ne teplo"
        case .other:
            return "pokles rychlosti, tlak jen \(name)"
        case .none:
            return "bez omezení"
        }
    }

    static func thermalName(_ raw: Int) -> String {
        switch raw {
        case 0: return "nominal"
        case 1: return "fair"
        case 2: return "serious"
        case 3: return "critical"
        default: return "?"
        }
    }
}

/// Globální "černá díra" pro výsledek referenční smyčky.
/// Bez zápisu do globální proměnné optimalizátor celou smyčku odstraní (ověřeno:
/// s `-O` a jen lokálním výsledkem vracelo měření 0 ns) – zápis sem je
/// pozorovatelný vedlejší efekt, takže smyčka zůstane.
var benchSink: Double = 0
/// Seed se bere z časovače, takže je pro každé volání jiný. Se stejným seedem
/// optimalizátor devět identických volání čisté funkce sloučí do jednoho (CSE)
/// a zbylých osm naměří 0 ns – přesně to se stalo při prvním běhu.

/// Referenční zátěž pro měření efektivní rychlosti jádra.
@inline(never)
func referenceWork(_ n: Int, _ seed: Double) -> Double {
    var a = seed, b = 2.0 - seed
    for _ in 0..<n {
        a = a * 1.0000001 + 0.0000001
        b = b * 0.9999999 + 0.0000001
    }
    return a + b
}

struct Sampler {
    /// Počet iterací referenční smyčky. ~345 µs na M5 P-jádru při plné frekvenci.
    static let iterations = 300_000
    /// Počet měřených dávek na jeden vzorek; bere se minimum (odolné proti preempci).
    static let bursts = 10
    /// Dávky zahozené na rozběh frekvence. Tohle není kosmetika: vlákno, které
    /// 5 s spí a pak 4 ms počítá, dostane na Apple Silicon nízkou frekvenci, protože
    /// DVFS se rozhoduje podle historie využití dané thread group. Naměřeno na M5
    /// (dvě série, interval 5 s): warmup 0,8 ms → 640/622 µs, 4 ms → 628/616 µs,
    /// 10 ms → 393/396 µs. Na **nečinném** stroji je ale potřeba ještě mnohem víc:
    /// 12 ms → 691/561/614 µs, 24 ms → 533/545/544 µs, 48 ms → 410/359/411 µs,
    /// 100 ms → 344/343/343 µs. Takt se tedy plně rozjede až po ~100 ms souvislé
    /// práce. S kratším warmupem hlásil nečinný zdravý stroj „60 %“, což byla
    /// měřicí chyba, ne throttling. 250 dávek ≈ 100 ms.
    static let warmups = 250

    private static func burstNanos() -> UInt64 {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let r = referenceWork(iterations, 1.0 + Double(t0 % 1_000) * 1e-12)
        let t1 = DispatchTime.now().uptimeNanoseconds
        benchSink += r
        return t1 - t0
    }

    /// Dávky běží na vlastním vlákně s pevně nastavenou QoS. Důvod: `DispatchQueue.sync`
    /// vykoná práci na volajícím vlákně, a v menu-barové aplikaci (accessory, nikdy
    /// v popředí) má main thread nižší QoS → plánovač ji posadí na E-jádro. Naměřeno:
    /// 600–665 µs z GUI proti 434 µs z CLI na tomtéž stroji, tedy falešných 60 %.
    private static let benchQueue = DispatchQueue(label: "thermalwatch.bench", qos: .userInteractive)

    private static func measure(bursts: Int, warmups: Int) -> UInt64 {
        var best = UInt64.max
        let sem = DispatchSemaphore(value: 0)
        benchQueue.async {
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
            for _ in 0..<warmups { _ = burstNanos() }
            for _ in 0..<bursts { best = min(best, burstNanos()) }
            sem.signal()
        }
        sem.wait()
        return best
    }

    /// Nejlepší čas referenční smyčky v tomto vzorku.
    static func bestNanos() -> UInt64 { measure(bursts: bursts, warmups: warmups) }

    /// Delší měření pro první kalibraci.
    static func calibrate() -> UInt64 { measure(bursts: 40, warmups: 40) }

    /// Vytížení všech jader od minulého volání, z tiků jádra. Stojí mikrosekundy.
    private static var prevTicks: (busy: Double, total: Double)?

    static func cpuBusyPct() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return nil }
        let u = Double(info.cpu_ticks.0), sy = Double(info.cpu_ticks.1)
        let i = Double(info.cpu_ticks.2), n = Double(info.cpu_ticks.3)
        let now = (busy: u + sy + n, total: u + sy + n + i)
        defer { prevTicks = now }
        guard let p = prevTicks else { return nil }   // první vzorek nemá s čím porovnat
        let db = now.busy - p.busy, dt = now.total - p.total
        guard dt > 0 else { return nil }
        return 100 * db / dt
    }

    static func loadAvg1() -> Double {
        var l = [Double](repeating: 0, count: 3)
        guard getloadavg(&l, 3) > 0 else { return 0 }
        return l[0]
    }

    static func onACPower() -> Bool {
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as [CFTypeRef]
        if list.isEmpty { return true } // desktop bez baterie
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  let state = d[kIOPSPowerSourceStateKey] as? String else { continue }
            return state == kIOPSACPowerValue
        }
        return true
    }

    /// Jedno měření rychlosti stojí ~104 ms práce jednoho jádra (warmup 250 dávek
    /// + 10 měřených, viz `warmups`/`bursts`). Proto se nedělá při každém vzorku:
    /// jednou za minutu to vyjde na 0,17 % jednoho jádra, tedy 0,017 % stroje.
    /// Když je horko, zahušťuje se na 20 s (0,5 % jádra), protože tehdy je to číslo
    /// k něčemu. Tepelný tlak se čte pořád, ten je zadarmo – jedno `notify_get_state`.
    static let speedIntervalIdle: TimeInterval = 60
    static let speedIntervalHot: TimeInterval = 20
    private static var lastSpeedAt: Date?

    /// Nejkratší odstup mezi dvěma spuštěními `ps` (~15 ms CPU na běh).
    static let topInterval: TimeInterval = 30
    private static var lastTopAt: Date?
    /// Nastaví aplikace na pozadí; CLI ho nechává na false.
    static var isGUI = false

    /// Jeden vzorek. `reference` je čas odpovídající 100 % (viz `Store.reference()`).
    static func sample(baseline reference: UInt64, force: Bool = false) -> Sample {
        let pressure = Pressure.level()
        let load = loadAvg1()
        // Číst se musí vždycky, i když se rychlost neměří – jinak by příští rozdíl
        // tiků pokrýval několik vzorků a hlásil průměr, ne okamžik.
        let cpu = cpuBusyPct()
        let temp = Sensors.temperature()
        let mem = Sensors.memoryUsedPct()
        let net = Sensors.network()

        var n: UInt64?
        var pct: Double?
        let hot = Verdict.pressureLevel(pressure) != .ok || load >= 4
        let interval = hot ? speedIntervalHot : speedIntervalIdle
        let due = lastSpeedAt == nil || Date().timeIntervalSince(lastSpeedAt!) >= interval
        if force || due {
            lastSpeedAt = Date()
            let m = bestNanos()
            n = m
            pct = min(reference > 0 ? (Double(reference) / Double(m)) * 100.0 : 100.0, 150)
        }

        // Viníky zjišťuj jen když je horko – na otázku „co mi hřeje stroj“
        // odpovídá tepelný tlak, ne každý výkyv rychlosti.
        var top: [TopProc]?
        let hotEnough = Verdict.pressureLevel(pressure) != .ok
        if hotEnough, lastTopAt == nil || Date().timeIntervalSince(lastTopAt!) >= topInterval {
            lastTopAt = Date()
            let procs = Pressure.topProcesses(3)
            if !procs.isEmpty { top = procs.map { TopProc(n: $0.name, c: $0.cpu) } }
        }

        return Sample(
            t: Date().timeIntervalSince1970,
            pressure: pressure,
            thermal: ProcessInfo.processInfo.thermalState.rawValue,
            speedPct: pct,
            nanos: n,
            load1: load,
            cpu: cpu,
            tempC: temp,
            mem: mem,
            netIn: net?.inKBs,
            netOut: net?.outKBs,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            onAC: onACPower(),
            gui: isGUI,
            top: top
        )
    }
}
