import Foundation

/// Parsing and formatting for Kubernetes resource quantities and timestamps.
enum Quantity {
    /// Parses a CPU quantity (`250m`, `1`, `1500u`, `2n`) into millicores.
    static func millicores(_ value: String?) -> Double {
        guard let value, !value.isEmpty else { return 0 }
        if let suffix = value.last, !suffix.isNumber {
            let magnitude = Double(value.dropLast()) ?? 0
            switch suffix {
            case "n": return magnitude / 1_000_000
            case "u": return magnitude / 1_000
            case "m": return magnitude
            case "k": return magnitude * 1_000_000
            default: return magnitude * 1_000
            }
        }
        return (Double(value) ?? 0) * 1_000
    }

    /// Parses a memory/storage quantity (`128Mi`, `1Gi`, `1e3`) into bytes.
    static func bytes(_ value: String?) -> Double {
        guard let value, !value.isEmpty else { return 0 }
        let multipliers: [(String, Double)] = [
            ("Ki", 1024), ("Mi", 1_048_576), ("Gi", 1_073_741_824),
            ("Ti", 1_099_511_627_776), ("Pi", 1_125_899_906_842_624), ("Ei", 1_152_921_504_606_846_976),
            ("k", 1_000), ("M", 1_000_000), ("G", 1_000_000_000),
            ("T", 1_000_000_000_000), ("P", 1_000_000_000_000_000), ("E", 1_000_000_000_000_000_000),
            ("m", 0.001),
        ]
        for (suffix, multiplier) in multipliers where value.hasSuffix(suffix) {
            return (Double(value.dropLast(suffix.count)) ?? 0) * multiplier
        }
        return Double(value) ?? 0
    }

    /// A node or metrics endpoint can report `inf`, `NaN` or an absurd
    /// exponent; `Int(_: Double)` traps on all of them, so every formatter
    /// clamps before converting.
    static func formatCPU(_ millicores: Double) -> String {
        guard millicores.isFinite else { return "—" }
        if millicores <= 0 { return "0" }
        if millicores < 1000 { return "\(Int(min(millicores, 1e15).rounded()))m" }
        return String(format: "%.2f", millicores / 1000)
    }

    static func formatBytes(_ bytes: Double) -> String {
        guard bytes.isFinite else { return "—" }
        guard bytes > 0 else { return "0" }
        let units = ["B", "Ki", "Mi", "Gi", "Ti", "Pi", "Ei"]
        var value = bytes
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        value = min(value, 1e15)
        return value < 10 && index > 0
            ? String(format: "%.1f%@", value, units[index])
            : "\(Int(value.rounded()))\(units[index])"
    }
}

enum Age {
    /// Renders a duration the way `kubectl` does: `3d4h`, `12m`, `45s`.
    static func short(since date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        return short(seconds: now.timeIntervalSince(date))
    }

    static func short(seconds rawSeconds: TimeInterval) -> String {
        let seconds = Int(max(0, rawSeconds))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return hours < 10 ? "\(hours)h\(minutes % 60)m" : "\(hours)h" }
        let days = hours / 24
        if days < 8 { return "\(days)d\(hours % 24)h" }
        if days < 365 { return "\(days)d" }
        return "\(days / 365)y\(days % 365)d"
    }

    static func absolute(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .standard)
    }
}
