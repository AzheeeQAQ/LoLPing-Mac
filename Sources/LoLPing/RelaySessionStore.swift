import Foundation
import Security
import LocalAuthentication
import PingCore

struct RelaySavedSession: Codable {
    let endpoint: String
    let room: String
    let token: String
    let memberID: String
    var isValid: Bool {
        RelayProtocol.endpoint(endpoint)?.absoluteString == endpoint && RelayProtocol.validRoomCode(room) &&
        token.count == 64 && token.allSatisfy { "0123456789abcdef".contains($0) } && UUID(uuidString: memberID) != nil
    }
}

/// Production credentials live in the local Keychain, never in source, public
/// gallery data or preferences. Isolated diagnostic suites use their own store.
final class RelaySessionStore {
    private let defaults: UserDefaults?
    private let useKeychain: Bool
    private let service: String
    init(defaults: UserDefaults?) {
        self.defaults = defaults; useKeychain = defaults === UserDefaults.standard
        service = (Bundle.main.bundleIdentifier ?? "local.allentu.LoLPing")+".relay-session"
    }
    private func account(_ endpoint: URL) -> String { EmoteLibrary.hash(Data(endpoint.absoluteString.utf8)) }
    private func query(_ endpoint: URL) -> [String: Any] {
        let context = LAContext(); context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account(endpoint), kSecUseAuthenticationContext as String: context]
    }
    func load(_ endpoint: URL) -> RelaySavedSession? {
        let data: Data?
        if useKeychain {
            var request = query(endpoint), result: CFTypeRef?
            request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
            guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess else { return nil }
            data = result as? Data
        } else { data = defaults?.data(forKey: "relaySession-"+account(endpoint)) }
        guard let data, let record = try? JSONDecoder().decode(RelaySavedSession.self, from: data),
              record.isValid, record.endpoint == endpoint.absoluteString else { return nil }
        return record
    }
    @discardableResult func save(_ value: RelaySavedSession) -> Bool {
        guard value.isValid, let endpoint = URL(string: value.endpoint), let data = try? JSONEncoder().encode(value) else { return false }
        if !useKeychain { defaults?.set(data, forKey: "relaySession-"+account(endpoint)); return true }
        let request = query(endpoint)
        let status = SecItemUpdate(request as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var attributes = request
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
    func remove(_ endpoint: URL) {
        if useKeychain { SecItemDelete(query(endpoint) as CFDictionary) }
        else { defaults?.removeObject(forKey: "relaySession-"+account(endpoint)) }
    }
}
