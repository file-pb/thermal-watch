import Foundation
import IOKit

/// Teplota, paměť a síť – tři zdroje, které jdou číst bez roota.
///
/// Teplota jde přes **privátní** `IOHIDEventSystem` (čidla se hlásí jako HID služby
/// s `PrimaryUsagePage 0xff00`, `PrimaryUsage 5`). Dokumentované cesty ji nedávají:
/// `powermetrics` chce roota a `ioreg -c AppleSMC` teplotu v properties nevystavuje.
/// Protože je to privátní API, může ho příští macOS beze slova změnit – proto je
/// všechno volitelné (`Double?`) a nic na tom nestojí; verdikt drží tepelný tlak.
///
/// Pozor na přesnost: nedokumentovaná čidla nemusí odpovídat tomu, co ukazují
/// komerční nástroje. Spolehlivý je trend, ne absolutní číslo.
enum Sensors {

    // MARK: - teplota

    typealias HIDClient = CFTypeRef
    typealias HIDService = CFTypeRef
    typealias HIDEvent = CFTypeRef

    private static let temperatureEventType: Int64 = 15

    private static var client: HIDClient?
    private static var dieServices: [HIDService] = []
    private static var sensorsReady = false
    private static var cached: (value: Double?, at: Date)?

    /// Kolik čidel se čte a jak často. Jeden odečet je IPC na čidlo: změřeno
    /// **18 ms za všech 44 čidel**, proto se bere jen několik `tdie` a nejvýš
    /// jednou za 15 s. Při vzorku po 5 s by teplota sama stála 0,36 % jádra,
    /// takhle je to zhruba desetina.
    static let maxSensors = 6
    static let refresh: TimeInterval = 15

    /// Projde čidla jednou a nechá si jen `tdie` (teploty křemíku). Enumerace všech
    /// 44 čidel při každém vzorku by byla zbytečná práce.
    private static func prepare() {
        guard !sensorsReady else { return }
        sensorsReady = true
        guard let c = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return }
        let matching: [String: Any] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
        _ = IOHIDEventSystemClientSetMatching(c, matching as CFDictionary)
        guard let services = IOHIDEventSystemClientCopyServices(c) as? [HIDService] else { return }
        client = c
        dieServices = services.filter {
            guard let name = IOHIDServiceClientCopyProperty($0, "Product" as CFString) as? String
            else { return false }
            return name.contains("tdie")
        }
        if dieServices.isEmpty { dieServices = services }
        if dieServices.count > maxSensors { dieServices = Array(dieServices.prefix(maxSensors)) }
    }

    /// Nejteplejší místo křemíku ve °C. Mezi odečty vrací poslední hodnotu.
    static func temperature() -> Double? {
        if let c = cached, Date().timeIntervalSince(c.at) < refresh { return c.value }
        prepare()
        guard !dieServices.isEmpty else { cached = (nil, Date()); return nil }
        var best: Double?
        defer { cached = (best, Date()) }
        for s in dieServices {
            guard let ev = IOHIDServiceClientCopyEvent(s, temperatureEventType, 0, 0) else { continue }
            let v = IOHIDEventGetFloatValue(ev, Int32(temperatureEventType << 16))
            guard v > 0, v < 150 else { continue }
            best = max(best ?? 0, v)
        }
        return best
    }

    // MARK: - paměť

    /// Obsazená paměť v procentech, počítaná jako v Monitoru aktivity:
    /// aktivní + wired + komprimovaná.
    static func memoryUsedPct() -> Double? {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let page = Double(vm_kernel_page_size)
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return nil }
        let used = (Double(vm.active_count) + Double(vm.wire_count)
                    + Double(vm.compressor_page_count)) * page
        return min(100, 100 * used / total)
    }

    // MARK: - síť

    private static var prevNet: (inB: UInt64, outB: UInt64, at: Date)?

    private static func counters() -> (UInt64, UInt64)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var inB: UInt64 = 0, outB: UInt64 = 0
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            guard cur.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            guard !name.hasPrefix("lo"), let d = cur.pointee.ifa_data else { continue }
            let data = d.assumingMemoryBound(to: if_data.self).pointee
            inB += UInt64(data.ifi_ibytes)
            outB += UInt64(data.ifi_obytes)
        }
        return (inB, outB)
    }

    /// Propustnost od minulého volání v kB/s. První volání nemá s čím porovnat.
    static func network() -> (inKBs: Double, outKBs: Double)? {
        guard let now = counters() else { return nil }
        let at = Date()
        defer { prevNet = (now.0, now.1, at) }
        guard let p = prevNet else { return nil }
        let dt = at.timeIntervalSince(p.at)
        guard dt > 0.5 else { return nil }
        // &- kvůli přetečení čítače při přepnutí rozhraní
        return (Double(now.0 &- p.inB) / 1024 / dt, Double(now.1 &- p.outB) / 1024 / dt)
    }
}

// MARK: - privátní IOHID symboly

typealias IOHIDEventSystemClientRef = CFTypeRef
typealias IOHIDServiceClientRef = CFTypeRef
typealias IOHIDEventRef = CFTypeRef

@_silgen_name("IOHIDEventSystemClientCreate")
func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> IOHIDEventSystemClientRef?
@_silgen_name("IOHIDEventSystemClientSetMatching")
func IOHIDEventSystemClientSetMatching(_ c: IOHIDEventSystemClientRef?, _ m: CFDictionary?) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
func IOHIDEventSystemClientCopyServices(_ c: IOHIDEventSystemClientRef?) -> CFArray?
@_silgen_name("IOHIDServiceClientCopyProperty")
func IOHIDServiceClientCopyProperty(_ s: IOHIDServiceClientRef?, _ k: CFString) -> CFTypeRef?
@_silgen_name("IOHIDServiceClientCopyEvent")
func IOHIDServiceClientCopyEvent(_ s: IOHIDServiceClientRef?, _ type: Int64,
                                 _ options: Int32, _ instance: Int64) -> IOHIDEventRef?
@_silgen_name("IOHIDEventGetFloatValue")
func IOHIDEventGetFloatValue(_ e: IOHIDEventRef?, _ field: Int32) -> Double
