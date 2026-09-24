import Darwin

enum Sysctl {
    static func int(_ name: String) -> Int {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return 0 }
        return size == 4 ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
    }

    static func string(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    static var bootTime: Double {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return 0 }
        return Double(tv.tv_sec)
    }
}

enum MachTime {
    static let nsPerTick: Double = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    static var seconds: Double { Double(mach_absolute_time()) * nsPerTick / 1e9 }
}

/// Reads a fixed-size C char tuple (e.g. `pbi_comm`, `vip_path`) as a String.
func cString<T>(_ tuple: inout T) -> String {
    withUnsafeBytes(of: &tuple) { raw in
        let chars = raw.bindMemory(to: CChar.self)
        let length = chars.firstIndex(of: 0) ?? chars.count
        return String(decoding: UnsafeRawBufferPointer(rebasing: raw[..<length]), as: UTF8.self)
    }
}
