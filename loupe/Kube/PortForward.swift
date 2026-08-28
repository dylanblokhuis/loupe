import Foundation
import Network
import Observation

/// A single `localhost:port` → `pod:port` tunnel.
///
/// Kubernetes exposes port-forwarding over the same multiplexed WebSocket
/// protocol as exec: each forwarded port gets a data channel (`2i`) and an
/// error channel (`2i+1`), and the server announces the port number as the
/// first two bytes on each. One WebSocket is opened per inbound TCP
/// connection, which is what kubectl does too.
@MainActor
@Observable
final class PortForwardSession: Identifiable, Hashable {
    enum State: Equatable {
        case starting
        case active
        case failed(String)
        case stopped
    }

    let id = UUID()
    let contextName: String
    let namespace: String
    let podName: String
    let remotePort: Int
    let label: String

    private(set) var localPort: Int
    private(set) var state: State = .starting
    private(set) var activeConnections = 0
    private(set) var totalConnections = 0

    @ObservationIgnored private let client: KubeClient
    @ObservationIgnored private let path: String
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private let bridges = BridgeRegistry()

    init(
        client: KubeClient,
        contextName: String,
        namespace: String,
        podName: String,
        remotePort: Int,
        localPort: Int,
        label: String
    ) {
        self.client = client
        self.contextName = contextName
        self.namespace = namespace
        self.podName = podName
        self.remotePort = remotePort
        self.localPort = localPort
        self.label = label
        self.path = "/api/v1/namespaces/\(namespace)/pods/\(podName)/portforward"
    }

    var url: String { "http://127.0.0.1:\(localPort)" }

    nonisolated static func == (lhs: PortForwardSession, rhs: PortForwardSession) -> Bool {
        lhs === rhs
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // MARK: Lifecycle

    func start() {
        stop()
        state = .starting
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            // Bind loopback only: a forwarded cluster port must not be exposed
            // to the local network.
            parameters.requiredLocalEndpoint = .hostPort(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: UInt16(clamping: localPort)) ?? .any
            )
            let listener = try NWListener(using: parameters)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor in
                    guard let self else { return }
                    switch newState {
                    case .ready:
                        if let port = listener.port { self.localPort = Int(port.rawValue) }
                        self.state = .active
                    case .failed(let error):
                        self.state = .failed(error.localizedDescription)
                    default:
                        break
                    }
                }
            }
            // Connections are bridged entirely off the main actor; only the
            // counters and the failure message come back to it.
            let client = self.client
            let path = self.path
            let remotePort = self.remotePort
            let bridges = self.bridges
            listener.newConnectionHandler = { [weak self] connection in
                let bridge = Bridge(
                    connection: connection, client: client, path: path, remotePort: remotePort
                ) { finished, errorMessage in
                    bridges.remove(finished)
                    Task { @MainActor in self?.connectionEnded(errorMessage) }
                }
                bridges.insert(bridge)
                Task { @MainActor in self?.connectionStarted() }
                bridge.start()
            }
            listener.start(queue: .global(qos: .userInitiated))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        bridges.closeAll()
        activeConnections = 0
        if case .failed = state {} else { state = .stopped }
    }

    private func connectionStarted() {
        totalConnections += 1
        activeConnections += 1
    }

    private func connectionEnded(_ errorMessage: String?) {
        activeConnections = max(0, activeConnections - 1)
        if let errorMessage, state == .active {
            state = .failed(errorMessage)
        }
    }
}

/// Thread-safe holder for the live bridges of one session.
private final class BridgeRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var bridges: Set<ObjectIdentifier> = []
    private var strong: [ObjectIdentifier: Bridge] = [:]

    func insert(_ bridge: Bridge) {
        lock.lock()
        defer { lock.unlock() }
        let key = ObjectIdentifier(bridge)
        bridges.insert(key)
        strong[key] = bridge
    }

    func remove(_ bridge: Bridge) {
        lock.lock()
        defer { lock.unlock() }
        let key = ObjectIdentifier(bridge)
        bridges.remove(key)
        strong[key] = nil
    }

    func closeAll() {
        lock.lock()
        let all = Array(strong.values)
        strong.removeAll()
        bridges.removeAll()
        lock.unlock()
        for bridge in all { bridge.close() }
    }
}

/// Pipes one accepted TCP connection through one Kubernetes WebSocket.
/// Runs entirely off the main actor so forwarded traffic never hitches the UI.
private final class Bridge: @unchecked Sendable {
    private let connection: NWConnection
    private let client: KubeClient
    private let path: String
    private let remotePort: Int
    private let onFinish: (Bridge, String?) -> Void
    private let queue = DispatchQueue(label: "loupe.portforward.bridge")

    private let lock = NSLock()
    private var socket: URLSessionWebSocketTask?
    private var pump: Task<Void, Never>?
    private var sawPortHeader = false
    private var closed = false

    init(
        connection: NWConnection,
        client: KubeClient,
        path: String,
        remotePort: Int,
        onFinish: @escaping (Bridge, String?) -> Void
    ) {
        self.connection = connection
        self.client = client
        self.path = path
        self.remotePort = remotePort
        self.onFinish = onFinish
    }

    func start() {
        connection.start(queue: queue)
        let task = Task.detached { [self] in
            do {
                let socket = try await client.webSocket(
                    path: path,
                    query: [URLQueryItem(name: "ports", value: String(remotePort))],
                    protocols: ["v4.channel.k8s.io"]
                )
                lock.lock()
                let alreadyClosed = closed
                if !alreadyClosed { self.socket = socket }
                lock.unlock()
                guard !alreadyClosed else {
                    socket.cancel(with: .goingAway, reason: nil)
                    return
                }
                socket.resume()
                readFromLocal()
                try await readFromCluster(socket)
            } catch {
                if !Task.isCancelled { finish(describe(error)) }
            }
        }
        lock.lock()
        pump = task
        lock.unlock()
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func readFromLocal() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, complete, error in
            lock.lock()
            let socket = self.socket
            let isClosed = closed
            lock.unlock()
            guard !isClosed else { return }

            if let data, !data.isEmpty {
                var frame = Data([0])
                frame.append(data)
                socket?.send(.data(frame)) { _ in }
            }
            if complete || error != nil {
                finish(nil)
            } else {
                readFromLocal()
            }
        }
    }

    private func readFromCluster(_ socket: URLSessionWebSocketTask) async throws {
        while !Task.isCancelled {
            lock.lock()
            let isClosed = closed
            lock.unlock()
            if isClosed { return }

            let message = try await socket.receive()
            let frame: Data
            switch message {
            case .data(let data): frame = data
            case .string(let string): frame = Data(string.utf8)
            @unknown default: continue
            }
            guard let channel = frame.first else { continue }
            var payload = frame.dropFirst()

            switch channel {
            case 0:
                // The server opens the data channel by echoing the port number.
                lock.lock()
                let needsHeader = !sawPortHeader
                if needsHeader { sawPortHeader = true }
                lock.unlock()
                if needsHeader { payload = payload.dropFirst(min(2, payload.count)) }
                guard !payload.isEmpty else { continue }
                connection.send(content: Data(payload), completion: .contentProcessed { _ in })
            case 1:
                let text = String(decoding: payload.dropFirst(min(2, payload.count)), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    finish(text)
                    return
                }
            default:
                continue
            }
        }
    }

    private func finish(_ errorMessage: String?) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        let socket = self.socket
        let pump = self.pump
        self.socket = nil
        self.pump = nil
        lock.unlock()

        connection.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        pump?.cancel()
        onFinish(self, errorMessage)
    }

    func close() {
        finish(nil)
    }
}

/// Owns every tunnel for the session so they survive navigating away from the
/// pod that started them.
@MainActor
@Observable
final class PortForwardManager {
    private(set) var sessions: [PortForwardSession] = []

    func sessions(forContext context: String) -> [PortForwardSession] {
        sessions.filter { $0.contextName == context }
    }

    /// Picks a local port the OS is free to assign when none is requested.
    @discardableResult
    func start(
        client: KubeClient,
        contextName: String,
        namespace: String,
        podName: String,
        remotePort: Int,
        localPort: Int,
        label: String
    ) -> PortForwardSession {
        let session = PortForwardSession(
            client: client,
            contextName: contextName,
            namespace: namespace,
            podName: podName,
            remotePort: remotePort,
            localPort: localPort,
            label: label
        )
        sessions.append(session)
        session.start()
        return session
    }

    func stop(_ session: PortForwardSession) {
        session.stop()
        sessions.removeAll { $0 === session }
    }

    func stopAll(forContext context: String) {
        for session in sessions where session.contextName == context { session.stop() }
        sessions.removeAll { $0.contextName == context }
    }
}
