import Foundation
import XCTest
@testable import SalahBuddy

/// v5 (migration 20261002000100): the `forgot` tier, captions, `place_kind`,
/// and the tolerant tier decode that keeps one newer phone from stopping an
/// older phone's pull.
@MainActor
final class PostFieldsV5Tests: XCTestCase {

    private let user = UUID()
    private let circle = UUID()

    // MARK: - The forgot tier

    func testForgotEarnsNothingAndIsNotInWindow() {
        XCTAssertEqual(LogTier.forgot.xp, 0)
        XCTAssertFalse(LogTier.forgot.isInWindow)
        // Jamaat floors in-window prayers only; a forgotten log stays at 0.
        XCTAssertEqual(GameEngine.prayerXP(tier: .forgot, jamaat: true), 0)
    }

    func testRemoteForgotPostScoresZero() {
        let post = RemotePost(id: UUID(), userID: user, circleID: circle, dayKey: "2026-09-30",
                              prayer: .fajr, tier: .forgot, loggedAt: Date())
        XCTAssertEqual(post.asPrayerLog().xp, 0)
    }

    // MARK: - Tolerant tier decoding

    func testUnknownTierDecodesAsForgotInsteadOfFailingThePull() throws {
        let json: String = """
        [\(row(id: UUID(), tier: "onTime")), \(row(id: UUID(), tier: "someFutureTier"))]
        """
        let posts: [RemotePost] = try CircleService.decode([RemotePost].self, from: Data(json.utf8))
        XCTAssertEqual(posts.map(\.tier), [.onTime, .forgot])
        XCTAssertEqual(posts[1].asPrayerLog().xp, 0, "an unknown tier must never invent XP")
    }

    func testUnknownPlaceKindDecodesAsNil() throws {
        let json: String = "[\(row(id: UUID(), tier: "prayed", extra: #","place_kind":"garden""#))]"
        let posts: [RemotePost] = try CircleService.decode([RemotePost].self, from: Data(json.utf8))
        XCTAssertNil(posts[0].placeKind)
    }

    // MARK: - Wire shape

    func testCaptionAndPlaceKindRoundTrip() throws {
        let json: String = "[\(row(id: UUID(), tier: "onTime", extra: #","place_kind":"onTheGo","caption":"ducks were watching""#))]"
        let post: RemotePost = try CircleService.decode([RemotePost].self, from: Data(json.utf8))[0]
        XCTAssertEqual(post.placeKind, .onTheGo)
        XCTAssertEqual(post.caption, "ducks were watching")
        XCTAssertEqual(post.asPrayerLog().placeTag, .onTheGo)
        XCTAssertEqual(post.asPrayerLog().caption, "ducks were watching")

        let encoded: [String: Any] = try encodedObject(post)
        XCTAssertEqual(encoded["place_kind"] as? String, "onTheGo")
        XCTAssertEqual(encoded["caption"] as? String, "ducks were watching")
    }

    func testFromLogNormalizesTheCaptionAndCarriesTheKind() throws {
        let log = PrayerLog(id: UUID(), prayer: .asr, dayKey: "2026-10-01", loggedAt: Date(),
                            tier: .onTime, xp: 30, placeTag: .masjid,
                            caption: "  Asr with the aunties\nafter halaqa  ")
        let post: RemotePost = RemotePost.from(log: log, userID: user, circleID: circle,
                                               placeLabel: "🕌 Masjid", photoPath: "a/b/c.jpg")
        XCTAssertEqual(post.caption, "Asr with the aunties after halaqa")
        XCTAssertEqual(post.placeKind, .masjid)
        XCTAssertEqual(post.photoPath, "a/b/c.jpg")
    }

    func testFromLogKeepsAForgottenLogBare() {
        // posts_forgot_is_bare would refuse this row on every drain forever.
        let log = PrayerLog(id: UUID(), prayer: .fajr, dayKey: "2026-09-30", loggedAt: Date(),
                            tier: .forgot, xp: 0, caption: "I promise")
        let post: RemotePost = RemotePost.from(log: log, userID: user, circleID: circle,
                                               photoPath: "a/b/c.jpg")
        XCTAssertNil(post.caption)
        XCTAssertNil(post.photoPath)
    }

    func testAbsentFieldsAreOmittedNotSentAsNull() throws {
        let post = RemotePost(id: UUID(), userID: user, circleID: circle, dayKey: "2026-10-01",
                              prayer: .dhuhr, tier: .prayed, loggedAt: Date())
        let encoded: [String: Any] = try encodedObject(post)
        XCTAssertNil(encoded["caption"])
        XCTAssertNil(encoded["place_kind"])
    }

    func testReportCarriesTheCaption() throws {
        let report = RemoteReport(reporterID: user, postID: UUID(), circleID: circle,
                                  reportedUserID: UUID(), caption: "words")
        let encoded: [String: Any] = try encodedObject(report)
        XCTAssertEqual(encoded["caption"] as? String, "words")
    }

    // MARK: - normalizedCaption (mirrors posts_caption_shape)

    func testNormalizedCaptionShape() {
        XCTAssertNil(PrayerLog.normalizedCaption(nil))
        XCTAssertNil(PrayerLog.normalizedCaption("   \n\t "), "blank is no caption")
        XCTAssertEqual(PrayerLog.normalizedCaption("a\u{0000}b\r\nc"), "a b c")
        XCTAssertEqual(PrayerLog.normalizedCaption("  sand   in everything "), "sand in everything")
    }

    func testNormalizedCaptionCountsScalarsAndNeverSplitsAnEmoji() throws {
        // One family emoji: one Character, seven scalars.
        let family: String = "👨‍👩‍👧‍👦"
        XCTAssertEqual(family.unicodeScalars.count, 7)
        let raw: String = String(repeating: "x", count: 135) + family
        let out: String = try XCTUnwrap(PrayerLog.normalizedCaption(raw))
        XCTAssertLessThanOrEqual(out.unicodeScalars.count, PrayerLog.captionMaxScalars)
        XCTAssertEqual(out, String(repeating: "x", count: 135), "the emoji is dropped whole, not cut")

        let exact: String = String(repeating: "é", count: 140)
        XCTAssertEqual(PrayerLog.normalizedCaption(exact), exact)
    }

    // MARK: - Persistence

    func testPreV5LogStillDecodes() throws {
        let json: String = """
        {"id":"\(UUID().uuidString)","prayer":"asr","dayKey":"2026-09-01",
         "loggedAt":0,"tier":"prayed","xp":20}
        """
        let log: PrayerLog = try JSONDecoder().decode(PrayerLog.self, from: Data(json.utf8))
        XCTAssertNil(log.caption)
        XCTAssertEqual(log.tier, .prayed)
    }

    func testCaptionPersists() throws {
        let log = PrayerLog(id: UUID(), prayer: .asr, dayKey: "2026-10-01", loggedAt: Date(),
                            tier: .onTime, xp: 30, caption: "between errands")
        let back: PrayerLog = try JSONDecoder().decode(PrayerLog.self,
                                                       from: JSONEncoder().encode(log))
        XCTAssertEqual(back.caption, "between errands")
    }

    // MARK: - Helpers

    private func row(id: UUID, tier: String, extra: String = "") -> String {
        """
        {"id":"\(id.uuidString)","user_id":"\(user.uuidString)","circle_id":"\(circle.uuidString)",\
        "day_key":"2026-10-01","prayer":"asr","tier":"\(tier)",\
        "logged_at":"2026-10-01T23:47:00Z","jamaat":false,"travel_combined":false\(extra)}
        """
    }

    private func encodedObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data: Data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
