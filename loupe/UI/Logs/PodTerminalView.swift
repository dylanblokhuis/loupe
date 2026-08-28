import SwiftUI
import SwiftTerm

/// A full terminal into a container over the Kubernetes exec WebSocket.
///
/// SwiftTerm provides the emulation (colors, cursor addressing, the alternate
/// screen), so full-screen programs like vim and htop work in place. The
/// session speaks the `v4.channel.k8s.io` framing: keystrokes go out as stdin
/// frames, stdout bytes are fed to the emulator, and view resizes are
/// forwarded so the remote PTY always matches what is on screen.
struct PodTerminalView: View {
    let connection: ClusterConnection
    let pod: KubeObject

    @State private var container = ""
    @State private var shell = "/bin/sh"
    @State private var controller = PodTerminalController()

    private var containers: [String] {
        pod.raw.array(at: "spec.containers").compactMap { $0.string(at: "name") }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if let errorMessage = controller.errorMessage {
                Banner(message: errorMessage, tint: .red) { controller.errorMessage = nil }
            }
            // The inset painted in the terminal's background color reads as
            // padding; SwiftTerm itself has no content-inset API.
            TerminalHost(terminalView: controller.terminalView)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
        }
        .onAppear {
            if container.isEmpty { container = containers.first ?? "" }
        }
        .onDisappear { controller.disconnect() }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Picker("", selection: $container) {
                ForEach(containers, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 170)
            .disabled(controller.state == .connected)

            Picker("", selection: $shell) {
                Text("/bin/sh").tag("/bin/sh")
                Text("/bin/bash").tag("/bin/bash")
                Text("/bin/ash").tag("/bin/ash")
                Text("/bin/zsh").tag("/bin/zsh")
            }
            .labelsHidden()
            .frame(maxWidth: 120)
            .disabled(controller.state == .connected)

            switch controller.state {
            case .connected:
                Button("Disconnect") { controller.disconnect() }
            case .connecting:
                ProgressView().controlSize(.small)
            default:
                Button("Connect") { connect() }
                    .disabled(container.isEmpty)
            }

            if case .closed(let reason) = controller.state, !reason.isEmpty {
                Text(reason)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func connect() {
        guard let client = connection.client, let namespace = pod.namespace else { return }
        controller.connect(
            client: client,
            path: "/api/v1/namespaces/\(namespace)/pods/\(pod.name)/exec",
            container: container,
            shell: shell
        )
    }
}

/// Owns the SwiftTerm view for one shell tab and bridges it to an
/// `ExecSession`. It lives in `@State` so the terminal buffer survives SwiftUI
/// re-rendering the tab's view tree.
@MainActor
@Observable
final class PodTerminalController: TerminalViewDelegate {
    enum SessionState: Equatable {
        case disconnected, connecting, connected, closed(String)
    }

    var state: SessionState = .disconnected
    var errorMessage: String?

    let terminalView: TerminalView
    @ObservationIgnored private var session: ExecSession?

    init() {
        terminalView = AdaptiveTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        terminalView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        terminalView.configureNativeColors()
        terminalView.terminalDelegate = self
    }

    func connect(client: KubeClient, path: String, container: String, shell: String) {
        disconnect()
        // RIS through the emulator itself, so a reconnect starts on a clean screen.
        terminalView.feed(text: "\u{1B}c")
        state = .connecting

        let session = ExecSession(
            client: client,
            path: path,
            container: container,
            command: [shell],
            onOutput: { [weak self] data in
                self?.terminalView.feed(byteArray: [UInt8](data)[...])
            },
            onState: { [weak self] newState in
                guard let self else { return }
                switch newState {
                case .open:
                    state = .connected
                    // The server learns the PTY size only through resize
                    // frames; report the geometry the view already has.
                    let terminal = terminalView.getTerminal()
                    self.session?.sendResize(cols: terminal.cols, rows: terminal.rows)
                    terminalView.window?.makeFirstResponder(terminalView)
                case .closed(let reason):
                    state = .closed(reason)
                    let label = reason.isEmpty ? "session ended" : reason
                    terminalView.feed(text: "\r\n\u{1B}[2m[\(label)]\u{1B}[0m\r\n")
                case .failed(let message):
                    state = .disconnected
                    errorMessage = message
                }
            }
        )
        self.session = session
        session.start()
    }

    func disconnect() {
        session?.close()
        session = nil
        state = .disconnected
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        session?.send(bytes: data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        session?.sendResize(cols: newCols, rows: newRows)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(decoding: content, as: UTF8.self), forType: .string)
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func bell(source: TerminalView) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}

/// SwiftTerm's stock scheme is xterm's gray-on-black. This keeps the terminal
/// on the system text colors instead, re-resolving them on light/dark
/// switches — SwiftTerm captures dynamic colors at assignment time.
private final class AdaptiveTerminalView: TerminalView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            configureNativeColors()
        }
    }
}

private struct TerminalHost: NSViewRepresentable {
    let terminalView: TerminalView

    func makeNSView(context: Context) -> TerminalView { terminalView }
    func updateNSView(_ nsView: TerminalView, context: Context) {}
}

/// Drives the `v4.channel.k8s.io` WebSocket sub-protocol: every frame is
/// prefixed with a channel byte (0 stdin, 1 stdout, 2 stderr, 3 error,
/// 4 terminal resize).
@MainActor
final class ExecSession {
    enum State {
        case open
        case closed(String)
        case failed(String)
    }

    private let client: KubeClient
    private let path: String
    private let container: String
    private let command: [String]
    private let onOutput: (Data) -> Void
    private let onState: (State) -> Void
    private var task: URLSessionWebSocketTask?
    private var pump: Task<Void, Never>?

    init(
        client: KubeClient,
        path: String,
        container: String,
        command: [String],
        onOutput: @escaping (Data) -> Void,
        onState: @escaping (State) -> Void
    ) {
        self.client = client
        self.path = path
        self.container = container
        self.command = command
        self.onOutput = onOutput
        self.onState = onState
    }

    func start() {
        var query = [
            URLQueryItem(name: "container", value: container),
            URLQueryItem(name: "stdin", value: "true"),
            URLQueryItem(name: "stdout", value: "true"),
            // The API server rejects stderr together with tty.
            URLQueryItem(name: "stderr", value: "false"),
            URLQueryItem(name: "tty", value: "true"),
        ]
        query.append(contentsOf: command.map { URLQueryItem(name: "command", value: $0) })

        pump = Task {
            do {
                let socket = try await client.webSocket(
                    path: path, query: query, protocols: ["v4.channel.k8s.io"]
                )
                self.task = socket
                socket.resume()
                onState(.open)
                try await receiveLoop(socket)
            } catch {
                if !Task.isCancelled { onState(.failed(ClusterConnection.describe(error))) }
            }
        }
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async throws {
        while !Task.isCancelled {
            let message = try await socket.receive()
            switch message {
            case .data(let data):
                handle(data)
            case .string(let string):
                handle(Data(string.utf8))
            @unknown default:
                break
            }
        }
    }

    private func handle(_ frame: Data) {
        guard let channel = frame.first else { return }
        let payload = frame.dropFirst()
        guard !payload.isEmpty else { return }
        switch channel {
        case 1, 2:
            onOutput(Data(payload))
        case 3:
            // Channel 3 carries a terminal Status object.
            if let status = try? JSONParser.parse(Data(payload)),
               status.string(at: "status") != "Success" {
                onState(.closed(status.string(at: "message") ?? "session ended"))
            } else {
                onState(.closed(""))
            }
        default:
            break
        }
    }

    func send(bytes: some Sequence<UInt8>) {
        guard let task else { return }
        var frame = Data([0])
        frame.append(contentsOf: bytes)
        task.send(.data(frame)) { _ in }
    }

    func sendResize(cols: Int, rows: Int) {
        guard let task else { return }
        var frame = Data([4])
        frame.append(contentsOf: Array("{\"Width\":\(cols),\"Height\":\(rows)}".utf8))
        task.send(.data(frame)) { _ in }
    }

    func close() {
        pump?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}
