import Foundation
import Security

/// Adresse du serveur + clé de l'application (clé stockée dans le trousseau iOS).
@MainActor
final class AppConfig: ObservableObject {
    @Published private(set) var server: String
    @Published private(set) var key: String
    @Published var techName: String

    private static let serverKey = "server"
    private static let techKey = "techName"
    private static let keychainAccount = "app-key"

    init() {
        server = UserDefaults.standard.string(forKey: Self.serverKey) ?? ""
        techName = UserDefaults.standard.string(forKey: Self.techKey) ?? ""
        key = Keychain.read(Self.keychainAccount) ?? ""
    }

    var isConfigured: Bool { client != nil }

    var client: APIClient? {
        guard !key.isEmpty, let url = Self.normalized(server) else { return nil }
        return APIClient(base: url, key: key)
    }

    static func normalized(_ s: String) -> URL? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if !t.lowercased().hasPrefix("http") { t = "https://" + t }
        if !t.hasSuffix("/") { t += "/" }
        guard let u = URL(string: t), u.host != nil else { return nil }
        return u
    }

    /// Vérifie la connexion puis enregistre.
    func save(server: String, key: String) async throws {
        guard let url = Self.normalized(server) else { throw APIError.notConfigured }
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let ping = try await APIClient(base: url, key: k).ping()
        self.server = url.absoluteString
        self.key = k
        self.techName = ping.tech
        UserDefaults.standard.set(self.server, forKey: Self.serverKey)
        UserDefaults.standard.set(ping.tech, forKey: Self.techKey)
        Keychain.write(Self.keychainAccount, k)
    }

    func reset() {
        server = ""
        key = ""
        UserDefaults.standard.removeObject(forKey: Self.serverKey)
        Keychain.delete(Self.keychainAccount)
    }

    /// Lien de configuration : fixittrajet://setup?server=…&key=…
    func handle(url: URL) async -> String? {
        guard url.scheme == "fixittrajet", url.host == "setup",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let q = Dictionary((comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        guard let s = q["server"], let k = q["key"] else { return "Lien de configuration incomplet." }
        do {
            try await save(server: s, key: k)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

enum Keychain {
    private static let service = "fr.fixit-service.trajet"

    static func write(_ account: String, _ value: String) {
        delete(account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func read(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
