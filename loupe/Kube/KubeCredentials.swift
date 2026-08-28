import Foundation

enum KubeAuthError: Error, LocalizedError {
    case execFailed(command: String, status: Int32, message: String)
    case execProducedNoCredential(command: String)
    case tokenFileUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .execFailed(let command, let status, let message):
            return "Credential plugin '\(command)' exited with status \(status): \(message)"
        case .execProducedNoCredential(let command):
            return "Credential plugin '\(command)' did not return a token."
        case .tokenFileUnreadable(let path):
            return "Could not read token file at \(path)"
        }
    }
}

/// Resolves the request headers for a context, refreshing short-lived
/// credentials (exec plugins, projected token files) as they expire.
actor KubeCredentials {
    private let user: KubeUser
    private let clusterServer: String
    private var cachedToken: String?
    private var cachedExpiry: Date?

    init(user: KubeUser, clusterServer: String) {
        self.user = user
        self.clusterServer = clusterServer
    }

    /// Headers to attach to every request, excluding `Accept`/`Content-Type`.
    ///
    /// A list rather than a dictionary because `Impersonate-Group` is a
    /// genuinely repeated header — Kubernetes reads one group per occurrence,
    /// not a comma-joined value.
    func headers() async throws -> [(name: String, value: String)] {
        var headers: [(name: String, value: String)] = []

        if let token = try await resolveToken() {
            headers.append(("Authorization", "Bearer \(token)"))
        } else if let username = user.username, let password = user.password {
            let encoded = Data("\(username):\(password)".utf8).base64EncodedString()
            headers.append(("Authorization", "Basic \(encoded)"))
        }

        if let impersonate = user.impersonateUser {
            headers.append(("Impersonate-User", impersonate))
        }
        for group in user.impersonateGroups {
            headers.append(("Impersonate-Group", group))
        }
        return headers
    }

    private func resolveToken() async throws -> String? {
        if let token = user.token, !token.isEmpty { return token }

        if let path = user.tokenFile {
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                throw KubeAuthError.tokenFileUnreadable(path)
            }
            return contents.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let provider = user.authProviderName {
            switch provider {
            case "oidc":
                if let idToken = user.authProviderConfig["id-token"], !idToken.isEmpty { return idToken }
            default:
                if let accessToken = user.authProviderConfig["access-token"], !accessToken.isEmpty {
                    return accessToken
                }
            }
        }

        guard let exec = user.exec else { return nil }
        if let cachedToken, let cachedExpiry, cachedExpiry.timeIntervalSinceNow > 30 {
            return cachedToken
        }
        let credential = try await runExecPlugin(exec)
        cachedToken = credential.token
        cachedExpiry = credential.expiry ?? Date().addingTimeInterval(300)
        return credential.token
    }

    private struct ExecResult {
        var token: String
        var expiry: Date?
    }

    private func runExecPlugin(_ exec: KubeExecConfig) async throws -> ExecResult {
        let process = Process()
        process.executableURL = KubeCredentials.locate(exec.command)
        process.arguments = exec.args

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in exec.env { environment[key] = value }
        // The v1beta1/v1 contract is that KUBERNETES_EXEC_INFO is always set;
        // `provideClusterInfo` only controls whether it carries the cluster.
        var spec = JSONObject([("interactive", .bool(false))])
        if exec.provideClusterInfo {
            spec["cluster"] = .object(JSONObject([("server", .string(clusterServer))]))
        }
        let info = JSONValue.object(JSONObject([
            ("apiVersion", .string(exec.apiVersion)),
            ("kind", .string("ExecCredential")),
            ("spec", .object(spec)),
        ]))
        environment["KUBERNETES_EXEC_INFO"] = info.serialized()
        process.environment = environment

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        // Draining the pipes blocks; doing that on a cooperative-pool thread
        // would stall unrelated async work for as long as the plugin runs.
        let (stdout, stderrData) = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try process.run()
                    let out = output.fileHandleForReading.readDataToEndOfFile()
                    let err = errors.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: (out, err))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        let stderr = String(decoding: stderrData, as: UTF8.self)

        guard process.terminationStatus == 0 else {
            throw KubeAuthError.execFailed(
                command: exec.command,
                status: process.terminationStatus,
                message: stderr.isEmpty ? (exec.installHint ?? "no output") : stderr
            )
        }
        guard let root = try? JSONParser.parse(stdout),
              let token = root.string(at: "status.token"), !token.isEmpty
        else {
            throw KubeAuthError.execProducedNoCredential(command: exec.command)
        }
        let expiry = root.string(at: "status.expirationTimestamp").flatMap(KubeDate.parse)
        return ExecResult(token: token, expiry: expiry)
    }

    /// Credential plugins are usually referenced by bare name, so `PATH` (plus
    /// the usual Homebrew locations, which GUI apps do not inherit) is searched.
    /// Also used to find `kubectl` when handing a shell to an external terminal.
    static func locate(_ command: String) -> URL {
        if command.contains("/") { return URL(fileURLWithPath: command) }
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        directories.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
        for directory in directories {
            let candidate = directory + "/" + command
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return URL(fileURLWithPath: command)
    }
}

enum KubeDate {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return formatter.date(from: string) ?? fractionalFormatter.date(from: string)
    }

    static func format(_ date: Date) -> String {
        formatter.string(from: date)
    }
}
