import XCTest
@testable import SalahBuddy

/// v5 (mockup): the Circle tab's places map and Explorer of the month.
final class PlacesMapTests: XCTestCase {

    private func visit(_ name: String, _ label: String, you: Bool = false) -> PlacesMap.Visit {
        PlacesMap.Visit(memberName: name, isYou: you, label: label)
    }

    func testHomeAndWorkAreNeverShared() {
        let visits = [visit("Mina", "🏠 Home"), visit("Mina", "💼 Work"),
                      visit("Mina", "🕌 Masjid"), visit("Mina", "📍 Capitol Hill")]
        XCTAssertEqual(Set(PlacesMap.spots(from: visits).map(\.label)),
                       ["🕌 Masjid", "📍 Capitol Hill"])
        XCTAssertEqual(PlacesMap.spotCounts(from: visits)["Mina"], 2)
    }

    func testSpotsAreDistinctAndMostVisitedFirst() {
        let visits = [visit("Mina", "📍 Pike Place"), visit("Zayn", "📍 Pike Place"),
                      visit("Zayn", "📍 Pike Place"), visit("Amira", "🕌 Masjid")]
        let spots = PlacesMap.spots(from: visits)
        XCTAssertEqual(spots.map(\.label), ["📍 Pike Place", "🕌 Masjid"])
        XCTAssertEqual(spots[0].visits, 3)
        XCTAssertEqual(spots[0].people, ["Mina", "Zayn"])
    }

    func testExplorerHasTheMostDistinctSpotsNotTheMostVisits() {
        let visits = [visit("Zayn", "📍 A"), visit("Zayn", "📍 A"), visit("Zayn", "📍 A"),
                      visit("Mina", "📍 A"), visit("Mina", "📍 B")]
        XCTAssertEqual(PlacesMap.explorer(from: visits),
                       PlacesMap.Explorer(name: "Mina", isYou: false, spots: 2))
    }

    func testExplorerTiesGoAlphabetically() {
        let visits = [visit("Zayn", "📍 A"), visit("Amira", "📍 B")]
        XCTAssertEqual(PlacesMap.explorer(from: visits)?.name, "Amira")
    }

    func testNoSharedSpotsMeansNoExplorer() {
        XCTAssertNil(PlacesMap.explorer(from: [visit("Mina", "🏠 Home")]))
    }

    func testPinPositionIsStableAndInsideTheMap() {
        let spot = PlacesMap.Spot(label: "📍 Capitol Hill", visits: 1, people: [])
        XCTAssertEqual(spot.position.x, spot.position.x)
        XCTAssertTrue((0.1...0.9).contains(spot.position.x))
        XCTAssertTrue((0.1...0.9).contains(spot.position.y))
    }
}
