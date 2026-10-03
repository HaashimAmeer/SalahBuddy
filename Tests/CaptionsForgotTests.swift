import Foundation
import XCTest
@testable import SalahBuddy

/// v5: the caption field and the "prayed but forgot to log" action, driven
/// through a real `AppState` (the `WidgetWriterTests` rig: `Store.directory` is
/// the test host's container, and every file touched is put back).
@MainActor
final class CaptionsForgotTests: XCTestCase {

    // MARK: - Rig

    private func prepareDisk() {
        for file in [Store.settingsFile, Store.profileFile, Store.logsFile,
                     Store.circleFile, Store.widgetFile] {
            let url: URL = Store.url(for: file)
            let original: Data? = try? Data(contentsOf: url)
            addTeardownBlock {
                try? FileManager.default.removeItem(at: url)
                if let original { try? original.write(to: url, options: .atomic) }
            }
            try? FileManager.default.removeItem(at: url)
        }
        addTeardownBlock {
            AppClock.isTimeTravelAllowed = true
            AppClock.offset = 0
        }
        AppClock.isTimeTravelAllowed = true
        AppClock.offset = 0
        #if DEBUG
        LocationProvider.shared.simulateDeviceFix(nil)
        #endif
        var profile: UserProfile = .fresh(now: Date().addingTimeInterval(-90 * 86_400))
        profile.startedSolo = false
        Store.save(profile, to: Store.profileFile)
        var settings = AppSettings()
        settings.circleMode = .demo
        settings.useDeviceLocation = false
        Store.save(settings, to: Store.settingsFile)
    }

    private func yesterdayKey() -> String {
        AppClock.dayKey(for: AppClock.now.addingTimeInterval(-86_400))
    }

    // MARK: - Forgot to log

    func testForgotLogsAPastPrayerAsPrayedForNoXP() {
        prepareDisk()
        let state = AppState()
        let day: String = yesterdayKey()
        let xpBefore: Int = state.profile.totalXP

        state.logForgot(.fajr, dayKey: day)

        let entry: PrayerLog? = state.logs.first { $0.dayKey == day && $0.prayer == .fajr }
        XCTAssertEqual(entry?.tier, .forgot)
        XCTAssertEqual(entry?.xp, 0)
        XCTAssertNil(entry?.photoFilename)
        XCTAssertNil(entry?.caption)
        XCTAssertEqual(state.profile.totalXP, xpBefore, "forgot earns nothing")
        XCTAssertEqual(GridCellState.logged(.forgot), .inWindow(.forgot),
                       "a forgotten log draws as prayed, not made up")
    }

    func testForgotIsRefusedTwiceAndForToday() {
        prepareDisk()
        let state = AppState()
        let day: String = yesterdayKey()

        state.logForgot(.dhuhr, dayKey: day)
        state.logForgot(.dhuhr, dayKey: day)
        state.logPastMakeUp(.dhuhr, dayKey: day)
        XCTAssertEqual(state.logs.filter { $0.dayKey == day && $0.prayer == .dhuhr }.count, 1,
                       "one prayer, one record — whichever came first")

        state.logForgot(.asr, dayKey: state.todayKey)
        XCTAssertFalse(state.logs.contains { $0.dayKey == state.todayKey && $0.tier == .forgot },
                       "today's prayers are logged from Today, not back-filled")
    }

    func testAForgottenDayIsCompleteButNeverPerfect() {
        let day = "2026-09-30"
        var logs: [PrayerLog] = Prayer.allCases.dropLast().map {
            PrayerLog(id: UUID(), prayer: $0, dayKey: day, loggedAt: Date(), tier: .onTime, xp: 30)
        }
        logs.append(PrayerLog(id: UUID(), prayer: .isha, dayKey: day, loggedAt: Date(),
                              tier: .forgot, xp: 0))
        XCTAssertTrue(GameEngine.isDayComplete(logs: logs, dayKey: day))
        XCTAssertFalse(GameEngine.isPerfectDay(logs: logs, dayKey: day))
    }

    // MARK: - Captions

    func testACaptionIsNormalizedIntoTheLogAndShownOnYourSquare() throws {
        prepareDisk()
        let state = AppState()
        let window: PrayerWindow = try XCTUnwrap(state.todaySchedule?.window(for: .dhuhr))
        AppClock.offset = window.start.addingTimeInterval(120).timeIntervalSince(Date())
        state.refresh()

        state.log(.dhuhr, photoFilename: nil, caption: "  between meetings\n alhamdulillah ")

        let log: PrayerLog = try XCTUnwrap(state.logs.first { $0.prayer == .dhuhr
            && $0.dayKey == state.todayKey })
        XCTAssertEqual(log.caption, "between meetings alhamdulillah")
        let mine: GridEntry? = state.gridEntries(for: .dhuhr, dayKey: state.todayKey)
            .first { $0.member.isYou }
        XCTAssertEqual(mine?.caption, "between meetings alhamdulillah")
    }

    func testABlankCaptionIsNoCaption() throws {
        prepareDisk()
        let state = AppState()
        let window: PrayerWindow = try XCTUnwrap(state.todaySchedule?.window(for: .asr))
        AppClock.offset = window.start.addingTimeInterval(120).timeIntervalSince(Date())
        state.refresh()

        state.log(.asr, photoFilename: nil, caption: "   ")
        XCTAssertNil(state.logs.first { $0.prayer == .asr && $0.dayKey == state.todayKey }?.caption)
    }

    func testTheDemoCircleCaptionsSomePostsDeterministically() {
        let days: [String] = (1...28).map { String(format: "2026-09-%02d", $0) }
        let captions: [String?] = days.flatMap { day in
            Prayer.allCases.map { BuddySimulator.caption(seed:
                BuddySimulator.seed(name: "Mina", dayKey: day, prayer: $0)) }
        }
        let some: Int = captions.compactMap { $0 }.count
        XCTAssertGreaterThan(some, 0)
        XCTAssertLessThan(some, captions.count, "not every post has a caption")
        XCTAssertEqual(captions, days.flatMap { day in
            Prayer.allCases.map { BuddySimulator.caption(seed:
                BuddySimulator.seed(name: "Mina", dayKey: day, prayer: $0)) }
        }, "time travel reproduces the same captions")
        for caption in captions.compactMap({ $0 }) {
            XCTAssertEqual(PrayerLog.normalizedCaption(caption), caption,
                           "a demo caption must already satisfy the server's shape")
        }
    }

    // MARK: - Slot repair

    func testASlotRepairWritesCaptionAndPlaceKindEvenWhenAbsent() throws {
        let patch = PostSlotPatch(tier: .prayed, loggedAt: Date(), jamaat: false,
                                  placeLabel: nil, travelCombined: false)
        let text: String = String(decoding: try JSONEncoder().encode(patch), as: UTF8.self)
        XCTAssertTrue(text.contains("\"caption\":null"), text)
        XCTAssertTrue(text.contains("\"place_kind\":null"), text)

        let tagged = PostSlotPatch(tier: .prayed, loggedAt: Date(), jamaat: false,
                                   placeLabel: "🕌 Masjid", travelCombined: false,
                                   placeKind: .masjid, caption: "with the aunties")
        let taggedText: String = String(decoding: try JSONEncoder().encode(tagged), as: UTF8.self)
        XCTAssertTrue(taggedText.contains("\"place_kind\":\"masjid\""), taggedText)
        XCTAssertTrue(taggedText.contains("\"caption\":\"with the aunties\""), taggedText)
    }
}
