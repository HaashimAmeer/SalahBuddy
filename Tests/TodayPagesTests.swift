import Foundation
import XCTest
@testable import SalahBuddy

/// v5 (mockup): the Today pager's pages — which windows exist, which one
/// Today opens on, and when the XP you would earn next drops.
final class TodayPagesTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    private func at(_ hours: Double) -> Date { base.addingTimeInterval(hours * 3600) }

    /// Fajr 5–7, Dhuhr 13–16, Asr 16–18, Maghrib 18–19.5, Isha 19.5–29 (5 AM).
    private var schedule: DaySchedule {
        DaySchedule(dayKey: "2026-10-02", dayStart: base, windows: [
            PrayerWindow(prayer: .fajr, start: at(5), end: at(7)),
            PrayerWindow(prayer: .dhuhr, start: at(13), end: at(16)),
            PrayerWindow(prayer: .asr, start: at(16), end: at(18)),
            PrayerWindow(prayer: .maghrib, start: at(18), end: at(19.5)),
            PrayerWindow(prayer: .isha, start: at(19.5), end: at(29)),
        ])
    }

    func testFivePagesInTimeOrder() {
        let pages = TodayPages.build(schedule: schedule, yesterdayKey: "2026-10-01",
                                     traveling: false, now: at(14))
        XCTAssertEqual(pages.map(\.prayer), [.fajr, .dhuhr, .asr, .maghrib, .isha])
        XCTAssertTrue(pages.allSatisfy { $0.dayKey == "2026-10-02" && $0.combinedWith == nil })
    }

    func testBeforeFajrTheFirstPageIsLastNightsIsha() {
        let pages = TodayPages.build(schedule: schedule, yesterdayKey: "2026-10-01",
                                     traveling: false, now: at(2))
        XCTAssertEqual(pages.count, 6)
        let first = pages[0]
        XCTAssertEqual(first.prayer, .isha)
        XCTAssertTrue(first.isYesterdayIsha)
        XCTAssertEqual(first.dayKey, "2026-10-01")
        XCTAssertEqual(first.end, at(5), "last night's Isha runs until today's Fajr")
        XCTAssertNil(first.start)
        XCTAssertEqual(TodayPages.currentIndex(in: pages, now: at(2)), 0)
    }

    func testAfterFajrLastNightsIshaIsGone() {
        let pages = TodayPages.build(schedule: schedule, yesterdayKey: "2026-10-01",
                                     traveling: false, now: at(5))
        XCTAssertFalse(pages.contains { $0.isYesterdayIsha })
    }

    func testTravelingFoldsEachPairIntoItsLeadsPage() {
        let pages = TodayPages.build(schedule: schedule, yesterdayKey: "2026-10-01",
                                     traveling: true, now: at(14))
        XCTAssertEqual(pages.map(\.prayer), [.fajr, .dhuhr, .maghrib])
        XCTAssertEqual(pages[1].combinedWith, .asr)
        XCTAssertEqual(pages[1].start, at(13))
        XCTAssertEqual(pages[1].end, at(18), "the pair's page ends when Asr ends")
        XCTAssertEqual(pages[2].combinedWith, .isha)
        XCTAssertEqual(pages[1].title, "Dhuhr + Asr")
    }

    func testOpensOnTheLatestWindowThatHasStarted() {
        let pages = TodayPages.build(schedule: schedule, yesterdayKey: "2026-10-01",
                                     traveling: false, now: at(16.5))
        XCTAssertEqual(pages[TodayPages.currentIndex(in: pages, now: at(16.5))].prayer, .asr)
        // Between Fajr's end and Dhuhr, Fajr is still the latest to have started.
        XCTAssertEqual(pages[TodayPages.currentIndex(in: pages, now: at(10))].prayer, .fajr)
        XCTAssertEqual(pages[TodayPages.currentIndex(in: pages, now: at(23))].prayer, .isha)
    }

    func testTierBoundaryIsTheEndOfTheCurrentQuarter() {
        let window = PrayerWindow(prayer: .asr, start: at(16), end: at(18))   // quarters of 30m
        XCTAssertEqual(TodayPages.tierBoundary(for: window, at: at(16)), at(16.5))
        XCTAssertEqual(TodayPages.tierBoundary(for: window, at: at(16.6)), at(17))
        XCTAssertEqual(TodayPages.tierBoundary(for: window, at: at(17.9)), at(18))
        XCTAssertNil(TodayPages.tierBoundary(for: window, at: at(15)))
        XCTAssertNil(TodayPages.tierBoundary(for: window, at: at(18)))
    }

    /// The boundary must agree with `GameEngine.tier`: just before it the tier
    /// is one thing, at it the next.
    func testTierBoundaryAgreesWithGameEngine() {
        let window = PrayerWindow(prayer: .asr, start: at(16), end: at(18))
        var now = at(16.1)
        var tiers: [LogTier] = []
        while let boundary = TodayPages.tierBoundary(for: window, at: now) {
            tiers.append(GameEngine.tier(for: window, at: boundary.addingTimeInterval(-1))!)
            now = boundary
        }
        XCTAssertEqual(tiers, [.onTime, .prayed, .lastCall, .closeCall])
    }
}
