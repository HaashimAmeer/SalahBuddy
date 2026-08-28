import XCTest
import UserNotifications
@testable import SalahBuddy

// MARK: - Stubs

/// The phone, without a phone. Every branch `PushRegistrar` cares about —
/// never asked, already authorised, denied, notifications switched off — is a
/// field on this object.
@MainActor
private final class StubPushSystem: PushSystem {
    var status: UNAuthorizationStatus = .notDetermined
    /// What the person taps on the system sheet.
    var grants: Bool = true

    var authorizationRequests: Int = 0
    var registrations: Int = 0
    var preferencesValue: PushPreferences =
        PushPreferences(notificationsEnabled: true, friendActivity: false)
    /// Stands in for `UserDefaults`, so no test leaves a fingerprint behind for
    /// the next one to trip over.
    var stored: String?
    /// The other half of that store: a `devices` row this phone owes the server
    /// a delete for, which has to survive the launch that could not send it.
    var owedDelete: String?

    func authorizationStatus() async -> UNAuthorizationStatus { status }

    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        status = grants ? .authorized : .denied
        return grants
    }

    func registerForRemoteNotifications() { registrations += 1 }

    func preferences() -> PushPreferences { preferencesValue }

    func lastRegistration() -> String? { stored }

    func rememberRegistration(_ fingerprint: String?) { stored = fingerprint }

    func pendingDelete() -> String? { owedDelete }

    func rememberPendingDelete(_ token: String?) { owedDelete = token }
}

@MainActor
private final class StubPushTransport: PushTransport {
    /// Every `register_device` call, in order.
    var upserts: [RemoteDevice] = []
    var deletes: [String] = []
    var bodies: [NotifyBody] = []

    /// v5 §6: every `register_live_activity_token` call, and every token this
    /// device asked the server to forget.
    var liveActivityRegistrations: [LiveActivityRegistration] = []
    var liveActivityDeletes: [String] = []

    var reply: NotifyReply = NotifyReply(ok: true, kind: nil, sent: true, reason: nil)
    var upsertError: (any Error)?
    var deleteError: (any Error)?
    var notifyError: (any Error)?
    var liveActivityError: (any Error)?

    func registerDevice(_ device: RemoteDevice) async throws {
        if let upsertError { throw upsertError }
        upserts.append(device)
    }

    func deleteDevice(token: String) async throws {
        if let deleteError { throw deleteError }
        deletes.append(token)
    }

    func notify(_ body: NotifyBody) async throws -> NotifyReply {
        bodies.append(body)
        if let notifyError { throw notifyError }
        return reply
    }

    func registerLiveActivityToken(_ registration: LiveActivityRegistration) async throws {
        if let liveActivityError { throw liveActivityError }
        liveActivityRegistrations.append(registration)
    }

    func deleteLiveActivityToken(token: String) async throws {
        if let liveActivityError { throw liveActivityError }
        liveActivityDeletes.append(token)
    }
}

private struct StubFailure: Error {}

// MARK: - Tests

/// v4 Phase D §6: push registration and the three `notify` calls.
///
/// Everything here runs without a device, a network or a signed-in user: the
/// policy sits above two seams (`PushSystem`, `PushTransport`) precisely so the
/// awkward cases — a solo user, a denied prompt, a token that changes hands —
/// are ordinary unit tests rather than things you find out about on a phone.
@MainActor
final class PushRegistrarTests: XCTestCase {

    private let me: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let friend: UUID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let postID: UUID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let token: String = "a1b2c3"
    private let monday: String = "2026-06-08"

    /// One phone, one network, one registrar. Built per test rather than in a
    /// `setUp` override: this class is `@MainActor` and `XCTestCase`'s hooks
    /// are not, and a fresh rig per test is what keeps the fingerprint left by
    /// one test out of the next one anyway.
    private typealias Rig = (system: StubPushSystem, transport: StubPushTransport,
                             push: PushRegistrar)

    private func makeRig(online: Bool = true) -> Rig {
        let system = StubPushSystem()
        let transport = StubPushTransport()
        let network: Reachability = Reachability()
        network.setOnline(online)
        let push = PushRegistrar(transport: transport, system: system, reachability: network)
        return (system: system, transport: transport, push: push)
    }

    /// A rig that has already been through the whole handshake.
    private func registeredRig() async -> Rig {
        let rig: Rig = makeRig()
        rig.system.status = .authorized
        await rig.push.refresh(userID: me, hasCircle: true)
        await rig.push.adoptDeviceToken(token)
        return rig
    }

    // MARK: - The APNs environment

    func testEnvironmentIsSandboxForADebugBuildAndProductionOtherwise() {
        XCTAssertEqual(APNsEnvironment.name(debugBuild: true), "sandbox")
        // TestFlight archives are Release builds and talk to PRODUCTION APNs —
        // the whole reason the line is drawn at `#if DEBUG`.
        XCTAssertEqual(APNsEnvironment.name(debugBuild: false), "production")
    }

    func testTheShippedEnvironmentMatchesThisBuildConfig() {
        #if DEBUG
        XCTAssertEqual(APNsEnvironment.current, "sandbox")
        #else
        XCTAssertEqual(APNsEnvironment.current, "production")
        #endif
    }

    func testTheEnvironmentTravelsInTheDeviceRow() async {
        let rig: Rig = await registeredRig()
        XCTAssertEqual(rig.transport.upserts.first?.environment, APNsEnvironment.current)
    }

    func testTheDeviceTokenIsLowercaseHex() {
        let data = Data([0x00, 0x0f, 0xa1, 0xff])
        XCTAssertEqual(PushRegistrar.hexToken(from: data), "000fa1ff")
    }

    // MARK: - The notify bodies

    /// The keys are camelCase and are read by `_shared/validate.ts`, not by
    /// PostgREST — so these assertions are the contract with that file.
    private func wireBody(_ body: NotifyBody) throws -> [String: Any] {
        // A plain `JSONEncoder` is exactly what `FunctionInvokeOptions` uses.
        let data: Data = try JSONEncoder().encode(body)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    func testPostBodyIsTheKindAndThePostID() throws {
        let body: [String: Any] = try wireBody(.post(postID))
        XCTAssertEqual(Set(body.keys), ["kind", "postId"])
        XCTAssertEqual(body["kind"] as? String, "post")
        let sentID: String? = body["postId"] as? String
        XCTAssertEqual(sentID?.lowercased(), postID.uuidString.lowercased())
    }

    func testJoinBodyCarriesNothingButItsKind() throws {
        let body: [String: Any] = try wireBody(NotifyBody.join)
        XCTAssertEqual(Set(body.keys), ["kind"])
        XCTAssertEqual(body["kind"] as? String, "join")
    }

    func testNudgeBodyCarriesRecipientDayKeyAndPrayer() throws {
        let body: [String: Any] = try wireBody(
            .nudge(recipientID: friend, dayKey: monday, prayer: .maghrib))
        XCTAssertEqual(Set(body.keys), ["kind", "recipientId", "dayKey", "prayer"])
        XCTAssertEqual(body["kind"] as? String, "nudge")
        let sentID: String? = body["recipientId"] as? String
        XCTAssertEqual(sentID?.lowercased(), friend.uuidString.lowercased())
        XCTAssertEqual(body["dayKey"] as? String, monday)
        // The rawValue, which IS the `prayer_kind` label and the string
        // `validate.ts` accepts.
        XCTAssertEqual(body["prayer"] as? String, "maghrib")
    }

    func testTheThreeCallsSendTheirOwnKind() async {
        let rig: Rig = await registeredRig()
        await rig.push.announcePost(postID: postID)
        await rig.push.announceJoin()
        await rig.push.nudge(recipientID: friend, dayKey: monday, prayer: .fajr)
        XCTAssertEqual(rig.transport.bodies.map(\.kind), ["post", "join", "nudge"])
        XCTAssertEqual(rig.transport.bodies.first?.postID, postID)
        XCTAssertEqual(rig.transport.bodies.last?.recipientID, friend)
    }

    // MARK: - What a reply means

    func testRateLimitedReadsAsAlreadyNudged() async {
        let rig: Rig = await registeredRig()
        rig.transport.reply = NotifyReply(ok: true, kind: "nudge", sent: false,
                                          reason: "rate_limited")
        let outcome: NotifyOutcome = await rig.push.nudge(recipientID: friend, dayKey: monday,
                                                          prayer: .isha)
        XCTAssertEqual(outcome, .alreadyNudged)
        // The whole point: the chip already says "Nudged ✓", and this must not
        // turn that into an error.
        XCTAssertFalse(outcome.isFailure)
    }

    func testADeliveredNudgeReadsAsSent() async {
        let rig: Rig = await registeredRig()
        rig.transport.reply = NotifyReply(ok: true, kind: "nudge", sent: true, reason: nil)
        let outcome: NotifyOutcome = await rig.push.nudge(recipientID: friend, dayKey: monday,
                                                          prayer: .isha)
        XCTAssertEqual(outcome, .sent)
    }

    /// The nudge reply says only whether the push went — the device counts are
    /// a fact about one named person. "Recorded, nobody listening" is still not
    /// a failure.
    func testAFriendWithNoRegisteredDeviceIsNotAFailure() {
        let reply = NotifyReply(ok: true, kind: "nudge", sent: false, reason: nil)
        XCTAssertEqual(PushRegistrar.outcome(from: reply), .skipped(reason: "not_sent"))
        XCTAssertFalse(PushRegistrar.outcome(from: reply).isFailure)
    }

    func testAServerSkipIsReportedWithItsReason() {
        let reply = NotifyReply(ok: true, kind: "post", sent: false, reason: "not_first")
        XCTAssertEqual(PushRegistrar.outcome(from: reply), .skipped(reason: "not_first"))
    }

    /// The function grew delivery counters after this shipped; a reply carrying
    /// fields this build has never heard of must still decode.
    func testAReplyWithUnknownFieldsStillDecodes() throws {
        let raw = Data(#"{"ok":true,"kind":"post","sent":true,"devices":3,"delivered":2}"#.utf8)
        let reply: NotifyReply = try JSONDecoder().decode(NotifyReply.self, from: raw)
        XCTAssertTrue(reply.sent)
        XCTAssertEqual(PushRegistrar.outcome(from: reply), .sent)
    }

    func testANotifyFailureNeverThrowsAtTheCallSite() async {
        let rig: Rig = await registeredRig()
        rig.transport.notifyError = StubFailure()
        let outcome: NotifyOutcome = await rig.push.announcePost(postID: postID)
        XCTAssertEqual(outcome, .failed)
    }

    // MARK: - Solo and demo (SPEC-V4 §1)

    func testSoloIsNeverAskedForPushPermission() async {
        let rig: Rig = makeRig()
        await rig.push.refresh(userID: nil, hasCircle: false)
        // Signed in, but no circle — still nothing to be notified about.
        await rig.push.refresh(userID: me, hasCircle: false)
        XCTAssertEqual(rig.system.authorizationRequests, 0)
        XCTAssertEqual(rig.system.registrations, 0)
        XCTAssertTrue(rig.transport.upserts.isEmpty)
        XCTAssertFalse(rig.push.isInRealCircle)
    }

    func testDemoModeNeverReachesTheNetworkToNudge() async {
        let rig: Rig = makeRig()
        await rig.push.refresh(userID: nil, hasCircle: false)
        let outcome: NotifyOutcome = await rig.push.nudge(recipientID: friend, dayKey: monday,
                                                          prayer: .asr)
        XCTAssertEqual(outcome, .skipped(reason: PushRegistrar.noCircleReason))
        XCTAssertTrue(rig.transport.bodies.isEmpty)
    }

    func testASimulatedBuddyIsNudgedLocallyAndOnlyLocally() async {
        let rig: Rig = await registeredRig()
        let buddy = CircleMember(id: "Yusuf", name: "Yusuf", emoji: "🧕", isYou: false)
        let outcome: NotifyOutcome = await rig.push.nudge(member: buddy, dayKey: monday,
                                                          prayer: .asr)
        XCTAssertEqual(outcome, .skipped(reason: PushRegistrar.simulatedMemberReason))
        XCTAssertTrue(rig.transport.bodies.isEmpty)
    }

    func testYouCannotNudgeYourself() async {
        let rig: Rig = await registeredRig()
        let you = CircleMember(id: me.uuidString, name: "You", emoji: "😄", isYou: true)
        let outcome: NotifyOutcome = await rig.push.nudge(member: you, dayKey: monday, prayer: .asr)
        XCTAssertEqual(outcome, .skipped(reason: PushRegistrar.simulatedMemberReason))
        XCTAssertTrue(rig.transport.bodies.isEmpty)
    }

    func testARealMemberIsNudgedOverTheWire() async {
        let rig: Rig = await registeredRig()
        let member = CircleMember(id: friend.uuidString, name: "Mina", emoji: "🌙", isYou: false)
        await rig.push.nudge(member: member, dayKey: monday, prayer: .asr)
        XCTAssertEqual(rig.transport.bodies.first?.recipientID, friend)
    }

    // MARK: - Registration

    func testARealCircleAsksOnceAndRegistersTheToken() async {
        let rig: Rig = makeRig()
        await rig.push.refresh(userID: me, hasCircle: true)
        XCTAssertEqual(rig.system.authorizationRequests, 1)
        XCTAssertEqual(rig.system.registrations, 1)
        // Nothing to write yet: iOS answers with the token afterwards.
        XCTAssertTrue(rig.transport.upserts.isEmpty)

        await rig.push.adoptDeviceToken(token)
        XCTAssertEqual(rig.transport.upserts.count, 1)
        XCTAssertEqual(rig.transport.upserts.first?.userID, me)
        XCTAssertEqual(rig.transport.upserts.first?.apnsToken, token)
        XCTAssertTrue(rig.push.isRegistered)
    }

    func testAnAlreadyAuthorisedUserIsNotAskedAgain() async {
        let rig: Rig = makeRig()
        rig.system.status = .authorized
        await rig.push.refresh(userID: me, hasCircle: true)
        // The usual case: onboarding already asked, for prayer reminders.
        XCTAssertEqual(rig.system.authorizationRequests, 0)
        XCTAssertEqual(rig.system.registrations, 1)
    }

    func testADeniedUserIsNeverAskedAgainAndWritesNoRow() async {
        let rig: Rig = makeRig()
        rig.system.status = .denied
        await rig.push.refresh(userID: me, hasCircle: true)
        await rig.push.adoptDeviceToken(token)
        XCTAssertEqual(rig.system.authorizationRequests, 0)
        XCTAssertEqual(rig.system.registrations, 0)
        XCTAssertTrue(rig.transport.upserts.isEmpty)
    }

    /// The other half of the same door. iOS answers with the token
    /// ASYNCHRONOUSLY, so it can land after the master switch went off and the
    /// row came down — and writing it again there would put back the row
    /// `refresh`/`preferencesChanged` had just deleted.
    func testATokenArrivingAfterTheMasterSwitchWentOffWritesNoRow() async {
        let rig: Rig = makeRig()
        rig.system.status = .authorized
        rig.system.preferencesValue = PushPreferences(notificationsEnabled: false,
                                                      friendActivity: false)
        await rig.push.refresh(userID: me, hasCircle: true)
        await rig.push.adoptDeviceToken(token)
        XCTAssertTrue(rig.transport.upserts.isEmpty)
        XCTAssertFalse(rig.push.isRegistered)
    }

    /// Declining the prompt stops us RECEIVING. It does not stop us sending —
    /// a nudge is a message to somebody else's phone.
    func testDecliningThePromptStillLetsYouNudge() async {
        let rig: Rig = makeRig()
        rig.system.grants = false
        await rig.push.refresh(userID: me, hasCircle: true)
        XCTAssertEqual(rig.system.authorizationRequests, 1)
        XCTAssertTrue(rig.transport.upserts.isEmpty)
        await rig.push.nudge(recipientID: friend, dayKey: monday, prayer: .fajr)
        XCTAssertEqual(rig.transport.bodies.count, 1)
    }

    func testTheSameTokenReRegisteringIsOneWrite() async {
        let rig: Rig = await registeredRig()
        // Relaunch, foreground, relaunch: iOS hands back the same token every
        // time, and the row already says all of this.
        await rig.push.adoptDeviceToken(token)
        await rig.push.refresh(userID: me, hasCircle: true)
        XCTAssertEqual(rig.transport.upserts.count, 1)
    }

    /// `devices.apns_token` is the primary key and `user_id` is inside the
    /// UPDATE grant, so the row FOLLOWS the token: one phone, one row, whoever
    /// is signed in on it.
    func testATokenThatMovesToAnotherUserRewritesTheSameRow() async {
        let rig: Rig = await registeredRig()
        await rig.push.refresh(userID: friend, hasCircle: true)

        XCTAssertEqual(rig.transport.upserts.count, 2)
        XCTAssertEqual(rig.transport.upserts.last?.userID, friend)
        XCTAssertEqual(rig.transport.upserts.last?.apnsToken, token)
    }

    func testAFailedWriteIsOwedARetryNextTime() async {
        let rig: Rig = makeRig()
        rig.system.status = .authorized
        rig.transport.upsertError = StubFailure()
        await rig.push.refresh(userID: me, hasCircle: true)
        await rig.push.adoptDeviceToken(token)
        XCTAssertFalse(rig.push.isRegistered)
        XCTAssertNil(rig.system.stored)

        rig.transport.upsertError = nil
        await rig.push.refresh(userID: me, hasCircle: true)
        XCTAssertEqual(rig.transport.upserts.count, 1)
        XCTAssertTrue(rig.push.isRegistered)
    }

    func testFriendActivityTravelsInTheRow() async {
        let rig: Rig = makeRig()
        rig.system.status = .authorized
        rig.system.preferencesValue = PushPreferences(notificationsEnabled: true,
                                                      friendActivity: true)
        await rig.push.refresh(userID: me, hasCircle: true)
        await rig.push.adoptDeviceToken(token)
        XCTAssertEqual(rig.transport.upserts.first?.notifyFriendActivity, true)

        // Flipping it is a change the server has to hear about.
        rig.system.preferencesValue = PushPreferences(notificationsEnabled: true,
                                                      friendActivity: false)
        await rig.push.refresh(userID: me, hasCircle: true)
        XCTAssertEqual(rig.transport.upserts.count, 2)
        XCTAssertEqual(rig.transport.upserts.last?.notifyFriendActivity, false)
    }

    // MARK: - The zone the device is standing in (v4 Phase 2, §6)

    /// `notify` decides whether a post's `day_key` is still the recipient's
    /// current local day, and the ONLY thing that tells it where a recipient is
    /// standing is this column. A row without it is a member who gets a 5am
    /// Mumbai Fajr at 4:30pm in Seattle.
    func testTheZoneTravelsInTheDeviceRow() async {
        let rig: Rig = await registeredRig()
        XCTAssertEqual(rig.transport.upserts.first?.utcOffset, AppClock.utcOffsetSeconds)
    }

    /// The wire contract with `public.register_device(..., p_utc_offset int)`
    /// (`20260822000500_device_utc_offset.sql`). Snake-cased params, all four
    /// present — the three-argument overload was DROPPED by that migration, so
    /// a body that omits the key is not a supported shape for this build.
    func testTheRegisterParamsMatchTheRPCSignature() throws {
        let device = RemoteDevice(userID: me, apnsToken: token,
                                  environment: APNsEnvironment.production,
                                  notifyFriendActivity: true,
                                  utcOffset: -25_200)
        let data: Data = try JSONEncoder().encode(device.registerParams)
        let object = try JSONSerialization.jsonObject(with: data)
        let body: [String: Any] = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(Set(body.keys),
                       ["p_token", "p_environment", "p_friend_activity", "p_utc_offset"])
        XCTAssertEqual(body["p_utc_offset"] as? Int, -25_200)
    }

    /// Seconds, signed, east-positive — the same unit and sign as
    /// `posts.utc_offset` and `PrayerLog.utcOffset`. A half-hour zone survives
    /// intact, because fifteen minutes of offset can decide which calendar day
    /// a device is on and the server compares dates.
    func testAHalfHourZoneIsCarriedExactly() throws {
        let mumbai: Int = 5 * 3600 + 30 * 60
        let device = RemoteDevice(userID: me, apnsToken: token,
                                  environment: APNsEnvironment.production,
                                  notifyFriendActivity: false, utcOffset: mumbai)
        let data: Data = try JSONEncoder().encode(device.registerParams)
        let object = try JSONSerialization.jsonObject(with: data)
        let body: [String: Any] = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(body["p_utc_offset"] as? Int, 19_800)
    }

    /// The fingerprint is what decides whether a foreground costs a round trip.
    /// The zone is the one field that changes when the PERSON changed nothing,
    /// so it has to be in there — otherwise a traveller keeps their departure
    /// offset until they happen to flip a setting.
    func testTheFingerprintNoticesAZoneChange() {
        func device(offset: Int) -> RemoteDevice {
            RemoteDevice(userID: me, apnsToken: token,
                         environment: APNsEnvironment.production,
                         notifyFriendActivity: false, utcOffset: offset)
        }
        XCTAssertEqual(device(offset: -25_200).fingerprint, device(offset: -25_200).fingerprint)
        XCTAssertNotEqual(device(offset: -25_200).fingerprint, device(offset: 19_800).fingerprint)
        // UTC+0 is a real place, not a stand-in for "unknown", so it has to be
        // a distinct fingerprint from every other zone.
        XCTAssertNotEqual(device(offset: 0).fingerprint, device(offset: 3600).fingerprint)
    }

    /// The traveller, end to end: a fingerprint left behind by the departure
    /// zone must NOT be mistaken for "the server already knows this".
    ///
    /// `refresh` runs on every foreground, which is the moment somebody who has
    /// just landed opens the app — so this is the whole re-registration path,
    /// and a stale offset on the server means the circle's pushes are filtered
    /// away from a member who is wide awake.
    func testLandingInANewZoneRewritesTheRow() async {
        let rig: Rig = makeRig()
        rig.system.status = .authorized
        // What the last launch, half a world away, would have persisted.
        let departure = RemoteDevice(userID: me, apnsToken: token,
                                     environment: APNsEnvironment.current,
                                     notifyFriendActivity: false,
                                     utcOffset: AppClock.utcOffsetSeconds + 8 * 3600)
        rig.system.stored = departure.fingerprint

        await rig.push.refresh(userID: me, hasCircle: true)
        await rig.push.adoptDeviceToken(token)

        XCTAssertEqual(rig.transport.upserts.count, 1)
        XCTAssertEqual(rig.transport.upserts.last?.utcOffset, AppClock.utcOffsetSeconds)
        XCTAssertTrue(rig.push.isRegistered)
    }

    /// ...and the converse, because the fingerprint's whole job is to make the
    /// common case free: standing still costs no round trip.
    func testStayingPutCostsNoRoundTrip() async {
        let rig: Rig = makeRig()
        rig.system.status = .authorized
        let here = RemoteDevice(userID: me, apnsToken: token,
                                environment: APNsEnvironment.current,
                                notifyFriendActivity: false,
                                utcOffset: AppClock.utcOffsetSeconds)
        rig.system.stored = here.fingerprint

        await rig.push.refresh(userID: me, hasCircle: true)
        await rig.push.adoptDeviceToken(token)

        XCTAssertTrue(rig.transport.upserts.isEmpty)
        XCTAssertTrue(rig.push.isRegistered)
    }

    /// A settings flip is the other door into `writeDeviceRow`, and it must
    /// carry the CURRENT zone rather than whatever was there at launch.
    func testASettingsFlipCarriesTheCurrentZone() async {
        let rig: Rig = await registeredRig()
        rig.system.preferencesValue = PushPreferences(notificationsEnabled: true,
                                                      friendActivity: true)
        await rig.push.preferencesChanged()
        XCTAssertEqual(rig.transport.upserts.count, 2)
        XCTAssertEqual(rig.transport.upserts.last?.utcOffset, AppClock.utcOffsetSeconds)
    }

    /// The Settings screen nests "Friend activity" under the master switch, so
    /// the master switch has to mean the same thing here.
    func testTheMasterSwitchGovernsFriendActivity() {
        let onlySub = PushPreferences(notificationsEnabled: false, friendActivity: true)
        XCTAssertFalse(onlySub.wantsFriendActivity)
        let both = PushPreferences(notificationsEnabled: true, friendActivity: true)
        XCTAssertTrue(both.wantsFriendActivity)
    }

    func testTurningNotificationsOffTakesTheDeviceRowDown() async {
        let rig: Rig = await registeredRig()
        XCTAssertTrue(rig.push.isRegistered)

        rig.system.preferencesValue = PushPreferences(notificationsEnabled: false,
                                                      friendActivity: false)
        await rig.push.refresh(userID: me, hasCircle: true)
        XCTAssertEqual(rig.transport.deletes, [token])
        XCTAssertFalse(rig.push.isRegistered)
        XCTAssertNil(rig.system.stored)

        // And it stays down without a delete per foreground.
        await rig.push.refresh(userID: me, hasCircle: true)
        XCTAssertEqual(rig.transport.deletes.count, 1)
    }

    /// Signing out has to take the row with it while the session that owns it
    /// still exists — see `PushRegistrar.unregister`.
    func testSigningOutDeletesThisDevicesRow() async {
        let rig: Rig = await registeredRig()
        await rig.push.unregister()
        XCTAssertEqual(rig.transport.deletes, [token])
        XCTAssertFalse(rig.push.isRegistered)
        XCTAssertFalse(rig.push.isInRealCircle)
        XCTAssertNil(rig.system.stored)
    }

    /// v4 Phase D FIX. This test used to assert that an offline sign-out simply
    /// forgot the registration locally, on the theory that Apple's 410 handling
    /// and the retention sweep would collect the row. Neither does: the token is
    /// still live (the app is still installed) so Apple never answers 410, and
    /// retention only touches rows by `user_id`. The row stayed, and the ONE
    /// thing `unregister` exists to prevent — this circle's pushes arriving on a
    /// phone somebody else is now holding — happened anyway. The debt is written
    /// down instead.
    func testSigningOutOfflineOwesTheServerADeleteAndRemembersIt() async {
        let rig: Rig = makeRig(online: false)
        rig.system.status = .authorized
        await rig.push.refresh(userID: me, hasCircle: true)
        await rig.push.adoptDeviceToken(token)
        XCTAssertEqual(rig.transport.upserts.count, 1)

        await rig.push.unregister()
        // Nothing hung on the way out...
        XCTAssertTrue(rig.transport.deletes.isEmpty)
        XCTAssertNil(rig.system.stored)
        XCTAssertFalse(rig.push.isRegistered)
        // ...and the row is still owed.
        XCTAssertEqual(rig.system.owedDelete, token)
    }

    /// The other half: the debt is paid the first time this device is online
    /// again, from the top of `refresh` — launch, foreground, or a circle
    /// appearing.
    func testTheOwedDeleteGoesOutOnTheNextOnlineRefresh() async {
        let system = StubPushSystem()
        let transport = StubPushTransport()
        let network: Reachability = Reachability()
        network.setOnline(false)
        let push = PushRegistrar(transport: transport, system: system, reachability: network)
        system.status = .authorized
        await push.refresh(userID: me, hasCircle: true)
        await push.adoptDeviceToken(token)
        await push.unregister()
        XCTAssertEqual(system.owedDelete, token)

        network.setOnline(true)
        await push.refresh(userID: nil, hasCircle: false)
        XCTAssertEqual(transport.deletes, [token])
        XCTAssertNil(system.owedDelete, "the debt is settled, not repeated")

        // And it is not paid twice.
        await push.refresh(userID: nil, hasCircle: false)
        XCTAssertEqual(transport.deletes.count, 1)
    }

    /// A delete that fails is still owed. Anything else is the same bug in a
    /// different coat: the local record erased, the server row alive.
    func testAFailedDeleteKeepsTheDebt() async {
        let rig: Rig = await registeredRig()
        rig.transport.deleteError = StubFailure()
        rig.system.preferencesValue = PushPreferences(notificationsEnabled: false,
                                                      friendActivity: false)
        await rig.push.refresh(userID: me, hasCircle: true)
        XCTAssertTrue(rig.transport.deletes.isEmpty)
        XCTAssertEqual(rig.system.owedDelete, token)

        rig.transport.deleteError = nil
        await rig.push.refresh(userID: me, hasCircle: true)
        XCTAssertEqual(rig.transport.deletes, [token])
        XCTAssertNil(rig.system.owedDelete)
    }

    /// Registering again after the row was taken down must not leave a delete
    /// owed for the row we just wrote.
    func testRegisteringAgainClearsTheOwedDelete() async {
        let rig: Rig = makeRig(online: false)
        rig.system.status = .authorized
        await rig.push.refresh(userID: me, hasCircle: true)
        await rig.push.adoptDeviceToken(token)
        rig.system.preferencesValue = PushPreferences(notificationsEnabled: false,
                                                      friendActivity: false)
        await rig.push.refresh(userID: me, hasCircle: true)
        XCTAssertEqual(rig.system.owedDelete, token)

        rig.system.preferencesValue = PushPreferences(notificationsEnabled: true,
                                                      friendActivity: false)
        await rig.push.refresh(userID: me, hasCircle: true)
        XCTAssertNil(rig.system.owedDelete)
        XCTAssertTrue(rig.push.isRegistered)
    }

    // MARK: - Settings reach the row without waiting for a foreground

    /// v4 Phase D FIX: `refresh` was the only thing that ever wrote the device
    /// row, and its only callers are launch and foreground. So turning "Friend
    /// activity" off left `devices.notify_friend_activity = true`, and the next
    /// push the person received — after backgrounding, which is the only way
    /// they see one — was the one they had just opted out of.
    func testFlippingFriendActivityReachesTheRowImmediately() async {
        let rig: Rig = await registeredRig()
        XCTAssertEqual(rig.transport.upserts.count, 1)
        XCTAssertEqual(rig.transport.upserts.last?.notifyFriendActivity, false)

        rig.system.preferencesValue = PushPreferences(notificationsEnabled: true,
                                                      friendActivity: true)
        await rig.push.preferencesChanged()
        XCTAssertEqual(rig.transport.upserts.count, 2)
        XCTAssertEqual(rig.transport.upserts.last?.notifyFriendActivity, true)
    }

    /// The master switch owns the remote half too, on the same tap.
    func testTurningNotificationsOffTakesTheRowDownOnTheSameTap() async {
        let rig: Rig = await registeredRig()
        rig.system.preferencesValue = PushPreferences(notificationsEnabled: false,
                                                      friendActivity: false)
        await rig.push.preferencesChanged()
        XCTAssertEqual(rig.transport.deletes, [token])
        XCTAssertFalse(rig.push.isRegistered)
    }

    /// This runs from `AppState.settings.didSet`, which is EVERY settings
    /// change — a calc-method edit included. Somebody changing a preference has
    /// not asked to be asked for permission.
    func testASettingsChangeNeverRaisesAPermissionPrompt() async {
        // In a real circle, with nobody yet asked — the one state where
        // `refresh` DOES put a sheet on screen (§1).
        let rig: Rig = await registeredRig()
        rig.system.status = .notDetermined
        rig.system.authorizationRequests = 0
        rig.system.preferencesValue = PushPreferences(notificationsEnabled: true,
                                                      friendActivity: true)

        await rig.push.preferencesChanged()
        XCTAssertEqual(rig.system.authorizationRequests, 0)
        XCTAssertEqual(rig.transport.upserts.count, 1,
                       "no row written for a device nobody has authorised")

        // ...and `refresh` still asks, so the prompt has not been lost.
        await rig.push.refresh(userID: me, hasCircle: true)
        XCTAssertEqual(rig.system.authorizationRequests, 1)
    }

    /// Solo is untouched by any of it (§1).
    func testASettingsChangeDoesNothingForASoloUser() async {
        let rig: Rig = makeRig()
        rig.system.status = .authorized
        await rig.push.refresh(userID: nil, hasCircle: false)
        await rig.push.preferencesChanged()
        XCTAssertTrue(rig.transport.upserts.isEmpty)
        XCTAssertTrue(rig.transport.deletes.isEmpty)
        XCTAssertEqual(rig.system.registrations, 0)
    }

    func testNothingIsSentWhileOffline() async {
        let rig: Rig = makeRig(online: false)
        rig.system.status = .authorized
        await rig.push.refresh(userID: me, hasCircle: true)
        let outcome: NotifyOutcome = await rig.push.announceJoin()
        XCTAssertEqual(outcome, .skipped(reason: PushRegistrar.offlineReason))
        XCTAssertTrue(rig.transport.bodies.isEmpty)
    }

    // MARK: - Foreground presentation

    /// Setting a `UNUserNotificationCenterDelegate` at all changes how the
    /// LOCAL notifications that were here first behave while the app is open.
    /// v3.9 showed none of them in the foreground, and that stays true.
    func testForegroundPresentationLeavesLocalRemindersToNotificationManager() {
        XCTAssertTrue(AppDelegate.presentationOptions(remote: false).isEmpty)
        let remote: UNNotificationPresentationOptions = AppDelegate.presentationOptions(remote: true)
        XCTAssertTrue(remote.contains(.banner))
        XCTAssertTrue(remote.contains(.sound))
    }

    // MARK: - Live Activity tokens (v5 §6)

    private func liveActivity(token: String = "act-1",
                              kind: LiveActivityTokenKind = .update,
                              activityID: String? = "A1",
                              dayKey: String? = "2026-08-28",
                              prayer: Prayer? = .asr,
                              endsAt: Date? = Date(timeIntervalSince1970: 1_756_000_000),
                              utcOffset: Int = AppClock.utcOffsetSeconds)
        -> LiveActivityRegistration {
        LiveActivityRegistration(token: token, kind: kind, activityID: activityID,
                                 dayKey: dayKey, prayer: prayer, endsAt: endsAt,
                                 environment: APNsEnvironment.current,
                                 utcOffset: utcOffset)
    }

    func testAnActivityTokenReachesTheServerWithItsWindow() async {
        let rig: Rig = await registeredRig()
        let sent: Bool = await rig.push.registerLiveActivityToken(liveActivity())
        XCTAssertTrue(sent)
        XCTAssertEqual(rig.transport.liveActivityRegistrations.count, 1)
        let written: LiveActivityRegistration? = rig.transport.liveActivityRegistrations.first
        XCTAssertEqual(written?.token, "act-1")
        XCTAssertEqual(written?.kind, .update)
        // `ends_at` is the one piece of schedule the server holds, and it is
        // what buys a correct `stale-date` and an `end` push for a window that
        // closed while the phone was asleep. A registration that drops it is a
        // Lock Screen nothing can retire.
        XCTAssertNotNil(written?.endsAt)
        XCTAssertEqual(written?.prayer, .asr)
        XCTAssertEqual(written?.utcOffset, AppClock.utcOffsetSeconds)
    }

    /// SPEC-V4 §1 and §9-03 together: the SURFACE works for a solo user, the
    /// PUSH half needs friends. A demo circle's Live Activity is local, and this
    /// device has no account for a token to belong to.
    func testDemoAndSoloNeverRegisterAnActivityToken() async {
        let rig: Rig = makeRig()
        await rig.push.refresh(userID: nil, hasCircle: false)
        let sent: Bool = await rig.push.registerLiveActivityToken(liveActivity())
        XCTAssertFalse(sent)
        XCTAssertTrue(rig.transport.liveActivityRegistrations.isEmpty)

        // Signed in, but no circle — still nobody to be pushed about.
        await rig.push.refresh(userID: me, hasCircle: false)
        await rig.push.registerLiveActivityToken(liveActivity())
        XCTAssertTrue(rig.transport.liveActivityRegistrations.isEmpty)
    }

    func testNoActivityTokenIsRegisteredWhileOffline() async {
        let rig: Rig = makeRig(online: false)
        rig.system.status = .authorized
        await rig.push.refresh(userID: me, hasCircle: true)
        let sent: Bool = await rig.push.registerLiveActivityToken(liveActivity())
        XCTAssertFalse(sent)
        XCTAssertTrue(rig.transport.liveActivityRegistrations.isEmpty)
    }

    /// ActivityKit re-emits the SAME token from `pushTokenUpdates` on every
    /// launch and after every state change. A round trip per emission, on a path
    /// that runs five times a day, is what the fingerprint exists to stop.
    func testTheSameActivityTokenReEmittedCostsNoRoundTrip() async {
        let rig: Rig = await registeredRig()
        await rig.push.registerLiveActivityToken(liveActivity())
        let again: Bool = await rig.push.registerLiveActivityToken(liveActivity())
        // Reported as SUCCESS, not as a skip: the server already says this.
        XCTAssertTrue(again)
        XCTAssertEqual(rig.transport.liveActivityRegistrations.count, 1)
    }

    /// ...and the converse, because a fingerprint that ignored a field would
    /// make that field unwritable after the first registration. The window and
    /// the zone are the two that move under a token that has not.
    func testAChangedWindowOrZoneIsANewRegistration() async {
        let rig: Rig = await registeredRig()
        await rig.push.registerLiveActivityToken(liveActivity())
        await rig.push.registerLiveActivityToken(liveActivity(prayer: .maghrib))
        await rig.push.registerLiveActivityToken(
            liveActivity(prayer: .maghrib, utcOffset: AppClock.utcOffsetSeconds + 3600))
        XCTAssertEqual(rig.transport.liveActivityRegistrations.count, 3)
    }

    func testAFailedRegistrationIsNotRememberedAsDone() async {
        let rig: Rig = await registeredRig()
        rig.transport.liveActivityError = StubFailure()
        let sent: Bool = await rig.push.registerLiveActivityToken(liveActivity())
        XCTAssertFalse(sent)
        XCTAssertTrue(rig.transport.liveActivityRegistrations.isEmpty)

        // The next emission must try again rather than read as already written.
        rig.transport.liveActivityError = nil
        await rig.push.registerLiveActivityToken(liveActivity())
        XCTAssertEqual(rig.transport.liveActivityRegistrations.count, 1)
    }

    /// The activity ended, so its address goes. Not owed and not retried — the
    /// server's sweep collects a missed one within twelve hours.
    func testEndingAnActivityDeletesItsRowAndForgetsOnlyItsFingerprint() async {
        let rig: Rig = await registeredRig()
        await rig.push.registerLiveActivityToken(liveActivity(token: "act-1"))
        await rig.push.registerLiveActivityToken(
            liveActivity(token: "act-2", activityID: "A2", prayer: .isha))
        XCTAssertEqual(rig.transport.liveActivityRegistrations.count, 2)

        await rig.push.forgetLiveActivityToken("act-1")
        XCTAssertEqual(rig.transport.liveActivityDeletes, ["act-1"])

        // The forgotten one costs a round trip again...
        await rig.push.registerLiveActivityToken(liveActivity(token: "act-1"))
        XCTAssertEqual(rig.transport.liveActivityRegistrations.count, 3)
        // ...and the OTHER activity's fingerprint survived, which is what the
        // token-prefix filter is for. Clearing the whole set here would make
        // every still-running activity re-register on the next emission.
        await rig.push.registerLiveActivityToken(
            liveActivity(token: "act-2", activityID: "A2", prayer: .isha))
        XCTAssertEqual(rig.transport.liveActivityRegistrations.count, 3)
    }

    /// A token whose value is a PREFIX of another's must not take that other
    /// one's fingerprint with it — the separator is what makes the filter a
    /// token match rather than a string match.
    func testForgettingATokenDoesNotForgetOneItMerelyPrefixes() async {
        let rig: Rig = await registeredRig()
        await rig.push.registerLiveActivityToken(liveActivity(token: "act"))
        await rig.push.registerLiveActivityToken(
            liveActivity(token: "act-1", activityID: "A2"))
        XCTAssertEqual(rig.transport.liveActivityRegistrations.count, 2)

        await rig.push.forgetLiveActivityToken("act")
        await rig.push.registerLiveActivityToken(
            liveActivity(token: "act-1", activityID: "A2"))
        XCTAssertEqual(rig.transport.liveActivityRegistrations.count, 2)
    }

    /// A delete that fails is swallowed, unlike `devices`' — the row expires by
    /// itself, so a pending-delete ledger would be machinery for nothing.
    func testAFailedActivityDeleteIsNotOwed() async {
        let rig: Rig = await registeredRig()
        await rig.push.registerLiveActivityToken(liveActivity())
        rig.transport.liveActivityError = StubFailure()
        await rig.push.forgetLiveActivityToken("act-1")
        XCTAssertTrue(rig.transport.liveActivityDeletes.isEmpty)
        XCTAssertNil(rig.system.owedDelete, "an activity token is never owed a delete")
    }

    /// The wire contract with `public.register_live_activity_token(...)`. Eight
    /// snake_cased params, and a nil field OMITTED rather than sent as null —
    /// PostgREST resolves the overload by the names in the body, and the RPC's
    /// own defaults are what should apply to what is missing.
    func testTheActivityRegisterParamsMatchTheRPCSignature() throws {
        let update: Data = try JSONEncoder().encode(liveActivity().registerParams)
        let body: [String: Any] = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: update) as? [String: Any])
        XCTAssertEqual(Set(body.keys),
                       ["p_token", "p_kind", "p_activity_id", "p_day_key", "p_prayer",
                        "p_ends_at", "p_environment", "p_utc_offset"])
        XCTAssertEqual(body["p_kind"] as? String, "update")
        // The rawValue IS the `prayer_kind` label.
        XCTAssertEqual(body["p_prayer"] as? String, "asr")
        XCTAssertEqual(body["p_ends_at"] as? String, "2025-08-24T01:46:40Z")

        // A push-to-start token names no window, and the RPC refuses one that
        // does — so the encoder must not manufacture nulls for the absent keys.
        let start: Data = try JSONEncoder().encode(
            liveActivity(token: "start-1", kind: .start, activityID: nil,
                         dayKey: nil, prayer: nil, endsAt: nil).registerParams)
        let startBody: [String: Any] = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: start) as? [String: Any])
        XCTAssertEqual(Set(startBody.keys),
                       ["p_token", "p_kind", "p_environment", "p_utc_offset"])
        XCTAssertEqual(startBody["p_kind"] as? String, "start")
    }

    // MARK: - Receiving a push (v4 Phase D)

    /// The three payloads `notify` actually builds, verbatim.
    ///
    /// `buildAPNsPayload` spreads its `data` block BESIDE `aps`, so `kind`
    /// arrives as a top-level key — and if that ever stops being true this is
    /// the test that says so, because everything downstream reads exactly one
    /// field and would otherwise just fall silent.
    func testTheThreeNotifyPayloadsDecodeToTheirKind() {
        // Every key but `kind` is here to be IGNORED — that is the point of the
        // fixtures being the real shapes rather than one-key dictionaries.
        let circle: String = friend.uuidString
        let post: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "📸 Amira", "body": "posted first for Fajr"]],
            "kind": "post", "circleId": circle, "postId": postID.uuidString,
            "userId": me.uuidString, "dayKey": monday, "prayer": "fajr",
        ]
        let join: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "SalahBuddy", "body": "Yusuf joined your circle"]],
            "kind": "join", "circleId": circle, "userId": me.uuidString,
        ]
        let nudge: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Amira", "body": "nudged you for Asr"]],
            "kind": "nudge", "circleId": circle, "fromUserId": me.uuidString,
            "dayKey": monday, "prayer": "asr",
        ]

        XCTAssertEqual(PushKind(userInfo: post), .post)
        XCTAssertEqual(PushKind(userInfo: join), .join)
        XCTAssertEqual(PushKind(userInfo: nudge), .nudge)
    }

    /// Anything else is nil, not a default. A later build's push, and a
    /// notification that is not ours at all, must not be read as one of three.
    func testAnUnknownOrAbsentKindIsNotGuessedAt() {
        XCTAssertNil(PushKind(userInfo: [:]))
        XCTAssertNil(PushKind(userInfo: ["aps": ["alert": "hello"]]))
        XCTAssertNil(PushKind(userInfo: ["kind": "circleDissolved"]))
        XCTAssertNil(PushKind(userInfo: ["kind": 7]), "a non-string kind is not a kind")
        XCTAssertNil(PushKind(userInfo: ["kind": "Join"]), "the rawValues are exact")
    }

    /// A LOCAL notification can never make the app talk to the network, even if
    /// something in its payload happens to spell `kind`. The same division
    /// `presentationOptions` draws, drawn again where it decides something else.
    func testALocalNotificationNeverSignalsTheCircle() {
        let payload: [AnyHashable: Any] = ["kind": "join"]
        XCTAssertEqual(AppDelegate.receivedKind(remote: true, userInfo: payload), .join)
        XCTAssertNil(AppDelegate.receivedKind(remote: false, userInfo: payload))
    }

    /// v4 Phase D REGRESSION: a receipt used to go nowhere. `AppDelegate`
    /// implemented `willPresent` — how to draw the banner — and threw the
    /// payload away, so the phone was told a friend had joined and did not go
    /// and look. This is the hook `CircleStack` points at `CircleSync`.
    func testAReceivedPushReachesTheHookThatSignalsTheSyncEngine() {
        let rig: Rig = makeRig()
        var seen: [PushKind] = []
        rig.push.onRemoteNotification = { kind in seen.append(kind) }

        rig.push.remoteNotificationArrived(.join)
        rig.push.remoteNotificationArrived(.post)

        XCTAssertEqual(seen, [.join, .post])
        XCTAssertEqual(rig.push.lastReceived, .post)
    }

    /// And it is NOT gated on there being a live circle here: `CircleSync.pull`
    /// already refuses to do anything without one, whereas a guard at this end
    /// would race the registrar learning about a circle against the first push
    /// about it.
    func testAReceiptIsNotGatedOnThisDeviceKnowingAboutACircle() {
        let rig: Rig = makeRig()
        XCTAssertFalse(rig.push.isInRealCircle)
        var seen: Int = 0
        rig.push.onRemoteNotification = { _ in seen += 1 }

        rig.push.remoteNotificationArrived(.join)

        XCTAssertEqual(seen, 1)
    }
}
