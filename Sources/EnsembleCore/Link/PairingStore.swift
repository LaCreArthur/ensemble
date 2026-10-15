import CryptoKit
import Foundation
import Security

/// The pairing with the other Mac, kept as one item in the login keychain: account = the other
/// Mac's ID, label = its name, data = the shared secret. Items from older versions, made by another
/// bundle id or signature, would need the user's password to read, so the service names this app.
public enum PairingStore {
    private static let service = "com.lacrearthur.ensemble.pairing"

    public static func load() -> Link.Pairing? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecReturnAttributes: true, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let item = result as? [CFString: Any],
              let id = item[kSecAttrAccount] as? String, let data = item[kSecValueData] as? Data, data.count == 32 else { return nil }
        return Link.Pairing(peer: Link.Peer(id: id, name: item[kSecAttrLabel] as? String ?? id), key: SymmetricKey(data: data))
    }

    /// Replaces any earlier pairing.
    public static func save(_ pairing: Link.Pairing) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
        let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                     kSecAttrAccount: pairing.peer.id, kSecAttrLabel: pairing.peer.name,
                                     kSecValueData: pairing.key.withUnsafeBytes { Data($0) }]
        SecItemAdd(item as CFDictionary, nil)
    }
}
