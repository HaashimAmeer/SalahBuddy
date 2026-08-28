import Foundation
import XCTest
@testable import SalahBuddy

/// v5 §2, tooth #2 — the session moves to the shared keychain access group and
/// every existing sign-in survives it.
///
/// This is the failure that has no symptom until it is far too late: the update
/// ships, the new access group is empty, and the whole TestFlight roster is
/// silently signed out of circles they cannot rejoin without an invite code.
/// Nothing on screen says so — the app just looks like a fresh install.
///
/// So the decision table is a function over two `SessionStore`s and a
/// `UserDefaults`, and every branch is asserted here with dictionaries standing
/// in for the Keychain. What the real thing adds is only which Keychain access
/// group each store addresses, and that is `SalahBuddy.entitlements`' job.
final class SessionKeychainTests: XCTestCase {

    // MARK: - Rig

    /// A `SessionStore` that is a dictionary, plus the two counters that say
    /// whether the adoption touched what it claims to touch.
    private final class FakeSessionStore: SessionStore {
        var items: [String: Data]
        var writable: Bool
        /// `SecItemDelete` failing is the whole of the retry story — a Keychain
        /// still locked before first unlock is the ordinary cause, and it
        /// leaves the item exactly where it was.
        var deletable: Bool
        private(set) var writes: Int = 0
        private(set) var deletes: Int = 0

        init(_ items: [String: Data] = [:], writable: Bool = true, deletable: Bool = true) {
            self.items = items
            self.writable = writable
            self.deletable = deletable
        }

        func read(_ key: String) -> Data? { items[key] }

        func write(_ key: String, _ value: Data) -> Bool {
            writes += 1
            guard writable else { return false }
            items[key] = value
            return true
        }

        func delete(_ key: String) {
            deletes += 1
            guard deletable else { return }
            items.removeValue(forKey: key)
        }
    }

    /// One Keychain seen through two names — the Simulator, which ignores
    /// access groups entirely and keeps a single Keychain for every app.
    private final class AliasedSessionStore: SessionStore {
        private let backing: FakeSessionStore
        init(_ backing: FakeSessionStore) { self.backing = backing }
        func read(_ key: String) -> Data? { backing.read(key) }
        func write(_ key: String, _ value: Data) -> Bool { backing.write(key, value) }
        func delete(_ key: String) { backing.delete(key) }
    }

    /// A store whose DELETE reaches further than its writes — the shape of an
    /// access-group-less Keychain query, which searches (and deletes across)
    /// every group the app is entitled to rather than just the default one.
    private final class SpillingSessionStore: SessionStore {
        private let own: FakeSessionStore
        private let alsoDeletesFrom: FakeSessionStore

        init(own: FakeSessionStore, alsoDeletesFrom: FakeSessionStore) {
            self.own = own
            self.alsoDeletesFrom = alsoDeletesFrom
        }

        func read(_ key: String) -> Data? { own.read(key) }
        func write(_ key: String, _ value: Data) -> Bool { own.write(key, value) }

        func delete(_ key: String) {
            own.delete(key)
            alsoDeletesFrom.delete(key)
        }
    }

    private let key = "sb-rmyygmyxppmnzcnvprvb-auth-token"
    private let session = Data("{\"refresh_token\":\"v4\"}".utf8)

    private func scratchDefaults() throws -> UserDefaults {
        let suite = "v5-session-tests-\(UUID().uuidString)"
        let defaults: UserDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return defaults
    }

    // MARK: - The storage key

    /// The key is `SupabaseClient`'s own derivation (`sb-<project ref>-auth-token`),
    /// recomputed rather than hard-coded — a project change has to move both
    /// sides at once or the adoption reads an item nobody wrote.
    func testTheStorageKeyMatchesWhatTheSDKDerives() throws {
        XCTAssertEqual(SessionKeychain.storageKey(forProjectURL: SupabaseConfig.url), key)
        XCTAssertEqual(
            SessionKeychain.storageKey(
                forProjectURL: try XCTUnwrap(URL(string: "https://abc123.supabase.co"))),
            "sb-abc123-auth-token")
    }

    func testAURLWithNoHostHasNothingToAdopt() {
        XCTAssertNil(SessionKeychain.storageKey(
            forProjectURL: URL(fileURLWithPath: "/nowhere")))
    }

    // MARK: - The move

    /// The one that matters: a v4 user updates, and stays signed in.
    func testAnExistingSessionIsCarriedIntoTheSharedGroup() throws {
        let defaults: UserDefaults = try scratchDefaults()
        let legacy = FakeSessionStore([key: session])
        let shared = FakeSessionStore()

        let outcome: SessionKeychain.Outcome = SessionKeychain.adopt(
            key: key, legacy: legacy, shared: shared, defaults: defaults)

        XCTAssertEqual(outcome, .adopted)
        XCTAssertEqual(shared.read(key), session, "this is the sign-in surviving the update")
        XCTAssertNil(legacy.read(key),
                     "the old copy is a refresh token that would outlive its own sign-out")
        XCTAssertTrue(defaults.bool(forKey: SessionKeychain.adoptedKey))
        XCTAssertTrue(defaults.bool(forKey: SessionKeychain.legacyClearedKey),
                      "the v4 item is confirmed gone, so nothing is owed")
    }

    /// The delete is fallible, and a v4 item that survives is not cosmetic: it
    /// is a live rotating refresh token, and `signOut()` will never reach it —
    /// the client only knows the shared group. So it is retried, and the
    /// adoption is not called finished until a re-read says the item is gone.
    func testAV4ItemThatSurvivesTheDeleteIsRetriedUntilItIsActuallyGone() throws {
        let defaults: UserDefaults = try scratchDefaults()
        let legacy = FakeSessionStore([key: session], deletable: false)
        let shared = FakeSessionStore()

        XCTAssertEqual(SessionKeychain.adopt(key: key, legacy: legacy, shared: shared,
                                             defaults: defaults), .adopted)
        XCTAssertEqual(shared.read(key), session)
        XCTAssertTrue(defaults.bool(forKey: SessionKeychain.adoptedKey),
                      "the session is home; that half must be recorded or the next launch "
                      + "signs a signed-out user back in")
        XCTAssertEqual(legacy.read(key), session, "the delete did not take")
        XCTAssertFalse(defaults.bool(forKey: SessionKeychain.legacyClearedKey),
                       "a token still on the device is owed work, not a finished migration")

        // Next launch, Keychain unlocked. Same call, and this time it lands.
        legacy.deletable = true
        XCTAssertEqual(SessionKeychain.adopt(key: key, legacy: legacy, shared: shared,
                                             defaults: defaults), .alreadyRun)

        XCTAssertNil(legacy.read(key), "the duplicate credential is gone for good")
        XCTAssertEqual(shared.read(key), session, "and the session was never at risk")
        XCTAssertTrue(defaults.bool(forKey: SessionKeychain.legacyClearedKey))
    }

    /// The same retry, for someone who signed OUT in between. The leftover is
    /// exactly the item that must not survive — and clearing it must not put
    /// them back in.
    func testALeftoverIsClearedAfterASignOutWithoutSigningAnyoneBackIn() throws {
        let defaults: UserDefaults = try scratchDefaults()
        let legacy = FakeSessionStore([key: session], deletable: false)
        let shared = FakeSessionStore()
        XCTAssertEqual(SessionKeychain.adopt(key: key, legacy: legacy, shared: shared,
                                             defaults: defaults), .adopted)

        // …they sign out. `signOut()` clears the shared item, which is the only
        // storage the client knows about; the v4 item is untouched by it.
        shared.items.removeValue(forKey: key)
        legacy.deletable = true

        let outcome: SessionKeychain.Outcome = SessionKeychain.adopt(
            key: key, legacy: legacy, shared: shared, defaults: defaults)

        XCTAssertEqual(outcome, .alreadyRun)
        XCTAssertNil(shared.read(key), "signed out is signed out")
        XCTAssertNil(legacy.read(key),
                     "a refresh token that outlives the sign-out that was supposed to end it")
        XCTAssertTrue(defaults.bool(forKey: SessionKeychain.legacyClearedKey))
    }

    /// A retry that cannot tell one Keychain from two must still not sign
    /// anyone out. Same belt as the adoption itself, on the later launch.
    func testARetriedDeleteThatSpillsAcrossGroupsStillCannotStrandTheUser() throws {
        let defaults: UserDefaults = try scratchDefaults()
        let old = FakeSessionStore([key: session])
        let shared = FakeSessionStore([key: session])
        let spilling = SpillingSessionStore(own: old, alsoDeletesFrom: shared)
        // The session is already home; only the clean-up is owed.
        defaults.set(true, forKey: SessionKeychain.adoptedKey)

        let outcome: SessionKeychain.Outcome = SessionKeychain.adopt(
            key: key, legacy: spilling, shared: shared, defaults: defaults)

        XCTAssertEqual(outcome, .alreadyRun)
        XCTAssertEqual(shared.read(key), session,
                       "the copy the app is about to read must survive the tidy-up")
        XCTAssertTrue(defaults.bool(forKey: SessionKeychain.legacyClearedKey),
                      "one item seen twice has no old copy to chase; stop asking")
    }

    /// Read-once. Sign-out removes the shared item; without the marker the very
    /// next launch would find a leftover under the old group and sign the
    /// person back in.
    func testASignedOutUserIsNeverSignedBackIn() throws {
        let defaults: UserDefaults = try scratchDefaults()
        let legacy = FakeSessionStore([key: session])
        let shared = FakeSessionStore()
        XCTAssertEqual(SessionKeychain.adopt(key: key, legacy: legacy, shared: shared,
                                             defaults: defaults), .adopted)

        // …they sign out, which clears the shared item. And something is under
        // the old group again — a re-plant here, a Keychain restored from a
        // backup in the real world. It is not a session this app may use.
        shared.items.removeValue(forKey: key)
        legacy.items[key] = session

        let outcome: SessionKeychain.Outcome = SessionKeychain.adopt(
            key: key, legacy: legacy, shared: shared, defaults: defaults)

        XCTAssertEqual(outcome, .alreadyRun)
        XCTAssertNil(shared.read(key), "signed out is signed out")
    }

    /// A fresh v5 sign-in, or the second launch after a successful adoption.
    func testASessionAlreadyInTheSharedGroupIsLeftAlone() throws {
        let defaults: UserDefaults = try scratchDefaults()
        let legacy = FakeSessionStore()
        let shared = FakeSessionStore([key: session])

        let outcome: SessionKeychain.Outcome = SessionKeychain.adopt(
            key: key, legacy: legacy, shared: shared, defaults: defaults)

        XCTAssertEqual(outcome, .alreadyShared)
        XCTAssertEqual(shared.writes, 0, "a session that is already home is not rewritten")
        XCTAssertEqual(shared.read(key), session)
        XCTAssertTrue(defaults.bool(forKey: SessionKeychain.adoptedKey))
    }

    /// A solo user who never signed in — the common case, and the one that must
    /// stay retryable.
    func testNothingToAdoptIsNotRemembered() throws {
        let defaults: UserDefaults = try scratchDefaults()
        let legacy = FakeSessionStore()
        let shared = FakeSessionStore()

        XCTAssertEqual(SessionKeychain.adopt(key: key, legacy: legacy, shared: shared,
                                             defaults: defaults), .nothingToAdopt)
        XCTAssertFalse(defaults.bool(forKey: SessionKeychain.adoptedKey),
                       "a Keychain that was merely LOCKED reads exactly like this one")

        // Which is the whole point: the launch after it still adopts.
        legacy.items[key] = session
        XCTAssertEqual(SessionKeychain.adopt(key: key, legacy: legacy, shared: shared,
                                             defaults: defaults), .adopted)
    }

    /// A write that did not land leaves the old copy exactly where it was, and
    /// records nothing — so the next launch tries again.
    func testAFailedWriteLeavesTheOldSessionIntactAndOwed() throws {
        let defaults: UserDefaults = try scratchDefaults()
        let legacy = FakeSessionStore([key: session])
        let shared = FakeSessionStore(writable: false)

        let outcome: SessionKeychain.Outcome = SessionKeychain.adopt(
            key: key, legacy: legacy, shared: shared, defaults: defaults)

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(legacy.read(key), session, "nothing is deleted until something is stored")
        XCTAssertEqual(legacy.deletes, 0)
        XCTAssertFalse(defaults.bool(forKey: SessionKeychain.adoptedKey))
    }

    /// The belt for the destructive step, and the reason both stores name their
    /// access group explicitly.
    ///
    /// A Keychain query with no access group does not mean "the default group"
    /// — it searches, and DELETES ACROSS, every group the app is entitled to.
    /// So the obvious implementation (`accessGroup: nil` for the old copy)
    /// writes the session into the shared group and then deletes both items:
    /// two in, zero out, every user signed out by the very code meant to keep
    /// them in. This models a delete that spills, and asserts the session is
    /// still there afterwards.
    func testADeleteThatSpillsAcrossGroupsCannotStrandTheUser() throws {
        let defaults: UserDefaults = try scratchDefaults()
        let old = FakeSessionStore([key: session])
        let shared = FakeSessionStore()
        let spilling = SpillingSessionStore(own: old, alsoDeletesFrom: shared)

        let outcome: SessionKeychain.Outcome = SessionKeychain.adopt(
            key: key, legacy: spilling, shared: shared, defaults: defaults)

        XCTAssertEqual(outcome, .adopted)
        XCTAssertEqual(shared.read(key), session,
                       "the copy the app is about to read must survive the tidy-up")
        XCTAssertNil(old.read(key))
        XCTAssertTrue(defaults.bool(forKey: SessionKeychain.adoptedKey))
    }

    /// The Simulator, which ignores access groups and keeps one Keychain for
    /// everything — so the two stores are literally the same item. The session
    /// is already visible to the "shared" reader, so there is nothing to move.
    ///
    /// The clean-up still probes, because there is no non-destructive way to
    /// ask "are these two groups the same one": it deletes, sees the shared
    /// copy vanish with it, and writes it straight back. What matters is the
    /// state afterwards — the session is there, and the app stops asking, so
    /// this cannot become a delete-and-restore on every launch.
    func testOneKeychainSeenTwiceEndsUpExactlyAsItWas() throws {
        let defaults: UserDefaults = try scratchDefaults()
        let backing = FakeSessionStore([key: session])

        let outcome: SessionKeychain.Outcome = SessionKeychain.adopt(
            key: key,
            legacy: AliasedSessionStore(backing),
            shared: AliasedSessionStore(backing),
            defaults: defaults)

        XCTAssertEqual(outcome, .alreadyShared)
        XCTAssertEqual(backing.read(key), session, "the one item there is survives")
        XCTAssertTrue(defaults.bool(forKey: SessionKeychain.legacyClearedKey))

        // And the launch after it touches nothing at all.
        let deletesSoFar: Int = backing.deletes
        XCTAssertEqual(SessionKeychain.adopt(key: key,
                                             legacy: AliasedSessionStore(backing),
                                             shared: AliasedSessionStore(backing),
                                             defaults: defaults), .alreadyRun)
        XCTAssertEqual(backing.deletes, deletesSoFar)
        XCTAssertEqual(backing.read(key), session)
    }

    /// An empty value is not a session. A Keychain item truncated to zero bytes
    /// would otherwise be adopted, remembered, and read back by the SDK as a
    /// decode failure with no way to retry.
    func testAnEmptyItemIsNotASession() throws {
        let defaults: UserDefaults = try scratchDefaults()
        let legacy = FakeSessionStore([key: Data()])
        let shared = FakeSessionStore()

        XCTAssertEqual(SessionKeychain.adopt(key: key, legacy: legacy, shared: shared,
                                             defaults: defaults), .nothingToAdopt)
        XCTAssertEqual(shared.writes, 0)
    }
}
