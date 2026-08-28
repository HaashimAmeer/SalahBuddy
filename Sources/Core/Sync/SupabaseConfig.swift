import Foundation
import GoogleSignIn
import Supabase

/// v4 backend configuration.
///
/// Both values below are **publishable** config, not secrets — they ship in
/// every copy of the binary and are meant to be public. The security boundary
/// is row-level security in Postgres (see `backend/supabase/migrations/`), not
/// the key: with only this key and no user session you can read nothing.
/// That's why they can live in a public repo.
enum SupabaseConfig {

    /// v5 §4 (P4): both live in `SharedBackend` now. The widget's nudge button
    /// POSTs to the same project with the same key and cannot compile this file
    /// (it imports `Supabase` and `GoogleSignIn`), and a project URL spelled in
    /// two places is a widget quietly nudging into a project the app has moved
    /// off — a failure indistinguishable from a network error.
    static let url = SharedBackend.url

    /// New-format publishable key (`sb_publishable_…`), not a legacy anon JWT.
    static let publishableKey = SharedBackend.publishableKey

    /// Private Storage bucket holding circle photos, keyed
    /// `<circle_id>/<user_id>/<uuid>.jpg` (SPEC-V4 §4).
    static let photoBucket = "prayer-photos"

    /// Google's iOS OAuth client id. Also declared as `GIDClientID` in
    /// `project.yml` so the SDK can self-configure from the bundle.
    static let googleClientID =
        "923951498597-445nb4q5o5k66imnbbul70h88s7bct72.apps.googleusercontent.com"
}

/// The one shared Supabase client. Created lazily so a solo user who never
/// touches the social boundary never pays for it.
///
/// v5 §2: the session lives in the SHARED keychain access group, because a
/// widget extension is a different process and the SDK's default storage — no
/// access group, so this process's own — is invisible to it (§4, the nudge
/// button).
///
/// The adoption runs inside this initialiser rather than from the launch
/// sequence, and that placement is the safety argument: `static let` is
/// evaluated exactly once, before the value exists, so there is no order of
/// calls anywhere in the app that can reach a client whose session has not been
/// carried over yet. A launch-sequence call would work today and rot the first
/// time something touched `Supa.client` a line earlier.
enum Supa {
    static let client: SupabaseClient = {
        SessionKeychain.adoptLegacySessionIfNeeded()
        return SupabaseClient(
            supabaseURL: SupabaseConfig.url,
            supabaseKey: SupabaseConfig.publishableKey,
            options: SupabaseClientOptions(
                auth: SupabaseClientOptions.AuthOptions(
                    storage: KeychainLocalStorage(
                        service: SessionKeychain.service,
                        accessGroup: SharedContainer.keychainAccessGroup))))
    }()
}

/// Google's SDK reads `GIDClientID` from Info.plist on first use, but only if
/// nothing configured it first — so we set it explicitly and idempotently
/// rather than depending on load order.
enum GoogleAuthConfig {
    static func applyIfNeeded() {
        guard GIDSignIn.sharedInstance.configuration == nil else { return }
        GIDSignIn.sharedInstance.configuration =
            GIDConfiguration(clientID: SupabaseConfig.googleClientID)
    }
}
