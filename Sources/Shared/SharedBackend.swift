import Foundation

/// v5 §4 (P4) — the handful of backend facts BOTH processes need.
///
/// The widget extension compiles four things (`project.yml`), and
/// `SupabaseConfig.swift` is not one of them: it imports `Supabase` and
/// `GoogleSignIn`, which is most of the app's dependency graph and exactly what
/// §3 keeps out of the extension. But P4's nudge button has to reach the same
/// project, with the same publishable key, holding a session out of the same
/// keychain group — so those strings have to be sayable from both sides.
///
/// **One spelling, and the APP reads it from here rather than the other way
/// round** — the same arrangement `WidgetFile.appGroupID` already has with
/// `SharedContainer`. `SupabaseConfig`, `SessionKeychain` and `SharedContainer`
/// all now derive from this file. A project URL that lived in two places would
/// mean a widget silently POSTing a nudge at a project the app has moved off,
/// and the failure would look like an ordinary network error.
///
/// Everything here is **publishable config, not a secret** (see
/// `SupabaseConfig`): it ships in every copy of the binary and is meant to be
/// public. The security boundary is row-level security in Postgres, which is
/// why this can live in a public repo.
enum SharedBackend {

    // MARK: - The project

    static let urlString: String = "https://rmyygmyxppmnzcnvprvb.supabase.co"

    static let url: URL = URL(string: SharedBackend.urlString)!

    /// New-format publishable key (`sb_publishable_…`), not a legacy anon JWT.
    static let publishableKey: String = "sb_publishable_CDUUDqJc8edrT92QIIq8FA_sYz1ut3Q"

    /// The `notify` edge function — the one endpoint the extension calls.
    /// Everything else the widget needs is already on disk.
    static var notifyURL: URL {
        SharedBackend.url.appendingPathComponent("functions/v1/notify")
    }

    // MARK: - The session (v5 §2)

    /// The Keychain service `KeychainLocalStorage` namespaces items under — the
    /// SDK's own default, restated because both processes have to address the
    /// very items the SDK writes.
    static let keychainService: String = "supabase.gotrue.swift"

    /// The SHARED access group, `<TeamID>.group.…` (§2). The app writes the
    /// session here; the extension reads it and NEVER refreshes it (§2 tooth
    /// #3 — two processes rotating one refresh token invalidate each other).
    static let keychainAccessGroup: String =
        "852AXZ2B57.group.org.amacvoters.salahbuddymock"

    /// Where v4 left it: the app's own app-identifier group, invisible to any
    /// other process. Read once and re-stored by `SessionKeychain`.
    static let legacyKeychainAccessGroup: String =
        "852AXZ2B57.org.amacvoters.salahbuddymock"

    /// PURE. The storage key `SupabaseClient` derives from the project URL:
    /// `sb-<project ref>-auth-token`. Recomputed from the same URL rather than
    /// hard-coded, so a project change moves both sides at once.
    ///
    /// Answers nil for a URL with no host — which `SupabaseClient` treats as
    /// fatal, and which every caller here treats as "then there is nothing to
    /// read".
    static func sessionStorageKey(forProjectURL url: URL = SharedBackend.url) -> String? {
        guard let host: String = url.host(percentEncoded: false),
              let reference: Substring = host.split(separator: ".").first,
              !reference.isEmpty else { return nil }
        return "sb-\(reference)-auth-token"
    }

    // MARK: - The deep link (v5 §2 tooth #3, §4)

    /// The app's own URL scheme, declared in `project.yml`'s
    /// `CFBundleURLTypes`.
    ///
    /// It exists for ONE case, and it is the case §2 tooth #3 is about: the
    /// extension holds a session it may not refresh, and an expired one means
    /// "hand this to the app", never "refresh it myself". A widget cannot open
    /// a sheet, so handing over is a URL.
    static let urlScheme: String = "salahbuddy"

    /// `salahbuddy://nudge?member=…&prayer=…&dayKey=…`
    ///
    /// The parameters are what the Today screen needs to put the person in
    /// front of you; every one of them is already in `widget.json`, so nothing
    /// crosses here that the extension did not already hold. `member` is a
    /// circle member id, never a name.
    static func nudgeDeepLink(memberID: String?, prayer: String?, dayKey: String?) -> URL? {
        var components = URLComponents()
        components.scheme = SharedBackend.urlScheme
        components.host = "nudge"
        var items: [URLQueryItem] = []
        if let memberID, !memberID.isEmpty { items.append(URLQueryItem(name: "member", value: memberID)) }
        if let prayer, !prayer.isEmpty { items.append(URLQueryItem(name: "prayer", value: prayer)) }
        if let dayKey, !dayKey.isEmpty { items.append(URLQueryItem(name: "dayKey", value: dayKey)) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }

    /// The inverse, for the app's `.onOpenURL`. nil for anything that is not
    /// ours — Google's OAuth callback comes back through the same door.
    static func nudgeDeepLinkTarget(_ url: URL)
        -> (memberID: String?, prayer: String?, dayKey: String?)? {
        guard url.scheme?.lowercased() == SharedBackend.urlScheme,
              url.host?.lowercased() == "nudge" else { return nil }
        let items: [URLQueryItem] = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems ?? []
        func value(_ name: String) -> String? {
            let found: String? = items.first(where: { $0.name == name })?.value
            return (found?.isEmpty ?? true) ? nil : found
        }
        return (value("member"), value("prayer"), value("dayKey"))
    }
}
