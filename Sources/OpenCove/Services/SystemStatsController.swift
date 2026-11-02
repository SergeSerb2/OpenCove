import Darwin
import Foundation
import IOKit

/// CPU, memory, network and disk readings for the System section. Sampling
/// runs only while a view holds a lease, every two seconds, and needs no permission.
@MainActor
final class SystemStatsController: ObservableObject {
    struct Snapshot: Equatable {
        var cpu: Double?            // 0...1, across all cores
        var memoryUsed: Double?     // bytes
        var memoryTotal: Double
        var downloadRate: Double?   // bytes per second
        var uploadRate: Double?
        var diskFree: Double?       // bytes available for important use
        var diskTotal: Double?
        var batteryHealth: Double?  // full-charge capacity relative to design capacity
        var batteryCycles: Int?
    }

    @Published private(set) var snapshot = Snapshot(memoryTotal: Double(ProcessInfo.processInfo.physicalMemory))
    private var leases = 0
    private var task: Task<Void, Never>?
    private var previousCPU: (busy: UInt64, total: UInt64)?
    private var previousNetwork: (received: UInt64, sent: UInt64, date: Date)?

    var isSampling: Bool { task != nil }

    func acquire() {
        leases += 1
        guard task == nil else { return }
        let battery = Self.readBatteryHealth()
        snapshot.batteryHealth = battery.health
        snapshot.batteryCycles = battery.cycles
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.sample()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    func release() {
        leases = max(0, leases - 1)
        guard leases == 0 else { return }
        task?.cancel()
        task = nil
        previousCPU = nil
        previousNetwork = nil
    }

    private func sample() {
        var next = snapshot
        next.cpu = readCPU()
        next.memoryUsed = Self.readMemoryUsed()
        (next.downloadRate, next.uploadRate) = readNetwork()
        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            next.diskFree = values.volumeAvailableCapacityForImportantUsage.map(Double.init)
            next.diskTotal = values.volumeTotalCapacity.map(Double.init)
        }
        if next != snapshot { snapshot = next }
    }

    private func readCPU() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        let user = UInt64(ticks.0), system = UInt64(ticks.1), idle = UInt64(ticks.2), nice = UInt64(ticks.3)
        let busy = user + system + nice, total = busy + idle
        defer { previousCPU = (busy, total) }
        guard let previous = previousCPU, total > previous.total, busy >= previous.busy else { return snapshot.cpu }
        return Double(busy - previous.busy) / Double(total - previous.total)
    }

    private static func readMemoryUsed() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = Double(vm_kernel_page_size)
        // App memory plus wired and compressed pages, as Activity Monitor reports "Memory Used".
        let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        return (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
    }

    private func readNetwork() -> (Double?, Double?) {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return (nil, nil) }
        defer { freeifaddrs(pointer) }
        var received: UInt64 = 0, sent: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let flags = Int32(entry.pointee.ifa_flags)
            if let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
               flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
               let data = entry.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                received += UInt64(data.pointee.ifi_ibytes)
                sent += UInt64(data.pointee.ifi_obytes)
            }
            cursor = entry.pointee.ifa_next
        }
        let now = Date()
        defer { previousNetwork = (received, sent, now) }
        guard let previous = previousNetwork, received >= previous.received, sent >= previous.sent else { return (nil, nil) }
        let seconds = now.timeIntervalSince(previous.date)
        guard seconds > 0.2 else { return (snapshot.downloadRate, snapshot.uploadRate) }
        return (Double(received - previous.received) / seconds, Double(sent - previous.sent) / seconds)
    }

    /// Reads the internal battery's cycle count and capacity once. Returns nils on Macs without one.
    private static func readBatteryHealth() -> (health: Double?, cycles: Int?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (nil, nil) }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any] else { return (nil, nil) }
        let nested = properties["BatteryData"] as? [String: Any] ?? [:]
        func number(_ key: String) -> Double? {
            ((properties[key] ?? nested[key]) as? NSNumber).map(\.doubleValue)
        }
        let cycles = number("CycleCount").map(Int.init)
        guard let design = number("DesignCapacity"), design > 0,
              let full = number("NominalChargeCapacity") ?? number("AppleRawMaxCapacity"), full > 0 else { return (nil, cycles) }
        return (min(1, full / design), cycles)
    }
}
