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
    /// Spouští `ps` jen při alertu, ne při každém vzorku.
    static func topProcesses(_ n: Int = 3) -> [(name: String, cpu: Double)] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Aceo", "pcpu,comm", "-r"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var out: [(String, Double)] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let sp = t.firstIndex(of: " "), let cpu = Double(t[t.startIndex..<sp]) else { continue }
            let name = t[t.index(after: sp)...].trimmingCharacters(in: .whitespaces)
            if name.contains("ThermalWatch") { continue }
            if cpu < 5 { break }
            out.append((name, cpu))
            if out.count == n { break }
        }
        return out
    }
}
