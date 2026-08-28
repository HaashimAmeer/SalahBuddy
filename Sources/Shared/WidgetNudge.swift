import Foundation
import Security

/// v5 §4 (P4) — everything the nudge button needs, on the side of the fence
/// BOTH processes compile.
///
/// The button lives in the widget extension, which compiles four things and not
/// one line of `Sources/Core/Sync/` (§3). It cannot use `Supa.client`, it
/// cannot use `PushRegistrar`, and it must not grow its own copy of either. So
/// the three things it actually does — read the shared session, POST one
/// `notify` body, flip one flag in `widget.json` — live here, next to the file
/// format they operate on, where the app's test target compiles them too.
///
/// **§2 tooth #3 is the rule this file exists to keep: THE EXTENSION NEVER
/// REFRESHES.** Two processes rotating one refresh token invalidate each other
/// — the app signs itself out because the widget spent its token, or the other
/// way round, and the person is signed out by a button they tapped on a home
/// screen. There is therefore no refresh path anywhere below: an expired
/// session means "hand this to the app" (`SharedBackend.nudgeDeepLink`) and
/// nothing else. The only Keychain verb here is READ.
enum SharedSession {

    /// How much life a token needs left before this process will spend it.
    ///
    /// A minute, because the request has to go out, cross a network and be
    /// verified by Supabase's auth server — and the failure mode of guessing
    /// too tight is a deep link into the app, while the failure mode of
    /// guessing too loose is a 401 the person reads as "the button is broken".
    static let freshnessMargin: TimeInterval = 60

    /// What the shared Keychain item holds, as much of it as this side needs.
    ///
    /// It is the Supabase SDK's own `Session`, written by `KeychainLocalStorage`
    /// under `SharedBackend.keychainService` / the storage key. Decoded with
    /// two fields out of nine, tolerantly, because this process must not care
    /// what else the SDK stores there and must not break when it stores more.
    struct Token: Equatable, Sendable {
        var accessToken: String
        /// Seconds since 1970, or nil when the item does not say.
        var expiresAt: Double?

        /// Usable RIGHT NOW, with room to make the call.
        ///
        /// **An item with no expiry reads as EXPIRED**, which is the
        /// conservative direction and a deliberate one: the SDK has always
        /// written `expires_at`, so its absence means the shape has moved under
        /// us, and the two possible mistakes are not symmetric. Treating an
        /// unknown expiry as fresh spends a token that may be dead on a request
        /// nobody can retry and shows a person a button that silently does
        /// nothing; treating it as expired opens the app, where a real client
        /// with a real refresh path sorts it out.
        func isFresh(at now: Date, margin: TimeInterval = SharedSession.freshnessMargin) -> Bool {
            guard !accessToken.isEmpty, let expiresAt else { return false }
            return expiresAt - now.timeIntervalSince1970 > margin
        }
    }

    /// PURE — the decode, so a test can drive every shape without a Keychain.
    static func decode(_ data: Data) -> Token? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any],
              let accessToken = json["access_token"] as? String,
              !accessToken.isEmpty else { return nil }
        // `expires_at` is seconds since 1970. JSONSerialization hands numbers
        // back as NSNumber, so an Int and a Double both arrive here; a string
        // is accepted too rather than dropped, because a value we can read is
        // better than a deep link we did not need.
        let expiresAt: Double?
        if let number = json["expires_at"] as? NSNumber {
            expiresAt = number.doubleValue
        } else if let text = json["expires_at"] as? String {
            expiresAt = Double(text)
        } else {
            expiresAt = nil
        }
        return Token(accessToken: accessToken, expiresAt: expiresAt)
    }

    /// Read the session out of the SHARED access group. Never writes, never
    /// deletes, never refreshes.
    ///
    /// nil is the ordinary answer in four cases and none of them is an error: a
    /// solo user who never signed in, a build with no keychain-sharing
    /// entitlement, a device before first unlock, and a session the app has
    /// already signed out of.
    static func load(service: String = SharedBackend.keychainService,
                     accessGroup: String = SharedBackend.keychainAccessGroup,
                     key: String? = SharedBackend.sessionStorageKey()) -> Token? {
        guard let key else { return nil }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        // NAMED, never omitted. A Keychain query that names no access group
        // SEARCHES every group the process is entitled to — which happens to
        // work here and is exactly the sloppiness `SessionKeychain` documents
        // as having nearly signed everybody out on the app's side.
        query[kSecAttrAccessGroup as String] = accessGroup

        var result: CFTypeRef?
        let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return SharedSession.decode(data)
    }
}

// MARK: - Where a nudge goes

/// Whether this process can send a nudge itself, and if so how.
///
/// **It exists because the answer is decided TWICE and the two have to agree.**
/// `CircleWidgetModel` asks it at render time to choose between a `Button` and a
/// `Link`, and `NudgeSender` asks it again inside `perform()` before it writes
/// anything, because a widget's render is not current: WidgetKit generates and
/// archives entry views when the TIMELINE is produced, and the next entry may be
/// parked at the window's end (`WidgetSnapshot.reloadDate`, up to eight hours
/// out). A Supabase access token lives about one. So the Button on screen at
/// 10:30 was drawn against a token that was fresh at 09:00 and is dead now, and
/// the tap has to find that out before it ticks a chip.
///
/// PURE, so both call sites spend the same function rather than two hand-rolled
/// conditions that drift.
enum NudgeRoute: Equatable {
    /// A real circle and a session this process may spend.
    case remote
    /// Demo or solo: the nudge is real to the person and never leaves the phone.
    ///
    /// §9-03 — "the widget renders the simulated circle too... the widget works
    /// for every solo user from day one" — and `WidgetSnapshotBuilder` fills
    /// `waiting[]` for a demo circle accordingly. A demo user has no account by
    /// definition, so gating the button on a Supabase session would draw a
    /// "Nudge Harun" pill that can only ever bounce a first-run user into the
    /// app, forever. `AppState.sendNudge` in demo mode is itself purely local
    /// (`nudgesSent` + republish, never the network), so the honest thing on
    /// this side is the same: flip the flag and stop.
    case local
    /// Nothing to do here. A real circle whose session is expired, missing, or
    /// unreadable — §2 tooth #3 forbids refreshing it, so this is the app's
    /// business and the tile draws a deep link instead.
    case unavailable

    /// PURE. `token` is whatever `SharedSession.load()` answered — nil included.
    ///
    /// Every caller passes `snapshot?.mode ?? NudgeRoute.modeWithoutAFile`, so
    /// the "there is no `widget.json`" case is decided in one place rather than
    /// three.
    static func decide(mode: CircleMode, token: SharedSession.Token?,
                       at now: Date) -> NudgeRoute {
        if mode == .demo { return .local }
        guard let token, token.isFresh(at: now) else { return .unavailable }
        return .remote
    }

    /// What to assume when `widget.json` is not there at all — a build with no
    /// App Group, or an app that has never run.
    ///
    /// `.real`, which is the CONSERVATIVE direction rather than the likely one.
    /// Two of the three call sites cannot act on it anyway (no file means no
    /// `nudgeTarget` and no flag to write), and the third is the Control, which
    /// has no list to draw and one job left: say "Sign in to nudge" rather than
    /// swallow the tap. Assuming `.demo` there would turn the loudest surface in
    /// the app into a button that does nothing.
    static let modeWithoutAFile: CircleMode = .real

    /// Whether a button (rather than a deep link) is the right thing to draw.
    var canSend: Bool { self != .unavailable }
}

// MARK: - The request

/// The one call the extension makes: `POST functions/v1/notify`, `kind:
/// "nudge"`.
///
/// It is the SAME endpoint and the same body `PushRegistrar.nudge` sends
/// (`NotifyBody`), because it is the same thing happening — the server
/// re-derives the sender from the bearer token, re-checks that the recipient is
/// a circle-mate, and applies §6's one-per-window rate limit. Nothing about
/// this request is trusted; it only says what we are claiming to have done.
enum NudgeRequest {

    /// PURE, so the headers and the body are testable without a network.
    ///
    /// `apikey` as well as `Authorization`: Supabase's edge gateway wants the
    /// publishable key on every call, and the user's JWT is what identifies the
    /// sender. The SDK adds both for the app; here they are written out.
    static func build(memberID: String, dayKey: String, prayer: String,
                      accessToken: String,
                      url: URL = SharedBackend.notifyURL,
                      apiKey: String = SharedBackend.publishableKey) -> URLRequest? {
        guard !memberID.isEmpty, !dayKey.isEmpty, !prayer.isEmpty,
              !accessToken.isEmpty else { return nil }
        let body: [String: String] = [
            "kind": "nudge",
            "recipientId": memberID,
            "dayKey": dayKey,
            "prayer": prayer,
        ]
        guard let data: Data = try? JSONSerialization.data(withJSONObject: body,
                                                           options: [.sortedKeys])
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        // An intent gets a few seconds of wall clock at most, and a nudge whose
        // moment has passed is not worth a queue (`NotifyOutcome.failed` says
        // the same thing on the app's side).
        request.timeoutInterval = 10
        return request
    }

    /// Whether a `notify` reply means the nudge landed.
    ///
    /// `rate_limited` counts as YES, exactly as `PushRegistrar.outcome` reads
    /// it: you already nudged them for this window, the chip already says
    /// "Nudged", and a second tap must not un-tick it. The reply is decoded
    /// loosely on purpose — the endpoint grows fields, and a field this build
    /// has never heard of is not a failure.
    ///
    /// **This is `NudgeSender`'s reconciliation predicate, not decoration.** The
    /// optimistic tick goes into `widget.json` before the request (§4), so a
    /// reply of 401 (a rotated refresh, a revoked session) or 500 would
    /// otherwise leave a chip reading "Nudged" forever for somebody who received
    /// nothing — and `nextNudgeTarget` would skip past them until the app
    /// published a CHANGED snapshot. `false` here un-ticks it.
    ///
    /// One consequence, taken deliberately: a 2xx that says
    /// `{"sent":false,"reason":"not_sent"}` — the recipient has no registered
    /// device — reads as NOT landed and un-ticks too, even though the server
    /// recorded the nudge. The second tap then answers `rate_limited` and ticks
    /// for good. One extra tap in the rare case is the cheaper mistake: the
    /// alternative is a widget that cannot tell "nobody was reached" from
    /// "everything worked".
    static func landed(status: Int, body: Data?) -> Bool {
        guard (200 ..< 300).contains(status) else { return false }
        guard let body,
              let object = try? JSONSerialization.jsonObject(with: body),
              let json = object as? [String: Any] else { return true }
        if let sent = json["sent"] as? Bool, sent { return true }
        let reason: String? = json["reason"] as? String
        return reason == "rate_limited"
    }
}

// MARK: - The optimistic write (v5 §4)

extension WidgetSnapshot {

    /// This snapshot with one person marked as nudged for this window.
    ///
    /// PURE. §4: "the intent runs headless; write the new state into the
    /// container inside `perform()` before returning so the reload renders it."
    /// This is that new state, and the write is `WidgetFile.markNudged`.
    ///
    /// Only `waiting[].nudgedThisWindow` moves. Not the counts — nudging
    /// somebody is not praying for them — and not `posts`, which is the tile's
    /// picture of a window nothing here has changed.
    ///
    /// - Parameter nudged: false RETRACTS the tick. That direction exists
    ///   because the write is optimistic and the reply can say it should not
    ///   have been (`NudgeRequest.landed`); without it a 401 leaves a chip
    ///   claiming a nudge that never went, and the button skipping the person it
    ///   was aimed at.
    func markingNudged(memberID: String, nudged: Bool = true) -> WidgetSnapshot {
        guard !memberID.isEmpty else { return self }
        var copy: WidgetSnapshot = self
        copy.circle.waiting = circle.waiting.map { person in
            guard person.userID == memberID else { return person }
            var marked: WidgetSnapshot.Waiting = person
            marked.nudgedThisWindow = nudged
            return marked
        }
        return copy
    }

    /// Whether this file is still about the window a nudge was aimed at.
    ///
    /// The app republishes `widget.json` on every change, so between the
    /// optimistic write and the reply the file may have moved on to the next
    /// prayer entirely. Retracting a tick then would edit a window nothing was
    /// nudged in.
    func isAbout(dayKey: String, prayer: String) -> Bool {
        guard let window else { return false }
        return window.dayKey == dayKey && window.prayer.rawValue == prayer
    }

    /// Who this window's nudge button should be aimed at: the first person in
    /// `waiting` who has not been nudged yet.
    ///
    /// `waiting` is already the NUDGE list rather than "everybody who has not
    /// posted" — it carries the Today screen's own gate
    /// (`WidgetSnapshotBuilder.nudgesAllowed`: the window must be open, thirty
    /// minutes in, and never the carry-over isha), so this does no gating of
    /// its own and must not: two surfaces deciding who is late is two surfaces
    /// that can disagree.
    var nextNudgeTarget: WidgetSnapshot.Waiting? {
        circle.waiting.first(where: { !$0.nudgedThisWindow })
    }
}

extension WidgetFile {

    /// Read `widget.json`, mark one person nudged, write it back.
    ///
    /// **The extension is the only thing that ever calls this, and it is the
    /// only write the extension is allowed to make.** `widget.json` has one
    /// writer (`AppState.publishWidgetSnapshot`) and that has not changed for
    /// anything the file MEANS — this flips a single optimistic flag so the
    /// tile can settle the instant the button is tapped, and the app's next
    /// publish is authoritative over it.
    ///
    /// A read-modify-write, so it can lose a race with the app publishing at
    /// the same instant. That is the right trade: the value at stake is one
    /// session-scoped tick, the server's rate limit is the real one-per-window
    /// guarantee, and the alternative (a lock, or a second file) is machinery
    /// for a flag whose worst failure is a button that has to be looked at
    /// twice.
    @discardableResult
    static func markNudged(memberID: String, nudged: Bool = true,
                           at url: URL? = WidgetFile.url) -> Bool {
        guard let url, let snapshot: WidgetSnapshot = WidgetFile.read(at: url) else {
            return false
        }
        let marked: WidgetSnapshot = snapshot.markingNudged(memberID: memberID,
                                                            nudged: nudged)
        guard !marked.hasSameContent(as: snapshot) else { return false }
        return WidgetFile.write(marked, to: url)
    }

    /// Take a tick back, but only while the file is still about the window it
    /// was put there for — see `WidgetSnapshot.isAbout(dayKey:prayer:)`.
    @discardableResult
    static func retractNudge(memberID: String, dayKey: String, prayer: String,
                             at url: URL? = WidgetFile.url) -> Bool {
        guard let url, let snapshot: WidgetSnapshot = WidgetFile.read(at: url),
              snapshot.isAbout(dayKey: dayKey, prayer: prayer) else { return false }
        return WidgetFile.markNudged(memberID: memberID, nudged: false, at: url)
    }
}
