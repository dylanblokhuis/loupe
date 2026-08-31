import SwiftUI

/// One pod/container being streamed into a console.
struct LogSource {
    var label: String
    var color: Color
    var lineCount = 0
    var error: String?

    static let palette: [Color] = [
        .cyan, .orange, .green, .pink, .purple, .yellow, .mint, .indigo, .teal, .brown,
    ]

    func padded(to width: Int) -> String {
        let trimmed = label.count > width ? String(label.suffix(width)) : label
        return trimmed.padding(toLength: max(width, trimmed.count), withPad: " ", startingAt: 0)
    }
}

struct LogLine: Identifiable {
    var index: Int
    let source: Int
    let stamp: String
    let text: String
    var id: Int { index }

    /// Splits the kubelet's RFC3339Nano prefix off a line.
    static func split(_ raw: String) -> (stamp: String, text: String) {
        guard let space = raw.firstIndex(of: " ") else { return ("", raw) }
        let candidate = String(raw[raw.startIndex..<space])
        guard candidate.count >= 20, candidate.hasSuffix("Z"), candidate.first?.isNumber == true else {
            return ("", raw)
        }
        return (candidate, String(raw[raw.index(after: space)...]))
    }

    /// Nanoseconds are more precision than anyone reads; milliseconds are not.
    static func displayStamp(_ stamp: String) -> String {
        guard let dot = stamp.firstIndex(of: ".") else { return stamp }
        let fraction = stamp[stamp.index(after: dot)...].prefix(3)
        return stamp[stamp.startIndex..<dot] + "." + fraction + "Z"
    }

    /// Tints obvious severities so errors stand out while scrolling.
    var tint: Color {
        let lowered = text.lowercased()
        if lowered.contains("error") || lowered.contains(" err ") || lowered.contains("fatal")
            || lowered.contains("panic") || lowered.contains("\"level\":\"error\"") {
            return .red
        }
        if lowered.contains("warn") { return .orange }
        if lowered.contains("debug") || lowered.contains("trace") { return .secondary }
        return .primary
    }
}
