import Foundation
import CryptoKit

/// Stable device identity for Gateway pairing.
/// OpenClaw expects every client to present a keypair-derived device id and to
/// sign the server's connect-challenge nonce.
///
/// NOTE: the exact signature payload layout is defined in OpenClaw's
/// `src/gateway/protocol/schema/protocol-schemas.ts` (payload v2/v3) and can
/// change between releases. If connect fails with `DEVICE_AUTH_SIGNATURE_INVALID`,
/// compare this payload builder against the OpenClaw source for your installed
/// version (see README → Troubleshooting).
struct DeviceIdentity {
    let privateKey: Curve25519.Signing.PrivateKey

    var publicKeyBase64: String {
        privateKey.publicKey.rawRepresentation.base64EncodedString()
    }

    /// Device id = fingerprint (SHA-256 hex) of the raw public key.
    var deviceID: String {
        let digest = SHA256.hash(data: privateKey.publicKey.rawRepresentation)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// v2 payload — field order verified against the Control UI client
    /// (dist/control-ui/assets/gateway-*.js, function `j`):
    /// v2|deviceId|clientId|clientMode|role|scopes,csv|signedAtMs|token|nonce
    func signature(clientID: String, mode: String, role: String, scopes: [String],
                   token: String, nonce: String, signedAt: Int64) -> String {
        let payload = [
            "v2", deviceID, clientID, mode, role,
            scopes.joined(separator: ","), String(signedAt), token, nonce
        ].joined(separator: "|")
        let sig = (try? privateKey.signature(for: Data(payload.utf8))) ?? Data()
        return sig.base64EncodedString()
    }

    // MARK: Persistence (Keychain)

    private static let service = "com.athena.device-key"

    static func loadOrCreate() -> DeviceIdentity {
        if let data = Keychain.read(service: service, account: "ed25519"),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            return DeviceIdentity(privateKey: key)
        }
        let key = Curve25519.Signing.PrivateKey()
        Keychain.write(service: service, account: "ed25519", data: key.rawRepresentation)
        return DeviceIdentity(privateKey: key)
    }
}

/// Minimal Keychain wrapper for secrets (device key, gateway token).
enum Keychain {
    static func read(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    @discardableResult
    static func write(service: String, account: String, data: Data) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func readString(service: String, account: String) -> String? {
        read(service: service, account: account).flatMap { String(data: $0, encoding: .utf8) }
    }
    @discardableResult
    static func writeString(service: String, account: String, _ value: String) -> Bool {
        write(service: service, account: account, data: Data(value.utf8))
    }
}
