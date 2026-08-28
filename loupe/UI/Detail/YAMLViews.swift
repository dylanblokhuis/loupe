import SwiftUI

/// Read-only YAML with lightweight highlighting, a search field and copy.
struct YAMLDocumentView: View {
    let text: String
    @State private var search = ""

    private var lines: [Line] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { Line(number: $0.offset + 1, text: String($0.element)) }
    }

    private var matches: [Line] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return lines }
        return lines.filter { $0.text.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
                TextField("Filter lines", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                if !search.isEmpty {
                    Text("\(matches.count) lines").font(.system(size: 10)).foregroundStyle(.secondary)
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Divider().frame(height: 12)
                Button {
                    ResourceActions.copyToPasteboard(text)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc").font(.system(size: 10))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.bar)

            ScrollView([.vertical, .horizontal]) {
                // A horizontal scroll view needs a definite content width;
                // monospaced text makes that a simple character count.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(matches) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(line.number)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.quaternary)
                                .frame(width: 38, alignment: .trailing)
                            Text(YAMLHighlighter.highlight(line.text))
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .padding(.vertical, 0.5)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
                .frame(width: contentWidth, alignment: .leading)
            }
        }
    }

    private var contentWidth: CGFloat {
        let longest = matches.map(\.text.count).max() ?? 0
        return 58 + CGFloat(longest) * 6.63
    }

    private struct Line: Identifiable {
        let number: Int
        let text: String
        var id: Int { number }
    }
}

enum YAMLHighlighter {
    /// Colours keys, scalars and comments. Deliberately line-local — a full
    /// parser is unnecessary for a display-only view.
    static func highlight(_ line: String) -> AttributedString {
        let indent = line.prefix(while: { $0 == " " })
        let trimmed = line.dropFirst(indent.count)

        if trimmed.hasPrefix("#") {
            var comment = AttributedString(line)
            comment.foregroundColor = .secondary
            return comment
        }

        var prefix = String(indent)
        var body = trimmed
        if trimmed.hasPrefix("- ") || trimmed == "-" {
            prefix += "- "
            body = trimmed.dropFirst(min(2, trimmed.count))
        }

        guard let separator = keySeparator(in: body) else {
            var plain = AttributedString(prefix)
            var value = AttributedString(String(body))
            value.foregroundColor = color(for: body.trimmingCharacters(in: .whitespaces))
            plain.append(value)
            return plain
        }

        var result = AttributedString(prefix)
        var key = AttributedString(String(body[body.startIndex..<separator]))
        key.foregroundColor = .init(red: 0.35, green: 0.6, blue: 0.95)
        result.append(key)
        result.append(AttributedString(":"))

        let rest = body[body.index(after: separator)...]
        let spacing = rest.prefix(while: { $0 == " " })
        result.append(AttributedString(String(spacing)))

        let scalar = rest.dropFirst(spacing.count)
        if !scalar.isEmpty {
            var value = AttributedString(String(scalar))
            value.foregroundColor = color(for: scalar.trimmingCharacters(in: .whitespaces))
            result.append(value)
        }
        return result
    }

    private static func color(for value: String) -> Color {
        if value.isEmpty { return .primary }
        if value.hasPrefix("\"") || value.hasPrefix("'") { return .init(red: 0.85, green: 0.5, blue: 0.35) }
        if ["true", "false", "null", "~"].contains(value) { return .purple }
        if Double(value) != nil { return .init(red: 0.4, green: 0.72, blue: 0.5) }
        if value == "|" || value == "|-" || value == ">" || value == ">-" { return .secondary }
        return .init(red: 0.85, green: 0.5, blue: 0.35)
    }

    private static func keySeparator(in text: Substring) -> Substring.Index? {
        var quote: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == ":" {
                let next = text.index(after: index)
                if next == text.endIndex || text[next] == " " { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

/// Edits an object's YAML and applies it with a full replace, the same way
/// `kubectl edit` does.
struct YAMLEditorSheet: View {
    let object: KubeObject
    var apply: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var parseError: String?

    init(object: KubeObject, apply: @escaping (String) -> Void) {
        self.object = object
        self.apply = apply
        self._text = State(wrappedValue: object.presentableYAML)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Edit \(object.kind)").font(.headline)
                    Text(object.qualifiedName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Revert") { text = object.presentableYAML }
                    .disabled(text == object.presentableYAML)
            }
            .padding(14)

            Divider()

            TextEditor(text: $text)
                .font(.system(size: 11.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)

            if let parseError {
                Divider()
                Label(parseError, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }

            Divider()
            HStack {
                Text("Changes are applied with a full replace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply") {
                    do {
                        let parsed = try YAMLParser.parse(text)
                        guard parsed.objectValue != nil else {
                            parseError = "The document is not a Kubernetes object."
                            return
                        }
                        apply(text)
                        dismiss()
                    } catch {
                        parseError = "\(error)"
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text == object.presentableYAML)
            }
            .padding(14)
        }
        .frame(width: 760, height: 620)
    }
}
