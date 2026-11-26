// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import LocalAuthentication
import Security

/// Stores each database's derived master key in the Keychain, protected by
/// Face ID / Touch ID (invalidated if biometric enrolment changes).
enum BiometricKeyStore {
    enum StoreError: LocalizedError {
        case cancelled
        case notFound
        case failed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .cancelled: return String(localized: "Authentication was cancelled.")
            case .notFound: return String(localized: "\(BiometricKeyStore.biometryName) unlock needs to be set up again. Unlock with your master password.")
            case .failed(let s): return String(localized: "Keychain error (\(Int(s))).")
            }
        }
    }

    // Internal Keychain service name, unchanged since the app was called KeyCrate so that
    // Face ID unlock keeps working for existing installs.
    private static let service = "KeyCrate.BiometricKeys"

    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    static var biometryName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default:
            if #available(iOS 17.0, *), ctx.biometryType == .opticID { return "Optic ID" }
            return String(localized: "Biometrics")
        }
    }

    static var biometrySymbol: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .touchID: return "touchid"
        case .faceID: return "faceid"
        default:
            if #available(iOS 17.0, *), ctx.biometryType == .opticID { return "opticid" }
            return "lock.shield"
        }
    }

    private static func baseQuery(_ id: UUID) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        if let group = AppConfig.keychainAccessGroup {
            q[kSecAttrAccessGroup as String] = group
        }
        return q
    }

    static func store(_ key: Data, for id: UUID) throws {
        delete(for: id)
        var cfError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                           .biometryCurrentSet, &cfError) else {
            throw StoreError.failed(errSecParam)
        }
        var q = baseQuery(id)
        q[kSecValueData as String] = key
        q[kSecAttrAccessControl as String] = access
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.failed(status) }
    }

    /// Checks for a stored key without prompting the user.
    static func hasKey(for id: UUID) -> Bool {
        let ctx = LAContext()
        ctx.interactionNotAllowed = true
        var q = baseQuery(id)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecUseAuthenticationContext as String] = ctx
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    /// Prompts for biometrics and returns the stored key. Blocks; call off the main thread.
    static func loadKey(for id: UUID, reason: String) throws -> Data {
        let ctx = LAContext()
        ctx.localizedReason = reason
        ctx.localizedFallbackTitle = ""
        var q = baseQuery(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecUseAuthenticationContext as String] = ctx
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw StoreError.notFound }
            return data
        case errSecUserCanceled, errSecAuthFailed:
            throw StoreError.cancelled
        case errSecItemNotFound:
            throw StoreError.notFound
        default:
            throw StoreError.failed(status)
        }
    }

    static func delete(for id: UUID) {
        SecItemDelete(baseQuery(id) as CFDictionary)
    }
}
