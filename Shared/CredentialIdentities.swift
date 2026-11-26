// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import AuthenticationServices
import KeePassCore

/// Publishes (username, domain) pairs to iOS so QuickType can suggest logins.
/// Passwords are never shared with the system. Opt-in via settings.
enum CredentialIdentities {
    static func recordIdentifier(database: UUID, entry: UUID) -> String {
        "\(database.uuidString)|\(entry.uuidString)"
    }

    static func parse(_ recordIdentifier: String?) -> (database: UUID, entry: UUID)? {
        guard let parts = recordIdentifier?.split(separator: "|"), parts.count == 2,
              let db = UUID(uuidString: String(parts[0])), let e = UUID(uuidString: String(parts[1])) else { return nil }
        return (db, e)
    }

    // The completion handlers below are @Sendable and ASCredentialIdentityStore isn't, so the shared store
    // is looked up inside each handler rather than captured.
    @MainActor
    static func update(for db: Database, reference: DatabaseReference) {
        guard AppSettings.shared.quickTypeSuggestions else {
            ASCredentialIdentityStore.shared.getState { state in
                if state.isEnabled { ASCredentialIdentityStore.shared.removeAllCredentialIdentities(nil) }
            }
            return
        }
        var identities: [ASPasswordCredentialIdentity] = []
        for entry in db.searchableEntries where !entry.userName.isEmpty && !entry.times.isExpired {
            let hosts = Set(URLMatcher.urls(of: entry).compactMap(URLMatcher.host(from:)))
            for host in hosts {
                identities.append(ASPasswordCredentialIdentity(
                    serviceIdentifier: ASCredentialServiceIdentifier(identifier: host, type: .domain),
                    user: entry.userName,
                    recordIdentifier: recordIdentifier(database: reference.id, entry: entry.uuid)))
            }
        }
        ASCredentialIdentityStore.shared.getState { state in
            guard state.isEnabled else { return }
            ASCredentialIdentityStore.shared.replaceCredentialIdentities(with: identities, completion: nil)
        }
    }

    static func removeAll() {
        ASCredentialIdentityStore.shared.removeAllCredentialIdentities(nil)
    }
}
