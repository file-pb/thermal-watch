import Foundation

/// Nastavení v ~/Library/Application Support/ThermalWatch/config.json.
/// Bez konfigurace funguje lokální alert; vzdálený kanál je čistě volitelný –
/// dokud je `ntfyTopic` prázdné, neodchází ze stroje nic.
struct Config: Codable {
    var ntfyTopic: String = ""
    var ntfyServer: String = "https://ntfy.sh"
    var panel: Bool = true
    var sound: Bool = true
    var cooldownSeconds: Double = 600
    var alertOnModerate: Bool = false
    /// Mini graf trendu vedle tečky v liště.
    var menuBarChart: Bool = true

    static var url: URL { Store.dir.appendingPathComponent("config.json") }

    static func load() -> Config {
        guard let d = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(Config.self, from: d) else {
            let c = Config()
            c.save()
            return c
        }
        return c
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Config.url, options: .atomic)
    }

    var remoteEnabled: Bool { !ntfyTopic.isEmpty }
}
