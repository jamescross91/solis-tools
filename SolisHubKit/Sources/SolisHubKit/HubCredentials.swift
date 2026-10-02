import Foundation
import Security

/// Everything a request to the hub must carry. The bearer token is the hub's
/// own check; the Cloudflare pair is for Cloudflare Access in front of the
/// tunnel and is sent only when both halves are present.
public struct HubAuth: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var token: String
    public var cloudflareClientID: String?
    public var cloudflareClientSecret: String?

    public init(token: String, cloudflareClientID: String? = nil, cloudflareClientSecret: String? = nil) {
        self.token = token
        self.cloudflareClientID = cloudflareClientID
        self.cloudflareClientSecret = cloudflareClientSecret
    }

    public func headers() -> [String: String] {
        var result = ["Authorization": "Bearer \(token)"]
        if let id = cloudflareClientID, let secret = cloudflareClientSecret,
           !id.isEmpty, !secret.isEmpty {
            result["CF-Access-Client-Id"] = id
            result["CF-Access-Client-Secret"] = secret
        }
        return result
    }

    // A secret in a log line or a crash report is a leak, so printing a value
    // never shows one.
    public var description: String { "HubAuth(redacted)" }
    public var debugDescription: String { "HubAuth(redacted)" }
}

public enum HubCredentialsError: Error, Equatable, LocalizedError {
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .keychain(status):
            return "The Keychain refused the request (status \(status))."
        }
    }
}

/// Keychain storage for the hub token and the optional Cloudflare Access
/// pair. Nothing here ever logs or returns a secret except `load()`.
///
/// `accessGroup` lets the iOS app share credentials with a widget. Leave it
/// nil on macOS: the menu bar app is not sandboxed or provisioned, and an
/// access group there needs entitlements it does not have.
public struct HubCredentials: Sendable {
    public let service: String
    public let accessGroup: String?

    public init(service: String = "solis-tools.hub", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private enum Account: String {
        case token
        case cloudflareClientID = "cloudflare-client-id"
        case cloudflareClientSecret = "cloudflare-client-secret"
    }

    /// The stored credentials, or nil when no token has been saved.
    public func load() throws -> HubAuth? {
        guard let token = try read(.token), !token.isEmpty else { return nil }
        return HubAuth(
            token: token,
            cloudflareClientID: try read(.cloudflareClientID),
            cloudflareClientSecret: try read(.cloudflareClientSecret)
        )
    }

    public func hasToken() -> Bool {
        (try? read(.token))?.isEmpty == false
    }

    /// An empty or nil Cloudflare value removes that entry.
    public func save(_ auth: HubAuth) throws {
        try write(.token, value: auth.token)
        try write(.cloudflareClientID, value: auth.cloudflareClientID)
        try write(.cloudflareClientSecret, value: auth.cloudflareClientSecret)
    }

    public func delete() throws {
        try write(.token, value: nil)
        try write(.cloudflareClientID, value: nil)
        try write(.cloudflareClientSecret, value: nil)
    }

    private func baseQuery(_ account: Account) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func read(_ account: Account) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw HubCredentialsError.keychain(status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ account: Account, value: String?) throws {
        let query = baseQuery(account)
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw HubCredentialsError.keychain(status)
            }
            return
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw HubCredentialsError.keychain(update) }
        var insert = query
        insert[kSecValueData as String] = data
        #if os(iOS)
        // Readable once after the first unlock so a background refresh still
        // works, and never migrated to another device.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw HubCredentialsError.keychain(status) }
    }
}
