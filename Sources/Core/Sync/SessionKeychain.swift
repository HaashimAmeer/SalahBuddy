import Foundation
import Supabase

/// v5 §2, tooth #2 — the Supabase session moves to the shared keychain access
/// group, and **every existing sign-in survives the move**.
///
/// Until v5 the SDK stored the session with `KeychainLocalStorage()` and no
/// access group at all, which means it landed in this process's DEFAULT group.
/// A widget process cannot see that item, so the nudge button (§4) could never
/// authenticate. Pointing the client at `KeychainLocalStorage(accessGroup:)`
/// fixes the widget and, on its own, signs every current user out: the new
/// group is empty, and an empty group reads exactly like "never signed in".
///
/// So: read the old item once, re-store it under the shared group, and only
/// then let the client exist. That ordering is not a call-site convention — it
/// is enforced by construction, because the adoption runs inside `Supa.client`'s
/// own lazy initialiser and nothing can reach the client without it.
///
/// **Not covered here, on purpose:** SPEC-V5 §2 tooth #3, "the extension NEVER
/// refreshes". Two processes rotating one refresh token can invalidate each
/// other, so P4's widget will build its own client with `autoRefreshToken:
/// false` and deep-link into the app when the token is expired. Nothing in this
/// file precludes that — a second client with different auth options is
/// additive.
enum SessionKeychain {

    /// The Keychain service `KeychainLocalStorage` namespaces items under. It
    /// is the SDK's own default, restated because we have to address the very
    /// items the SDK would.
    static let service: String = "supabase.gotrue.swift"

    /// Set once a session has been adopted (or once the shared group already
    /// had one), and never cleared.
    ///
    /// This is what stops a signed-out user from being signed back IN. Sign-out
    /// removes the shared item; without the marker, the very next launch would
    /// find a leftover under the old group and cheerfully restore it. It also
    /// means adoption is attempted exactly once in the life of an install,
    /// which is what "read-once-and-re-store" says.
    static let adoptedKey: String = "v5.sessionKeychainAdopted"

    /// PURE. The storage key `SupabaseClient` derives from the project URL:
    /// `sb-<project ref>-auth-token`. Recomputed here from the same URL rather
    /// than hard-coded, so a project change moves both sides at once.
    ///
    /// Answers nil for a URL with no host — which `SupabaseClient` treats as
    /// fatal, and which this file treats as "then there is nothing to adopt".
    static func storageKey(forProjectURL url: URL) -> String? {
        guard let host: String = url.host(percentEncoded: false),
              let reference: Substring = host.split(separator: ".").first,
              !reference.isEmpty else { return nil }
        return "sb-\(reference)-auth-token"
    }

    /// What one adoption attempt did. Returned rather than logged so the
    /// decision is testable without a Keychain.
    enum Outcome: Equatable, Sendable {
        /// Already done once. Nothing is read, nothing is written — see
        /// `adoptedKey`.
        case alreadyRun
        /// The shared group already holds a session (a fresh v5 sign-in, or a
        /// second launch after a successful adoption).
        case alreadyShared
        /// Neither group has anything: a fresh install, or a solo user who has
        /// never signed in. Deliberately NOT remembered — a Keychain that was
        /// simply locked (a launch before first unlock) reads the same way, and
        /// recording that would orphan a real session forever.
        case nothingToAdopt
        /// Moved.
        case adopted
        /// The write did not land. Owed, not lost: the old item is untouched
        /// and the next launch tries again.
        case failed
    }

    /// The real thing: adopt from the process default group into the shared one.
    @discardableResult
    static func adoptLegacySessionIfNeeded(defaults: UserDefaults = .standard) -> Outcome {
        guard let key: String = SessionKeychain.storageKey(forProjectURL: SupabaseConfig.url) else {
            return .nothingToAdopt
        }
        return SessionKeychain.adopt(
            key: key,
            // NAMED, rather than the `accessGroup: nil` the SDK used to pass.
            // A Keychain query that names no access group is not scoped to the
            // default group — it SEARCHES every group the app is entitled to,
            // and `SecItemDelete` matches the same way. So an unscoped delete
            // here would take the copy just written to the shared group with
            // it: two items in, zero items out, everybody signed out. Naming
            // the group the v4 item is actually in makes the read exact and
            // the delete incapable of reaching the new copy.
            legacy: KeychainSessionStore(accessGroup: SharedContainer.legacyKeychainAccessGroup),
            shared: KeychainSessionStore(accessGroup: SharedContainer.keychainAccessGroup),
            defaults: defaults)
    }

    /// The move itself, over a seam, so the whole decision table is reachable
    /// from a test with two dictionaries.
    @discardableResult
    static func adopt(key: String,
                      legacy: any SessionStore,
                      shared: any SessionStore,
                      defaults: UserDefaults) -> Outcome {
        guard !defaults.bool(forKey: SessionKeychain.adoptedKey) else { return .alreadyRun }

        if let existing: Data = shared.read(key), !existing.isEmpty {
            defaults.set(true, forKey: SessionKeychain.adoptedKey)
            return .alreadyShared
        }
        guard let carried: Data = legacy.read(key), !carried.isEmpty else {
            return .nothingToAdopt
        }
        guard shared.write(key, carried) else { return .failed }

        // The old copy is a duplicate credential now — a refresh token that
        // outlives the sign-out that was supposed to end it — so it goes.
        legacy.delete(key)
        if shared.read(key) == nil {
            // The delete reached the new copy as well: the two groups resolved
            // to one item. That is what the SIMULATOR does — it ignores access
            // groups entirely and keeps a single Keychain for every app — and
            // it is what a mis-scoped query would do on a device. Put it back;
            // signing everyone out is the one outcome this file exists to
            // prevent, and it is worth a second write to be sure of.
            _ = shared.write(key, carried)
        }
        defaults.set(true, forKey: SessionKeychain.adoptedKey)
        return .adopted
    }
}

// MARK: - The seam

/// The three Keychain operations the adoption needs, and nothing else.
///
/// It exists so the decision table above can be tested without a Keychain —
/// and, just as much, so the test target does not have to link Supabase to
/// name `AuthLocalStorage`.
protocol SessionStore {
    func read(_ key: String) -> Data?
    /// True when the value is stored. Failures are reported, never thrown: a
    /// Keychain that cannot be written to is a launch that retries, not a crash.
    func write(_ key: String, _ value: Data) -> Bool
    func delete(_ key: String)
}

/// The production `SessionStore`: the SDK's own `KeychainLocalStorage`.
///
/// Wrapping the SDK type rather than issuing `SecItem` calls by hand is the
/// point. The queries this adoption has to match are the ones the client will
/// use afterwards — same service, same account, same accessibility — and the
/// only way to guarantee that through an SDK upgrade is to run the SDK's code.
struct KeychainSessionStore: SessionStore {
    private let storage: KeychainLocalStorage

    init(accessGroup: String?) {
        self.storage = KeychainLocalStorage(service: SessionKeychain.service,
                                            accessGroup: accessGroup)
    }

    func read(_ key: String) -> Data? {
        // `errSecItemNotFound` throws here rather than answering nil, and it is
        // the ordinary case on a fresh install.
        try? storage.retrieve(key: key)
    }

    func write(_ key: String, _ value: Data) -> Bool {
        do {
            try storage.store(key: key, value: value)
            return true
        } catch {
            return false
        }
    }

    func delete(_ key: String) {
        try? storage.remove(key: key)
    }
}
