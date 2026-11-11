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
    /// Bloky v liště, každý jako dvojice hodnota + grafík.
    var blockSpeed: Bool = true
    var blockHeat: Bool = true
    var blockCpu: Bool = true
    var blockMem: Bool = false
    var blockNet: Bool = false

    init() {}

    /// Vlastní dekódování: chybějící klíč bere výchozí hodnotu. Syntetizovaný
    /// `Codable` by na starším config.json selhal a `load()` by ho přepsal
    /// výchozím — tedy by zahodil třeba nastavené ntfy téma.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func b(_ k: CodingKeys, _ d: Bool) -> Bool { ((try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil) ?? d }
        ntfyTopic = ((try? c.decodeIfPresent(String.self, forKey: .ntfyTopic)) ?? nil) ?? ""
        ntfyServer = ((try? c.decodeIfPresent(String.self, forKey: .ntfyServer)) ?? nil) ?? "https://ntfy.sh"
        panel = b(.panel, true)
        sound = b(.sound, true)
        cooldownSeconds = ((try? c.decodeIfPresent(Double.self, forKey: .cooldownSeconds)) ?? nil) ?? 600
        alertOnModerate = b(.alertOnModerate, false)
        blockSpeed = b(.blockSpeed, true)
        blockHeat = b(.blockHeat, true)
        blockCpu = b(.blockCpu, true)
        blockMem = b(.blockMem, false)
        blockNet = b(.blockNet, false)
    }

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
