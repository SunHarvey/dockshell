import DockShellDomain
import Foundation
import LocalAuthentication
import Security

/// Blocking Security.framework calls stay on this actor, never the main actor.
/// Queries are restricted to DockShell's service and an opaque UUID account.
public actor KeychainCredentialStore: CredentialStore {
    private let service: String

    public init(service: String = "dev.dockshell.credentials") { self.service = service }

    private func query(id: UUID) -> [CFString: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                kSecAttrAccount: id.uuidString, kSecUseAuthenticationContext: context]
    }

    public func store(_ secret: Data, id: UUID) throws {
        var attributes = query(id: id)
        attributes[kSecValueData] = secret
        attributes[kSecAttrLabel] = "DockShell"
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw failure(status) }
    }

    public func read(id: UUID) throws -> Data? {
        var query = query(id: id)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        return data
    }

    public func delete(id: UUID) throws {
        let status = SecItemDelete(query(id: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }

    private func failure(_ status: OSStatus) -> DockShellError {
        switch status {
        case errSecAuthFailed, errSecUserCanceled: .keychainDenied
        case errSecInteractionNotAllowed: .keychainLocked
        default: .keychainUnavailable
        }
    }
}
