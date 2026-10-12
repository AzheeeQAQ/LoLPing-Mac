import Foundation
import Security
import CryptoKit
import PingCore

/// A bundled private CA applies only to the configured relay host and port.
/// Certificate chain, hostname and validity still use Apple's trust evaluator.
enum RelayServerTrust {
    struct Profile: Decodable {
        let host: String
        let port: Int
        let certificateSHA256: String
    }
    private static let directory = Assets.root.appendingPathComponent("RelayTrust")
    static let profile: Profile? = {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("server.json")),
              let value = try? JSONDecoder().decode(Profile.self, from: data),
              !value.host.isEmpty, (1...65535).contains(value.port),
              value.certificateSHA256.count == 64,
              RelayProtocol.endpoint("wss://\(value.host):\(value.port)/ws")?.host == value.host else { return nil }
        return value
    }()
    static let anchor: SecCertificate? = {
        guard let profile, let data = try? Data(contentsOf: directory.appendingPathComponent("root-ca.cer")) else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == profile.certificateSHA256.lowercased() else { return nil }
        return SecCertificateCreateWithData(nil, data as CFData)
    }()
    static var endpoint: String? {
        guard let profile else { return nil }
        return "wss://\(profile.host):\(profile.port)/ws"
    }
    static var validationError: String? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        return profile != nil && anchor != nil ? nil : "服务器信任配置缺失或校验失败"
    }
    static func matches(host: String, port: Int) -> Bool {
        guard let profile else { return false }
        return host.lowercased() == profile.host.lowercased() && port == profile.port
    }
    /// nil leaves unrelated servers to normal system certificate validation.
    static func evaluate(_ trust: SecTrust, host: String, port: Int) -> Bool? {
        guard matches(host: host, port: port) else { return nil }
        guard let anchor else { return false }
        guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else { return false }
        SecTrustSetNetworkFetchAllowed(trust, false)
        var error: CFError?
        let accepted = SecTrustEvaluateWithError(trust, &error)
        if CommandLine.arguments.contains("--relay-check") {
            print("TLS trust evaluation: \(accepted) \(error.map { String(describing: $0) } ?? "")")
        }
        return accepted
    }
}
