import Foundation

/// Tepelný tlak podle Darwin notify klíče `com.apple.system.thermalpressurelevel`.
///
/// Tohle je ta správná metrika, a `ProcessInfo.thermalState` není: ve stejném okamžiku
/// vracel klíč `2` (Heavy) a `ProcessInfo` `fair` – veřejné API slévá Moderate a Heavy
/// do jedné hodnoty, takže nerozliší zahřátý stroj od skutečně omezeného. Ověřeno na
/// M5 / macOS 27.0 pěti odečty `notifyutil -g` proti `swift -e` ve stejné minutě.
///
/// Škála je z hlavičky SDK na tomhle stroji:
/// `/Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk/usr/include/libkern/OSThermalNotification.h`,
/// větev `#if TARGET_OS_OSX` – hodnoty 0..4 bez mezer. (Druhá větev s 10/20/30/40/50
/// je iOS, na macOS neplatí.) Čtení nevyžaduje root.
enum Pressure {
    static let nominal = 0, moderate = 1, heavy = 2, trapping = 3, sleeping = 4

    private static var token: Int32 = -1
    private static var registered = false

    /// Aktuální úroveň, nebo nil když se klíč nepodařilo zaregistrovat.
    static func level() -> Int? {
        if !registered {
            registered = notify_register_check("com.apple.system.thermalpressurelevel", &token) == 0
            if !registered { return nil }
        }
        var state: UInt64 = 0
        guard notify_get_state(token, &state) == 0 else { return nil }
        return Int(state)
    }

    static func name(_ p: Int?) -> String {
        switch p {
        case 0: return "Nominal"
        case 1: return "Moderate"
        case 2: return "Heavy"
        case 3: return "Trapping"
        case 4: return "Sleeping"
        default: return "?"
        }
    }

    /// Nejvíc vytížené procesy – aby alert řekl i co s tím, ne jen že je zle.
    /// Jedno spuštění `ps` stojí ~15 ms CPU, proto se volá jen když je horko.
    ///
    /// `cpu` je okamžité vytížení, `seconds` je **celkový** čas procesoru, který
    /// proces spálil od spuštění. To druhé je lepší odpověď na „co mi zbytečně
    /// hřeje stroj“: okamžitá špička může být legitimní build, ale aplikace, která
    /// za den spálila hodinu CPU na pozadí, je kandidát na zavření.
    static func processes() -> [(name: String, cpu: Double, seconds: Double)] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Aceo", "pcpu,time,comm", "-r"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        var out: [(String, Double, Double)] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst() {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 3, let cpu = Double(f[0]) else { continue }
            let name = f[2...].joined(separator: " ")
            if name.contains("ThermalWatch") { continue }
            out.append((name, cpu, parseTime(String(f[1]))))
        }
        return out
    }

    /// `ps` píše čas jako `[dd-]hh:mm.ss` nebo `mm:ss.hh`.
    static func parseTime(_ s: String) -> Double {
        var rest = s
        var days = 0.0
        if let dash = rest.firstIndex(of: "-") {
            days = Double(rest[rest.startIndex..<dash]) ?? 0
            rest = String(rest[rest.index(after: dash)...])
        }
        let parts = rest.split(separator: ":").map { Double($0) ?? 0 }
        let hms: Double
        switch parts.count {
        case 3: hms = parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: hms = parts[0] * 60 + parts[1]
        default: hms = parts.first ?? 0
        }
        return days * 86_400 + hms
    }

    static func topProcesses(_ n: Int = 3) -> [(name: String, cpu: Double)] {
        processes().filter { $0.cpu >= 5 }.prefix(n).map { ($0.name, $0.cpu) }
    }

    /// Text pro otázku „co mi teď hřeje stroj“.
    static func whoIsHeating() -> String {
        let all = processes()
        var out: [String] = []
        out.append("tepelný tlak: \(name(level()))")
        out.append("")
        let now = all.filter { $0.cpu >= 5 }.prefix(5)
        if now.isEmpty {
            out.append("teď nic výrazně nevytěžuje CPU")
        } else {
            out.append("vytěžuje CPU právě teď:")
            for p in now { out.append(String(format: "   %5.0f %%  %@", p.cpu, p.name)) }
        }
        out.append("")
        out.append("spálilo nejvíc času procesoru od svého spuštění:")
        for p in all.sorted(by: { $0.seconds > $1.seconds }).prefix(5) {
            let m = p.seconds / 60
            let t = m >= 60 ? String(format: "%.1f h", m / 60) : String(format: "%.0f min", m)
            out.append(String(format: "   %7@  %@", t as NSString, p.name))
        }
        return out.joined(separator: "\n")
    }
}
