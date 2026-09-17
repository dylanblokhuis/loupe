import SwiftUI

enum TableTextSize {
    static let storageKey = "loupe.tableTextSize"
    static let defaultSize = 11.0
    static let range = 8.0...24.0

    static func clamped(_ size: Double) -> Double {
        min(max(size, range.lowerBound), range.upperBound)
    }
}

struct TableTextSizeCommands: Commands {
    @AppStorage(TableTextSize.storageKey) private var textSize = TableTextSize.defaultSize

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            Button("Increase Table Text Size") {
                textSize = TableTextSize.clamped(textSize + 1)
            }
            .keyboardShortcut("+", modifiers: .control)
            .disabled(textSize >= TableTextSize.range.upperBound)

            Button("Decrease Table Text Size") {
                textSize = TableTextSize.clamped(textSize - 1)
            }
            .keyboardShortcut("-", modifiers: .control)
            .disabled(textSize <= TableTextSize.range.lowerBound)

            Button("Reset Table Text Size") {
                textSize = TableTextSize.defaultSize
            }
            .keyboardShortcut("0", modifiers: .control)
        }
    }
}
