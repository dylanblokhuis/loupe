import Foundation
import Security

/// Everything TLS-related that a cluster connection needs.
struct KubeTLSConfiguration: @unchecked Sendable {
    var anchors: [SecCertificate] = []
    var identity: SecIdentity?
    var identityChain: [SecCertificate] = []
    var insecureSkipVerify: Bool = false
    var serverName: String?
    /// True when the kubeconfig named a certificate authority. If it did and
    /// `anchors` is still empty, the connection must fail rather than quietly
    /// fall back to the system trust store.
    var requiresCustomAnchors: Bool = false
    /// Non-fatal problems (e.g. a client certificate that could not be
    /// converted) surfaced to the UI rather than silently dropped.
    var warnings: [String] = []
}

enum KubeTLSError: Error, LocalizedError {
    case invalidCertificateData
    case opensslMissing
    case opensslFailed(String)
    case pkcs12ImportFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidCertificateData:
            return "The certificate data in the kubeconfig could not be decoded."
        case .opensslMissing:
            return "No openssl binary was found; client-certificate authentication is unavailable."
        case .opensslFailed(let message):
            return "openssl could not package the client certificate: \(message)"
        case .pkcs12ImportFailed(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "The client certificate could not be imported: \(detail)"
        }
    }
}

enum PEM {
    /// Extracts the DER payload of every block of the given type.
    static func blocks(ofType type: String, in text: String) -> [Data] {
        var results: [Data] = []
        let begin = "-----BEGIN \(type)-----"
        let end = "-----END \(type)-----"
        var remainder = Substring(text)
        while let start = remainder.range(of: begin), let finish = remainder.range(of: end) {
            guard start.upperBound <= finish.lowerBound else { break }
            let body = remainder[start.upperBound..<finish.lowerBound]
            if let data = Data(base64Encoded: String(body), options: .ignoreUnknownCharacters) {
                results.append(data)
            }
            remainder = remainder[finish.upperBound...]
        }
        return results
    }

    /// Reads certificates from either PEM text or a bare DER blob.
    static func certificates(from data: Data) -> [SecCertificate] {
        if let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN") {
            return blocks(ofType: "CERTIFICATE", in: text)
                .compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        }
        return [SecCertificateCreateWithData(nil, data as CFData)].compactMap { $0 }
    }
}

/// Carries the reason a TLS challenge was rejected from the session delegate
/// back to whichever request failed.
final class TrustFailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?

    var message: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

enum KubeIdentityFactory {
    /// Converts a PEM certificate/key pair into a `SecIdentity`.
    ///
    /// Security.framework can only build an identity from a PKCS#12 container
    /// or from key material already stored in a keychain. Rather than write to
    /// the user's keychain, the pair is packaged into a throwaway PKCS#12 with
    /// `openssl` (which ships with macOS) and imported straight into memory.
    static func makeIdentity(certificatePEM: Data, keyPEM: Data) throws -> (SecIdentity, [SecCertificate]) {
        guard let openssl = locateOpenSSL() else { throw KubeTLSError.opensslMissing }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "loupe-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let certificateURL = directory.appending(path: "client.crt")
        let keyURL = directory.appending(path: "client.key")
        let bundleURL = directory.appending(path: "client.p12")
        try certificatePEM.write(to: certificateURL, options: .completeFileProtection)
        try keyPEM.write(to: keyURL, options: .completeFileProtection)
        for url in [certificateURL, keyURL] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        let passphrase = UUID().uuidString
        let process = Process()
        process.executableURL = openssl
        process.arguments = [
            "pkcs12", "-export",
            "-inkey", keyURL.path,
            "-in", certificateURL.path,
            "-passout", "pass:\(passphrase)",
            "-out", bundleURL.path,
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        try process.run()
        let errorText = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw KubeTLSError.opensslFailed(errorText.isEmpty ? "exit \(process.terminationStatus)" : errorText)
        }

        let bundle = try Data(contentsOf: bundleURL)
        var items: CFArray?
        let status = SecPKCS12Import(
            bundle as CFData,
            [kSecImportExportPassphrase as String: passphrase] as CFDictionary,
            &items
        )
        guard status == errSecSuccess,
              let entries = items as? [[String: Any]],
              let first = entries.first,
              let identityRef = first[kSecImportItemIdentity as String]
        else {
            throw KubeTLSError.pkcs12ImportFailed(status)
        }
        let identity = identityRef as! SecIdentity
        let chain = (first[kSecImportItemCertChain as String] as? [SecCertificate]) ?? []
        return (identity, chain)
    }

    private static func locateOpenSSL() -> URL? {
        let candidates = ["/usr/bin/openssl", "/opt/homebrew/bin/openssl", "/usr/local/bin/openssl"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}

extension KubeTLSConfiguration {
    /// Builds the TLS configuration for a context, tolerating individual
    /// failures so a bad client certificate does not block a token-authed
    /// cluster from connecting.
    static func make(for target: KubeTarget) -> KubeTLSConfiguration {
        var config = KubeTLSConfiguration()
        config.insecureSkipVerify = target.cluster.insecureSkipTLSVerify
        config.serverName = target.cluster.tlsServerName

        if let data = target.cluster.certificateAuthorityData {
            config.requiresCustomAnchors = true
            config.anchors = PEM.certificates(from: data)
            if config.anchors.isEmpty {
                config.warnings.append("The cluster's certificate-authority-data could not be decoded.")
            }
        } else if let path = target.cluster.certificateAuthorityPath {
            config.requiresCustomAnchors = true
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                config.anchors = PEM.certificates(from: data)
                if config.anchors.isEmpty {
                    config.warnings.append("No certificates found in \(path)")
                }
            } else {
                config.warnings.append("Could not read certificate authority at \(path)")
            }
        }

        let certificatePEM = target.user.clientCertificateData
            ?? target.user.clientCertificatePath.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
        let keyPEM = target.user.clientKeyData
            ?? target.user.clientKeyPath.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }

        if let certificatePEM, let keyPEM {
            do {
                let (identity, chain) = try KubeIdentityFactory.makeIdentity(
                    certificatePEM: certificatePEM, keyPEM: keyPEM
                )
                config.identity = identity
                config.identityChain = chain
            } catch {
                config.warnings.append(error.localizedDescription)
            }
        }
        return config
    }
}

/// Performs custom server-trust evaluation and answers client-certificate
/// challenges. One instance is shared by every task of a cluster's session.
final class KubeSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let tls: KubeTLSConfiguration
    private let trustFailure: TrustFailureBox

    init(tls: KubeTLSConfiguration, trustFailure: TrustFailureBox) {
        self.tls = tls
        self.trustFailure = trustFailure
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge, completionHandler: completionHandler)
    }

    private func handle(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            if tls.insecureSkipVerify {
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }
            guard !tls.anchors.isEmpty else {
                if tls.requiresCustomAnchors {
                    // The kubeconfig pinned a CA we could not load. Trusting the
                    // system roots instead would silently weaken the connection.
                    trustFailure.message = "The cluster's certificate authority could not be loaded, "
                        + "so the server's certificate cannot be verified."
                    completionHandler(.cancelAuthenticationChallenge, nil)
                } else {
                    completionHandler(.performDefaultHandling, nil)
                }
                return
            }
            // The cluster CA is usually a private root, so it is installed as
            // the *only* trusted anchor for this connection.
            SecTrustSetAnchorCertificates(trust, tls.anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            if let serverName = tls.serverName {
                SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, serverName as CFString))
            }
            var error: CFError?
            if SecTrustEvaluateWithError(trust, &error) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                // URLSession reports a rejected challenge as a plain
                // cancellation, so the real reason is stashed for the client to
                // report instead of "cancelled".
                trustFailure.message = (error as Error?)?.localizedDescription
                    ?? "The server's certificate was rejected by the cluster's certificate authority."
                completionHandler(.cancelAuthenticationChallenge, nil)
            }

        case NSURLAuthenticationMethodClientCertificate:
            guard let identity = tls.identity else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            let credential = URLCredential(
                identity: identity,
                certificates: tls.identityChain.isEmpty ? nil : tls.identityChain,
                persistence: .forSession
            )
            completionHandler(.useCredential, credential)

        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
