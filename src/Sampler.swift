import Foundation
import IOKit.ps

/// Jeden odečet stavu stroje.
struct Sample: Codable {
    let t: Double        // unix epoch (s)
    /// Darwin thermal pressure level 0..4 (Nominal/Moderate/Heavy/Trapping/Sleeping).
    /// Hlavní signál. Volitelné kvůli záznamům z verze, která ho ještě neměla.
    let pressure: Int?
    /// ProcessInfo.ThermalState.rawValue – jen pro doložení rozdílu, verdikt na něm
    /// nestojí: slévá Moderate a Heavy do `fair`.
    let thermal: Int
    let speedPct: Double // efektivní rychlost jednoho výkonného jádra vůči kalibrovanému maximu
    let nanos: UInt64    // nejlepší čas referenční smyčky v tomto vzorku
    let load1: Double    // 1min load average
    let lowPower: Bool   // Low Power Mode
    let onAC: Bool       // na napájení ze sítě
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

    /// Měřená rychlost. Hranice jsou volnější než by se zdálo, protože i na
    /// nezatíženém stroji se minimum z dávek rozptyluje o ~10 %.
    static func speedLevel(_ pct: Double) -> Severity {
        if pct >= 85 { return .ok }
        if pct >= 70 { return .mild }
        return .throttling
    }

    /// Load, od kterého je pokles rychlosti vysvětlitelný soupeřením o jádra.
    static let busyLoad = 3.0

    static func overall(_ s: Sample) -> Severity {
        let a = pressureLevel(s.pressure).rawValue
        let b = speedLevel(s.speedPct).rawValue
        return Severity(rawValue: max(a, b)) ?? .ok
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
                pct = max(pct, samples[j].speedPct)
                thermal = max(thermal, samples[j].thermal)
                if let q = samples[j].pressure { pressure = max(pressure ?? 0, q) }
                j -= 1; used += 1
            }
            out.append(Sample(t: s.t, pressure: pressure, thermal: thermal, speedPct: pct,
                              nanos: s.nanos, load1: s.load1, lowPower: s.lowPower, onAC: s.onAC))
        }
        return out
    }

    /// Příčina – to je ta odpověď, kterou uživatel chce: teplo, nebo zátěž?
    static func cause(_ s: Sample) -> String {
        switch pressureLevel(s.pressure) {
        case .throttling:
            return "teplo – systém je na \(Pressure.name(s.pressure))"
        case .mild:
            return "teplo stoupá (\(Pressure.name(s.pressure)))"
        case .ok:
            break
        }
        if speedLevel(s.speedPct) != .ok {
            if s.lowPower { return "Low Power Mode, ne teplo" }
            if s.load1 >= busyLoad {
                return String(format: "zátěž CPU (load %.1f), ne teplo", s.load1)
            }
            return "pokles rychlosti bez tepelného tlaku"
        }
        return "bez omezení"
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
    /// Počet iterací referenční smyčky. ~390 µs na M5 P-jádru při plné frekvenci.
    static let iterations = 300_000
    /// Počet měřených dávek na jeden vzorek; bere se minimum (odolné proti preempci).
    static let bursts = 10
    /// Dávky zahozené na rozběh frekvence. Tohle není kosmetika: vlákno, které
    /// 5 s spí a pak 4 ms počítá, dostane na Apple Silicon nízkou frekvenci, protože
    /// DVFS se rozhoduje podle historie využití dané thread group. Naměřeno na M5
    /// (dvě série, interval 5 s): warmup 0,8 ms → 640/622 µs, 4 ms → 628/616 µs,
    /// 10 ms → 393/396 µs, 80 ms → 396/380 µs. Pod 10 ms měření neukazuje throttling,
    /// ale vlastní rozjezd. 30 dávek ≈ 12 ms.
    static let warmups = 30

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

    /// Jeden vzorek. `baseline` je kalibrované minimum (ns) = 100 %.
    static func sample(baseline: UInt64) -> Sample {
        let n = bestNanos()
        let pct = baseline > 0 ? (Double(baseline) / Double(n)) * 100.0 : 100.0
        return Sample(
            t: Date().timeIntervalSince1970,
            pressure: Pressure.level(),
            thermal: ProcessInfo.processInfo.thermalState.rawValue,
            speedPct: min(pct, 150),
            nanos: n,
            load1: loadAvg1(),
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            onAC: onACPower()
        )
    }
}
