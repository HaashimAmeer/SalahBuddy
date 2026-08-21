import AuthenticationServices
import Foundation
import GoogleSignIn
import Supabase
import UIKit

// MARK: - The slice of the local profile that syncs

/// What SPEC-V4 §1 lets off the device on sign-in: a name, a face, and how the
/// app should address you. XP, streaks, badges and photos are *your* journey —
/// they stay local, and there is nothing in this struct that could carry them.
struct LocalIdentity: Equatable, Sendable {
    var name: String
    var avatarEmoji: String?
    var memberKind: String?

    init(name: String, avatarEmoji: String? = nil, memberKind: String? = nil) {
        self.name = name
        self.avatarEmoji = avatarEmoji
        self.memberKind = memberKind
    }

    /// Read straight from `Store`, the way `NotificationManager` does — so
    /// signing in never needs an `AppState` to exist first. `AppState` can
    /// override `AuthService.localIdentity` with its in-memory copy.
    ///
    /// v4 DECISION: `avatarEmoji` is nil. `UserProfile` has no emoji field —
    /// "you" is drawn with a hard-coded 😄 — so there is nothing per-person to
    /// send yet, and shipping that constant would paint every face in the
    /// roster identically (`CircleSnapshot.makeMember` prefers a stored emoji
    /// over its own nicer per-role fallback). The column and this plumbing
    /// exist so that the day a profile emoji becomes editable, it syncs.
    static func fromStore() -> LocalIdentity {
        let profile: UserProfile = Store.load(Store.profileFile,
                                              default: UserProfile.fresh(now: AppClock.now))
        let settings: AppSettings = Store.load(Store.settingsFile, default: AppSettings())
        return LocalIdentity(name: profile.name, avatarEmoji: nil,
                             memberKind: settings.memberKind)
    }

    /// Everything §1 lets off the device, in one comparable line.
    ///
    /// v4 DECISION: the profile mirror is retried off a DURABLE fingerprint
    /// rather than an in-memory "pending" flag. A flag set when the sign-in
    /// write failed is gone by the next launch — which is precisely when the
    /// retry was meant to run — and it says nothing at all about a name or a
    /// gender edited in Settings a week later. Comparing this string to the one
    /// stored after the last successful write answers both questions, and
    /// answers "nothing has changed" without a request.
    ///
    /// The user id is part of it so that signing into a different account never
    /// inherits the previous account's "already synced".
    func syncFingerprint(userID: UUID) -> String {
        [userID.uuidString, name, avatarEmoji ?? "", memberKind ?? ""]
            .joined(separator: "\u{1}")
    }
}

// MARK: - Errors this file raises itself

/// Failures that happen before Supabase is ever asked. Kept separate from
/// `CircleError` because they are about the PROVIDER handshake, and separate
/// from Supabase's own `AuthError` so the two never get confused at a call site.
enum SignInError: LocalizedError, Equatable {
    /// The provider came back without an ID token — nothing to exchange.
    case missingIdentityToken
    /// No foreground window to present the provider's sheet from.
    case noPresenter
    /// A completion handler that fired with neither a result nor an error.
    case providerReturnedNothing
    /// The person backed out. Callers should stay silent about this one.
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingIdentityToken:  return "That sign-in didn't come back with an identity token."
        case .noPresenter:           return "There's no window to show the sign-in sheet in."
        case .providerReturnedNothing: return "The sign-in sheet closed without an answer."
        case .cancelled:             return "Sign-in cancelled."
        }
    }
}

// MARK: - The profiles write payload

/// The four columns `profiles` grants an UPDATE on. `id` is deliberately
/// absent (see `AuthService.writeProfile`), and a nil is OMITTED rather than
/// sent as null so a field this build doesn't own can't blank one the server
/// already has.
///
/// Kept at file scope rather than nested inside `AuthService`: `Encodable`'s
/// `encode(to:)` is a nonisolated requirement, and a type nested in a
/// `@MainActor` class is the sort of thing that either does or does not
/// inherit that isolation depending on the compiler you ask.
private struct ProfilePatch: Encodable {
    let name: String
    let avatarEmoji: String?
    let memberKind: String?

    enum CodingKeys: String, CodingKey {
        case name
        case avatarEmoji = "avatar_emoji"
        case memberKind = "member_kind"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(avatarEmoji, forKey: .avatarEmoji)
        try c.encodeIfPresent(memberKind, forKey: .memberKind)
    }
}

// MARK: - AuthService

/// Apple + Google sign-in, exchanged for a Supabase session.
///
/// **THE NONCE RULE** (verified against supabase/auth `internal/api/token_oidc.go`,
/// which computes `sha256hex(params.nonce)` and compares it to the ID token's
/// `nonce` claim): generate a raw nonce, give the PROVIDER `sha256Hex(raw)`,
/// give Supabase `raw`. Identical for both providers. Every call below routes
/// through `completeSignIn`, so there is exactly one place the rule can be
/// wrong.
@MainActor
final class AuthService: ObservableObject {

    /// The signed-in Supabase user, which is also the `profiles.id` and the
    /// `CircleSnapshot.me` that makes `isYou` decidable offline.
    @Published private(set) var userID: UUID?

    /// A provider sheet or token exchange is in flight — the sign-in buttons
    /// read this to disable themselves.
    @Published private(set) var isWorking: Bool = false

    /// Copy for the sheet to show, already in the app's voice. Settable so the
    /// UI can clear it when the person moves on.
    @Published var lastError: String?

    /// True when the profile mirror is owed a write — the sign-in succeeded but
    /// the `profiles` row didn't land (offline, usually). Reported rather than
    /// relied on: the durable answer is `syncFingerprint`, so the retry in
    /// `syncProfileIfNeeded(userID:)` survives a relaunch, which this flag
    /// cannot.
    @Published private(set) var profileSyncPending: Bool = false

    var isSignedIn: Bool { userID != nil }

    /// Where the syncable slice of the profile comes from. Injectable so
    /// `AppState` can hand over its in-memory copy instead of re-reading disk.
    var localIdentity: () -> LocalIdentity = { LocalIdentity.fromStore() }

    /// Called when a provider supplies a display name and the local profile has
    /// none. Apple sends `fullName` exactly ONCE — on the very first
    /// authorization, never again — so a name dropped here is gone for good.
    var onDisplayName: ((String) -> Void)?

    // MARK: - Apple

    /// Stamps an Apple request with the HASHED nonce and hands back the RAW one
    /// for `signInWithApple(credential:rawNonce:)`.
    ///
    /// The two halves are produced together because that is the only way they
    /// can't drift: a caller that hashes on the wrong side gets a sign-in that
    /// fails only against the real server, ten minutes into a CI round trip.
    static func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) -> String {
        let raw: String = Nonce.random()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Nonce.sha256Hex(raw)
        return raw
    }

    func signInWithApple(credential: ASAuthorizationAppleIDCredential,
                         rawNonce: String) async throws {
        isWorking = true
        defer { isWorking = false }
        lastError = nil

        guard let tokenData: Data = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            let failure = SignInError.missingIdentityToken
            lastError = CircleError.from(failure).message
            throw failure
        }

        let appleName: String = AuthService.displayName(from: credential.fullName)
        do {
            try await completeSignIn(provider: .apple, idToken: idToken,
                                     accessToken: nil, rawNonce: rawNonce,
                                     providerName: appleName)
        } catch {
            lastError = CircleError.from(error).message
            throw error
        }
    }

    // MARK: - Google

    func signInWithGoogle() async throws {
        isWorking = true
        defer { isWorking = false }
        lastError = nil

        GoogleAuthConfig.applyIfNeeded()
        guard let presenter: UIViewController = AuthService.topViewController() else {
            let failure = SignInError.noPresenter
            lastError = CircleError.from(failure).message
            throw failure
        }

        let rawNonce: String = Nonce.random()
        do {
            let result: GIDSignInResult = try await AuthService.googleSignIn(
                presenting: presenter, hashedNonce: Nonce.sha256Hex(rawNonce))
            guard let idToken: String = result.user.idToken?.tokenString else {
                throw SignInError.missingIdentityToken
            }
            let accessToken: String = result.user.accessToken.tokenString
            let googleName: String = result.user.profile?.name ?? ""
            try await completeSignIn(provider: .google, idToken: idToken,
                                     accessToken: accessToken, rawNonce: rawNonce,
                                     providerName: googleName)
        } catch {
            // Backing out of the sheet is not a failure — it gets no banner.
            if let signIn = error as? SignInError, signIn == .cancelled {
                throw signIn
            }
            lastError = CircleError.from(error).message
            throw error
        }
    }

    /// Google's Swift API here is an ObjC method with a *nullable* completion
    /// block, and Swift's automatic async import of those is not guaranteed —
    /// so the bridge is written by hand. The one invariant: resume EXACTLY once
    /// on every path, including the both-nil case an ObjC block can always
    /// produce and a Swift `async` signature cannot express.
    private static func googleSignIn(presenting: UIViewController,
                                     hashedNonce: String) async throws -> GIDSignInResult {
        typealias Continuation = CheckedContinuation<GIDSignInResult, any Error>
        return try await withCheckedThrowingContinuation { (continuation: Continuation) in
            GIDSignIn.sharedInstance.signIn(withPresenting: presenting,
                                            hint: nil,
                                            additionalScopes: nil,
                                            nonce: hashedNonce,
                                            claims: nil) { result, error in
                if let error {
                    if AuthService.isGoogleCancellation(error) {
                        continuation.resume(throwing: SignInError.cancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let result else {
                    continuation.resume(throwing: SignInError.providerReturnedNothing)
                    return
                }
                continuation.resume(returning: result)
            }
        }
    }

    /// `kGIDSignInErrorCodeCanceled` (-5) in `kGIDSignInErrorDomain`, both
    /// spelled as literals from GIDSignIn.h / GIDSignIn.m. The Clang importer
    /// renames `NS_ERROR_ENUM` types (`GIDSignInErrorCode` becomes
    /// `GIDSignInError.Code`), and guessing that spelling wrong is exactly the
    /// class of mistake that only shows up ten minutes later on CI. Checking
    /// the domain too means the bare number can't collide with anything.
    ///
    /// `nonisolated` because it is called from inside Google's completion
    /// BLOCK, which is escaping and therefore does not inherit this class's
    /// `@MainActor` — a main-actor helper called from there is a compile error.
    private nonisolated static func isGoogleCancellation(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "com.google.GIDSignIn" && nsError.code == -5
    }

    /// Google's callback URL, for the app's `.onOpenURL`.
    @discardableResult
    func handleOpenURL(_ url: URL) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }

    // MARK: - Session lifecycle

    /// Adopt whatever session is already in the Keychain. Never throws: a cold
    /// launch in airplane mode must not sign anyone out.
    func restore() async {
        if let stored: Session = Supa.client.auth.currentSession {
            userID = stored.user.id
        }
        do {
            let session: Session = try await Supa.client.auth.session
            userID = session.user.id
        } catch {
            // ONLY a definitive "there is no session" clears the id. A refresh
            // that failed because the network is down leaves a perfectly good
            // session in the Keychain, and dropping it would kick a user out of
            // their circle for the crime of being on a train.
            if let authError = error as? AuthError, authError == .sessionMissing {
                userID = nil
            }
        }
    }

    func signOut() async {
        isWorking = true
        defer { isWorking = false }
        lastError = nil

        GIDSignIn.sharedInstance.signOut()
        // A sign-out that can't reach the server still has to sign you out
        // locally — the alternative is being stuck signed in while offline.
        try? await Supa.client.auth.signOut()
        userID = nil
        profileSyncPending = false
    }

    // MARK: - The exchange

    /// The ONE place the nonce rule is applied. `rawNonce` goes to Supabase;
    /// its sha256 already went to the provider.
    private func completeSignIn(provider: OpenIDConnectCredentials.Provider,
                                idToken: String,
                                accessToken: String?,
                                rawNonce: String,
                                providerName: String) async throws {
        // Banked BEFORE the exchange, and that ordering is the whole point.
        // Apple sends `fullName` on the FIRST authorization for an Apple ID and
        // never again, so a token exchange that times out used to take the name
        // with it permanently. Apple is also the one provider the server cannot
        // cover for: `handle_new_user` seeds `profiles.name` from
        // `raw_user_meta_data->>'full_name'`, which Google's ID token carries
        // and Apple's native one does not.
        adoptProviderName(providerName)

        let credentials = OpenIDConnectCredentials(provider: provider,
                                                   idToken: idToken,
                                                   accessToken: accessToken,
                                                   nonce: rawNonce)
        let session: Session = try await Supa.client.auth.signInWithIdToken(credentials: credentials)
        userID = session.user.id
        await syncProfile(userID: session.user.id)
    }

    /// Take a provider-supplied display name, but only when we have none of our
    /// own: onboarding is skippable (its Continue button is always enabled, and
    /// an empty field is simply never written), and a nameless profile renders
    /// to the entire circle as "Friend".
    private func adoptProviderName(_ offered: String) {
        let trimmed: String = offered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let existing: String = localIdentity().name
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard existing.isEmpty else { return }
        onDisplayName?(trimmed)
    }

    // MARK: - Profile mirror (SPEC-V4 §1)

    /// The launch/foreground entry point: push the profile only when it would
    /// actually change something.
    ///
    /// This is what makes §1's "profile syncs on sign-in" survive the two
    /// things that break it — a sign-in that happened with no signal, and a
    /// name or gender edited in Settings afterwards. Both show up here as a
    /// fingerprint that no longer matches what the last successful write left,
    /// and neither costs a request when nothing has moved.
    func syncProfileIfNeeded(userID: UUID) async {
        let identity: LocalIdentity = localIdentity()
        let current: String = identity.syncFingerprint(userID: userID)
        guard current != AuthService.lastSyncedFingerprint() else {
            profileSyncPending = false
            return
        }
        await syncProfile(userID: userID)
    }

    /// Push the local name/emoji/memberKind up, whatever the fingerprint says.
    /// Non-fatal by design: the person IS signed in by the time this runs, and
    /// failing the whole sign-in over a mirror write would strand them halfway.
    /// `syncProfileIfNeeded(userID:)` is the retry.
    func syncProfile(userID: UUID) async {
        let identity: LocalIdentity = localIdentity()
        do {
            try await AuthService.writeProfile(userID: userID, identity: identity)
            AuthService.rememberSyncedFingerprint(identity.syncFingerprint(userID: userID))
            profileSyncPending = false
        } catch {
            // Forgetting the fingerprint rather than keeping the previous one
            // guarantees the next foreground tries again.
            AuthService.rememberSyncedFingerprint(nil)
            profileSyncPending = true
        }
    }

    /// The fingerprint of the last write the server accepted. `UserDefaults`
    /// rather than `Store`: it is one short string of bookkeeping about the
    /// server, not a piece of the user's data, and it must be readable before
    /// anything else has loaded.
    private static let profileSyncKey: String = "v4.profileSyncedIdentity"

    private static func lastSyncedFingerprint() -> String? {
        UserDefaults.standard.string(forKey: AuthService.profileSyncKey)
    }

    private static func rememberSyncedFingerprint(_ value: String?) {
        if let value {
            UserDefaults.standard.set(value, forKey: AuthService.profileSyncKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AuthService.profileSyncKey)
        }
    }

    /// UPDATE first, INSERT only if nothing matched.
    ///
    /// Not an upsert, and the reason is the grants: `profiles` grants
    /// `insert (id, name, avatar_emoji, avatar_path, member_kind)` but
    /// `update (name, avatar_emoji, avatar_path, member_kind)` — no `id`.
    /// PostgREST's upsert puts every payload column into the
    /// `on conflict do update set` clause, `id` included, which Postgres then
    /// refuses for want of a column privilege. Two verbs, each carrying exactly
    /// the columns it is allowed to carry, is the honest shape. Steady state is
    /// still one round trip: the UPDATE hits.
    private static func writeProfile(userID: UUID, identity: LocalIdentity) async throws {
        let patch = ProfilePatch(name: identity.name,
                                 avatarEmoji: identity.avatarEmoji,
                                 memberKind: identity.memberKind)
        let updateBuilder: PostgrestFilterBuilder = try Supa.client
            .from("profiles")
            .update(patch, returning: .representation)
            .eq("id", value: userID)
        let updated: [RemoteProfile] = try await updateBuilder.execute().value
        if !updated.isEmpty { return }

        let row = RemoteProfile(id: userID,
                                name: identity.name,
                                avatarEmoji: identity.avatarEmoji,
                                memberKind: identity.memberKind)
        do {
            let insertBuilder: PostgrestFilterBuilder = try Supa.client
                .from("profiles")
                .insert(row, returning: .minimal)
            let _: PostgrestResponse<Void> = try await insertBuilder.execute()
        } catch {
            // Another device of ours inserted the row between our UPDATE and
            // our INSERT (23505, unique violation). Their write is ours too —
            // there is nothing here to repair.
            let postgrest = error as? PostgrestError
            if postgrest?.code == "23505" { return }
            throw error
        }
    }

    // MARK: - Small helpers

    /// Apple gives structured name components; the formatter turns them into
    /// whatever "a name" means in the user's locale.
    static func displayName(from components: PersonNameComponents?) -> String {
        guard let components else { return "" }
        let formatter = PersonNameComponentsFormatter()
        formatter.style = .default
        let formatted: String = formatter.string(from: components)
        return formatted.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The view controller Google's sheet should be presented from: the
    /// foreground-active scene's key window, then down any presentation chain
    /// already on screen (the sign-in sheet itself is one).
    static func topViewController() -> UIViewController? {
        guard let scene: UIWindowScene = AuthService.activeWindowScene() else { return nil }
        let keyWindow: UIWindow? = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
        var top: UIViewController? = keyWindow?.rootViewController
        while let presented: UIViewController = top?.presentedViewController {
            top = presented
        }
        return top
    }

    private static func activeWindowScene() -> UIWindowScene? {
        var fallback: UIWindowScene?
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if windowScene.activationState == .foregroundActive {
                return windowScene
            }
            if fallback == nil { fallback = windowScene }
        }
        return fallback
    }
}
