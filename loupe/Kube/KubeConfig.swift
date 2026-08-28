import Foundation

// MARK: - Model

struct KubeCluster: Identifiable, Sendable, Hashable {
    var name: String
    var server: String
    var certificateAuthorityData: Data?
    var certificateAuthorityPath: String?
    var insecureSkipTLSVerify: Bool
    var tlsServerName: String?
    var proxyURL: String?

    var id: String { name }
}

struct KubeUser: Identifiable, Sendable, Hashable {
    var name: String
    var token: String?
    var tokenFile: String?
    var username: String?
    var password: String?
    var clientCertificateData: Data?
    var clientCertificatePath: String?
    var clientKeyData: Data?
    var clientKeyPath: String?
    var impersonateUser: String?
    var impersonateGroups: [String]
    var exec: KubeExecConfig?
    var authProviderName: String?
    var authProviderConfig: [String: String]

    var id: String { name }
}

struct KubeExecConfig: Sendable, Hashable {
    var apiVersion: String
    var command: String
    var args: [String]
    var env: [String: String]
    var installHint: String?
    var provideClusterInfo: Bool
    var interactiveMode: String?
}

struct KubeContext: Identifiable, Sendable, Hashable {
    var name: String
    var cluster: String
    var user: String
    var namespace: String?

    var id: String { name }
}

/// A parsed (and possibly merged) set of kubeconfig files.
struct KubeConfig: Sendable {
    var clusters: [KubeCluster] = []
    var users: [KubeUser] = []
    var contexts: [KubeContext] = []
    var currentContext: String?
    /// Which file each context came from, so the UI can group them.
    var contextSources: [String: URL] = [:]
    var sourceFiles: [URL] = []

    func cluster(named name: String) -> KubeCluster? { clusters.first { $0.name == name } }
    func user(named name: String) -> KubeUser? { users.first { $0.name == name } }
    func context(named name: String) -> KubeContext? { contexts.first { $0.name == name } }

    /// Everything needed to talk to one context, resolved against its files.
    func resolve(context name: String) -> KubeTarget? {
        guard let context = context(named: name), let cluster = cluster(named: context.cluster) else { return nil }
        return KubeTarget(
            contextName: name,
            cluster: cluster,
            user: user(named: context.user) ?? KubeUser(
                name: context.user, token: nil, tokenFile: nil, username: nil, password: nil,
                clientCertificateData: nil, clientCertificatePath: nil, clientKeyData: nil,
                clientKeyPath: nil, impersonateUser: nil, impersonateGroups: [], exec: nil,
                authProviderName: nil, authProviderConfig: [:]
            ),
            namespace: context.namespace,
            sourceFile: contextSources[name]
        )
    }
}

struct KubeTarget: Sendable, Hashable {
    var contextName: String
    var cluster: KubeCluster
    var user: KubeUser
    /// The namespace the context declares, if it declares one at all. A context
    /// that explicitly says `default` is not the same as one that says nothing.
    var namespace: String?
    var sourceFile: URL?

    var defaultNamespace: String { namespace ?? "default" }
}

// MARK: - Loading

enum KubeConfigError: Error, LocalizedError {
    case noConfigFound([String])
    case unreadable(URL, Error)

    var errorDescription: String? {
        switch self {
        case .noConfigFound(let paths):
            return "No kubeconfig found. Looked in: \(paths.joined(separator: ", "))"
        case .unreadable(let url, let error):
            return "Could not read \(url.path): \(error.localizedDescription)"
        }
    }
}

enum KubeConfigLoader {
    /// The files kubectl would consult, honouring `KUBECONFIG`.
    static func defaultPaths() -> [URL] {
        if let env = ProcessInfo.processInfo.environment["KUBECONFIG"], !env.isEmpty {
            return env.split(separator: ":").map {
                URL(fileURLWithPath: NSString(string: String($0)).expandingTildeInPath)
            }
        }
        return [FileManager.default.homeDirectoryForCurrentUser.appending(path: ".kube/config")]
    }

    /// Loads and merges the given files. As in kubectl, the first definition of
    /// a name wins and the first file's `current-context` is used.
    static func load(paths: [URL]) throws -> KubeConfig {
        var merged = KubeConfig()
        var found = false

        for url in paths {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let text: String
            do {
                text = try String(contentsOf: url, encoding: .utf8)
            } catch {
                throw KubeConfigError.unreadable(url, error)
            }
            let root: JSONValue
            do {
                root = try YAMLParser.parse(text)
            } catch {
                throw KubeConfigError.unreadable(url, error)
            }
            found = true
            merged.sourceFiles.append(url)
            let base = url.deletingLastPathComponent()

            for entry in root.array(at: "clusters") {
                guard let name = entry.string(at: "name"),
                      !merged.clusters.contains(where: { $0.name == name }) else { continue }
                let spec = entry["cluster"] ?? .null
                merged.clusters.append(KubeCluster(
                    name: name,
                    server: spec.string(at: "server") ?? "",
                    certificateAuthorityData: decodeBase64(spec.string(at: "certificate-authority-data")),
                    certificateAuthorityPath: resolvePath(spec.string(at: "certificate-authority"), base: base),
                    insecureSkipTLSVerify: spec.bool(at: "insecure-skip-tls-verify") ?? false,
                    tlsServerName: spec.string(at: "tls-server-name"),
                    proxyURL: spec.string(at: "proxy-url")
                ))
            }

            for entry in root.array(at: "users") {
                guard let name = entry.string(at: "name"),
                      !merged.users.contains(where: { $0.name == name }) else { continue }
                merged.users.append(parseUser(named: name, spec: entry["user"] ?? .null, base: base))
            }

            for entry in root.array(at: "contexts") {
                guard let name = entry.string(at: "name"),
                      !merged.contexts.contains(where: { $0.name == name }) else { continue }
                let spec = entry["context"] ?? .null
                merged.contexts.append(KubeContext(
                    name: name,
                    cluster: spec.string(at: "cluster") ?? "",
                    user: spec.string(at: "user") ?? "",
                    namespace: spec.string(at: "namespace")
                ))
                merged.contextSources[name] = url
            }

            if merged.currentContext == nil, let current = root.string(at: "current-context"), !current.isEmpty {
                merged.currentContext = current
            }
        }

        guard found else { throw KubeConfigError.noConfigFound(paths.map(\.path)) }
        return merged
    }

    private static func parseUser(named name: String, spec: JSONValue, base: URL) -> KubeUser {
        var exec: KubeExecConfig?
        if let execSpec = spec["exec"], let command = execSpec.string(at: "command") {
            var env: [String: String] = [:]
            for item in execSpec.array(at: "env") {
                if let key = item.string(at: "name"), let value = item.string(at: "value") { env[key] = value }
            }
            exec = KubeExecConfig(
                apiVersion: execSpec.string(at: "apiVersion") ?? "client.authentication.k8s.io/v1beta1",
                command: command,
                args: execSpec.array(at: "args").compactMap(\.stringValue),
                env: env,
                installHint: execSpec.string(at: "installHint"),
                provideClusterInfo: execSpec.bool(at: "provideClusterInfo") ?? false,
                interactiveMode: execSpec.string(at: "interactiveMode")
            )
        }

        var providerConfig: [String: String] = [:]
        if let config = spec.object(at: "auth-provider.config") {
            for (key, value) in config { providerConfig[key] = value.displayString }
        }

        return KubeUser(
            name: name,
            token: spec.string(at: "token"),
            tokenFile: resolvePath(spec.string(at: "tokenFile"), base: base),
            username: spec.string(at: "username"),
            password: spec.string(at: "password"),
            clientCertificateData: decodeBase64(spec.string(at: "client-certificate-data")),
            clientCertificatePath: resolvePath(spec.string(at: "client-certificate"), base: base),
            clientKeyData: decodeBase64(spec.string(at: "client-key-data")),
            clientKeyPath: resolvePath(spec.string(at: "client-key"), base: base),
            impersonateUser: spec.string(at: "as"),
            impersonateGroups: spec.array(at: "as-groups").compactMap(\.stringValue),
            exec: exec,
            authProviderName: spec.string(at: "auth-provider.name"),
            authProviderConfig: providerConfig
        )
    }

    private static func decodeBase64(_ string: String?) -> Data? {
        guard let string, !string.isEmpty else { return nil }
        return Data(base64Encoded: string, options: .ignoreUnknownCharacters)
    }

    /// kubeconfig paths may be relative to the file that declares them.
    private static func resolvePath(_ path: String?, base: URL) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        return base.appending(path: expanded).standardizedFileURL.path
    }
}
