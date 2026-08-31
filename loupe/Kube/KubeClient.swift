import Foundation

// MARK: - Requests

struct KubeRequest: Sendable {
    enum Method: String, Sendable {
        case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE"
    }

    var method: Method = .get
    var path: String
    var query: [URLQueryItem] = []
    var body: Data?
    var accept: String = "application/json"
    var contentType: String?
    var headers: [String: String] = [:]
    var timeout: TimeInterval = 60

    static func get(_ path: String, query: [URLQueryItem] = []) -> KubeRequest {
        KubeRequest(path: path, query: query)
    }
}

/// The `Accept` value that asks the API server to render a resource with the
/// same columns `kubectl get` prints, for any kind including custom resources.
enum KubeAccept {
    static let table = "application/json;as=Table;v=v1;g=meta.k8s.io,application/json"
    static let json = "application/json"
    static let yaml = "application/yaml"
}

// MARK: - Errors

struct KubeStatusError: Error, LocalizedError {
    var code: Int
    var message: String
    var reason: String?
    var details: JSONValue?

    var errorDescription: String? {
        if let reason, !reason.isEmpty, reason != message { return "\(message) (\(reason))" }
        return message
    }

    var isNotFound: Bool { code == 404 }
    var isForbidden: Bool { code == 403 }
    /// The watch cursor fell out of the API server's history window.
    var isExpired: Bool { code == 410 }
}

enum KubeClientError: Error, LocalizedError {
    case invalidServerURL(String)
    case nonHTTPResponse
    case tlsRejected(String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL(let server): return "The cluster server URL is invalid: \(server)"
        case .nonHTTPResponse: return "The server returned a response that was not HTTP."
        case .tlsRejected(let message): return message
        }
    }
}

// MARK: - Client

/// A thin, dynamic Kubernetes API client: it speaks paths and JSON rather than
/// generated types, which is what lets the app browse arbitrary resources.
final class KubeClient: @unchecked Sendable {
    let target: KubeTarget
    let baseURL: URL
    let tlsWarnings: [String]

    private let session: URLSession
    private let credentials: KubeCredentials
    private let trustFailure = TrustFailureBox()

    init(target: KubeTarget) throws {
        self.target = target
        guard let baseURL = URL(string: target.cluster.server), baseURL.host != nil else {
            throw KubeClientError.invalidServerURL(target.cluster.server)
        }
        self.baseURL = baseURL

        let tls = KubeTLSConfiguration.make(for: target)
        self.tlsWarnings = tls.warnings

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 86_400
        configuration.httpMaximumConnectionsPerHost = 16
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": KubeClient.userAgent]
        if let proxy = target.cluster.proxyURL, let url = URL(string: proxy), let host = url.host {
            let port = url.port ?? (url.scheme == "https" ? 443 : 80)
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: true,
                kCFNetworkProxiesHTTPProxy as String: host,
                kCFNetworkProxiesHTTPPort as String: port,
                "HTTPSEnable": true,
                "HTTPSProxy": host,
                "HTTPSPort": port,
            ]
        }

        self.session = URLSession(
            configuration: configuration,
            delegate: KubeSessionDelegate(tls: tls, trustFailure: trustFailure),
            delegateQueue: nil
        )
        self.credentials = KubeCredentials(user: target.user, clusterServer: target.cluster.server)
    }

    static let userAgent = "loupe/1.0 (macOS; +https://github.com/dylanblokhuis/loupe)"

    /// Releases the session's strong reference to its delegate.
    func invalidate() {
        session.invalidateAndCancel()
    }

    // MARK: Request construction

    func makeURL(path: String, query: [URLQueryItem]) throws -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard var components = URLComponents(
            url: baseURL.appending(path: trimmed), resolvingAgainstBaseURL: false
        ) else {
            throw KubeClientError.invalidServerURL(path)
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw KubeClientError.invalidServerURL(path) }
        return url
    }

    private func makeURLRequest(_ request: KubeRequest) async throws -> URLRequest {
        var urlRequest = URLRequest(url: try makeURL(path: request.path, query: request.query))
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeout
        urlRequest.setValue(request.accept, forHTTPHeaderField: "Accept")
        if let contentType = request.contentType {
            urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        for header in try await credentials.headers() {
            urlRequest.addValue(header.value, forHTTPHeaderField: header.name)
        }
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        return urlRequest
    }

    // MARK: Unary requests

    /// URLSession surfaces a rejected server-trust challenge as a plain
    /// cancellation, which is indistinguishable from the caller cancelling.
    /// When the task itself was not cancelled, the delegate's recorded reason
    /// is used instead.
    private func translate(_ error: Error) -> Error {
        guard let urlError = error as? URLError, urlError.code == .cancelled, !Task.isCancelled else {
            return error
        }
        guard let message = trustFailure.message else { return error }
        return KubeClientError.tlsRejected(message)
    }

    @discardableResult
    func data(_ request: KubeRequest) async throws -> Data {
        let urlRequest = try await makeURLRequest(request)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw translate(error)
        }
        guard let http = response as? HTTPURLResponse else { throw KubeClientError.nonHTTPResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw KubeClient.statusError(code: http.statusCode, body: data)
        }
        return data
    }

    func json(_ request: KubeRequest) async throws -> JSONValue {
        try JSONParser.parse(try await data(request))
    }

    func text(_ request: KubeRequest) async throws -> String {
        String(decoding: try await data(request), as: UTF8.self)
    }

    // MARK: Streaming

    /// Yields newline-delimited chunks — used for watches and pod logs.
    func lines(_ request: KubeRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var streaming = request
                    streaming.timeout = 86_400
                    let urlRequest = try await self.makeURLRequest(streaming)
                    let (bytes, response) = try await self.session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        throw KubeClientError.nonHTTPResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count > 64_000 { break }
                        }
                        throw KubeClient.statusError(code: http.statusCode, body: body)
                    }
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: self.translate(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: WebSocket (exec, attach, port-forward)

    func webSocket(path: String, query: [URLQueryItem], protocols: [String]) async throws -> URLSessionWebSocketTask {
        var url = try makeURL(path: path, query: query)
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.scheme = components.scheme == "http" ? "ws" : "wss"
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 86_400
        for header in try await credentials.headers() {
            request.addValue(header.value, forHTTPHeaderField: header.name)
        }
        request.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        return session.webSocketTask(with: request)
    }

    // MARK: Error decoding

    static func statusError(code: Int, body: Data) -> KubeStatusError {
        if let status = try? JSONParser.parse(body), status.string(at: "kind") == "Status" {
            return KubeStatusError(
                code: status.int(at: "code") ?? code,
                message: status.string(at: "message") ?? HTTPURLResponse.localizedString(forStatusCode: code),
                reason: status.string(at: "reason"),
                details: status["details"]
            )
        }
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return KubeStatusError(
            code: code,
            message: text.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: code) : text,
            reason: nil,
            details: nil
        )
    }
}

// MARK: - Convenience API

extension KubeClient {
    /// `/version`
    func serverVersion() async throws -> JSONValue {
        try await json(.get("/version"))
    }

    func get(path: String, query: [URLQueryItem] = []) async throws -> JSONValue {
        try await json(.get(path, query: query))
    }

    func delete(path: String, propagationPolicy: String = "Background", gracePeriod: Int? = nil) async throws {
        var options = JSONObject([
            ("apiVersion", .string("meta.k8s.io/v1")),
            ("kind", .string("DeleteOptions")),
            ("propagationPolicy", .string(propagationPolicy)),
        ])
        if let gracePeriod { options["gracePeriodSeconds"] = .int(gracePeriod) }
        var request = KubeRequest(method: .delete, path: path)
        request.body = JSONValue.object(options).serializedData()
        request.contentType = "application/json"
        try await data(request)
    }

    func patch(path: String, patch body: JSONValue, type: PatchType = .merge) async throws -> JSONValue {
        var request = KubeRequest(method: .patch, path: path)
        request.body = body.serializedData()
        request.contentType = type.contentType
        return try JSONParser.parse(try await data(request))
    }

    func replace(path: String, object: JSONValue) async throws -> JSONValue {
        var request = KubeRequest(method: .put, path: path)
        request.body = object.serializedData()
        request.contentType = "application/json"
        return try JSONParser.parse(try await data(request))
    }

    func create(path: String, object: JSONValue) async throws -> JSONValue {
        var request = KubeRequest(method: .post, path: path)
        request.body = object.serializedData()
        request.contentType = "application/json"
        return try JSONParser.parse(try await data(request))
    }

    enum PatchType {
        case merge, strategicMerge, json

        var contentType: String {
            switch self {
            case .merge: return "application/merge-patch+json"
            case .strategicMerge: return "application/strategic-merge-patch+json"
            case .json: return "application/json-patch+json"
            }
        }
    }

    /// Asks the API server which verbs the current user may perform, so the UI
    /// can hide actions that would fail.
    func canI(verb: String, group: String, resource: String, namespace: String?) async -> Bool {
        var spec = JSONObject([
            ("verb", .string(verb)),
            ("group", .string(group)),
            ("resource", .string(resource)),
        ])
        if let namespace { spec["namespace"] = .string(namespace) }
        let review = JSONValue.object(JSONObject([
            ("apiVersion", .string("authorization.k8s.io/v1")),
            ("kind", .string("SelfSubjectAccessReview")),
            ("spec", .object(JSONObject([("resourceAttributes", .object(spec))]))),
        ]))
        do {
            let result = try await create(
                path: "/apis/authorization.k8s.io/v1/selfsubjectaccessreviews", object: review
            )
            return result.bool(at: "status.allowed") ?? false
        } catch {
            // If the review itself is unavailable, assume the action is allowed
            // and let the real request surface any error.
            return true
        }
    }
}
