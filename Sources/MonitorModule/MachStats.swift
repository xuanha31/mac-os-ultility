import Foundation
import Darwin

/// Đọc số liệu thô từ Mach / BSD API. Tất cả internal — chỉ `SystemMonitor` dùng.

struct CPUTicks {
    var user: UInt64
    var system: UInt64
    var idle: UInt64
    var nice: UInt64

    var total: UInt64 { user + system + idle + nice }
    var busy: UInt64 { user + system + nice }
}

struct NetBytes {
    var rx: UInt64
    var tx: UInt64
}

enum MachStats {

    /// Tổng CPU ticks toàn hệ thống (HOST_CPU_LOAD_INFO).
    static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, reboundPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // cpu_ticks index: 0=USER, 1=SYSTEM, 2=IDLE, 3=NICE
        return CPUTicks(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
    }

    /// RAM: (đã dùng, tổng) tính bằng bytes.
    /// "Đã dùng" xấp xỉ Activity Monitor = (active + wired + compressed) * pageSize.
    static func memory() -> (used: UInt64, total: UInt64)? {
        var total: UInt64 = 0
        var sizeOfTotal = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &total, &sizeOfTotal, nil, 0) == 0 else { return nil }

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let pageSize = UInt64(vm_kernel_page_size)
        let active = UInt64(stats.active_count)
        let wired = UInt64(stats.wire_count)
        let compressed = UInt64(stats.compressor_page_count)
        let used = (active + wired + compressed) * pageSize
        return (used, total)
    }

    /// Tổng bytes nhận/gửi qua mọi interface vật lý (bỏ loopback).
    /// Lưu ý: counter là 32-bit nên có thể wrap — `SystemMonitor` xử lý wrap khi tính delta.
    static func networkBytes() -> NetBytes {
        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0 else { return NetBytes(rx: 0, tx: 0) }
        defer { freeifaddrs(ifaddrPtr) }

        var cursor = ifaddrPtr
        while let current = cursor {
            let flags = Int32(current.pointee.ifa_flags)
            if let addr = current.pointee.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_LINK),
               (flags & IFF_LOOPBACK) == 0,
               let dataPtr = current.pointee.ifa_data {
                let networkData = dataPtr.assumingMemoryBound(to: if_data.self)
                rx += UInt64(networkData.pointee.ifi_ibytes)
                tx += UInt64(networkData.pointee.ifi_obytes)
            }
            cursor = current.pointee.ifa_next
        }
        return NetBytes(rx: rx, tx: tx)
    }
}
