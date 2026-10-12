import Foundation
import Security

enum RelayTrustChecks {
    static func ping(endpoint: URL) -> Int32 {
        guard let socket = PinnedRelaySocket(endpoint: endpoint) else { print("FAIL Invalid pinned endpoint"); return 1 }
        var done = false, success = false
        socket.onOpen = {
            socket.sendPing { error in
                success = error == nil; done = true
                print("\(success ? "PASS" : "FAIL") native TLS WebSocket ping/pong heartbeat")
            }
        }
        socket.onFailure = { error in print("FAIL heartbeat: \(error.localizedDescription)"); done = true }
        socket.start()
        let deadline = Date().addingTimeInterval(15)
        while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        socket.cancel()
        return success ? 0 : 1
    }
    static func run(chainPath: String, foreignPath: String) -> Int32 {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL") \(name)")
            if !condition { failures += 1 }
        }
        guard let profile = RelayServerTrust.profile, RelayServerTrust.anchor != nil,
              let pem = try? String(contentsOfFile: chainPath, encoding: .utf8),
              let foreign = try? Data(contentsOf: URL(fileURLWithPath: foreignPath)),
              let foreignCert = SecCertificateCreateWithData(nil, foreign as CFData) else {
            print("FAIL Missing trust fixtures or bundled relay profile"); return 1
        }
        let certificates = pem.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst().compactMap { piece -> SecCertificate? in
            guard let body = piece.components(separatedBy: "-----END CERTIFICATE-----").first,
                  let data = Data(base64Encoded: body.filter { !$0.isWhitespace }) else { return nil }
            return SecCertificateCreateWithData(nil, data as CFData)
        }
        func trust(_ certs: [SecCertificate]) -> SecTrust? {
            var value: SecTrust?
            guard SecTrustCreateWithCertificates(certs as CFArray, SecPolicyCreateSSL(true, profile.host as CFString), &value) == errSecSuccess else { return nil }
            return value
        }
        guard !certificates.isEmpty, let valid = trust(certificates), let expired = trust(certificates),
              let rogue = trust([foreignCert]), let unrelated = trust(certificates) else {
            print("FAIL Invalid certificate fixtures"); return 1
        }
        check(RelayServerTrust.evaluate(valid, host: profile.host, port: profile.port) == true, "configured server chain and IP are valid")
        check(RelayServerTrust.evaluate(rogue, host: profile.host, port: profile.port) == false, "unrelated certificate authority is rejected")
        SecTrustSetVerifyDate(expired, Date().addingTimeInterval(86400 * 365 * 20) as CFDate)
        check(RelayServerTrust.evaluate(expired, host: profile.host, port: profile.port) == false, "expired server certificates are rejected")
        check(RelayServerTrust.evaluate(unrelated, host: "other.example.com", port: profile.port) == nil, "private anchor is limited to configured host")
        check(RelayServerTrust.evaluate(unrelated, host: profile.host, port: profile.port+1) == nil, "private anchor is limited to configured port")
        SecTrustSetPolicies(valid, SecPolicyCreateSSL(true, "wrong.example.com" as CFString))
        check(!SecTrustEvaluateWithError(valid, nil), "hostname mismatch is rejected even with configured CA")
        return failures == 0 ? 0 : 1
    }
}
