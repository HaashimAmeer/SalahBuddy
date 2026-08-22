import XCTest
@testable import SalahBuddy

/// The city picker exists because the old flow silently kept the geocoder's
/// FIRST guess, and a wrong fixed location is wrong prayer times every day
/// with nothing on screen to notice. These cover the judgement calls in
/// turning raw search rows into a list somebody can choose from.
final class CitySearchTests: XCTestCase {

    private func place(_ locality: String?,
                       region: String? = nil,
                       country: String? = nil,
                       thoroughfare: String? = nil,
                       name: String? = nil,
                       lat: Double = 0,
                       lon: Double = 0) -> RawPlace {
        RawPlace(locality: locality, region: region, country: country,
                 thoroughfare: thoroughfare, name: name,
                 latitude: lat, longitude: lon)
    }

    // MARK: - The point of the feature

    func testNamesakeCitiesStayDistinct() {
        let matches = CityMatch.distill([
            place("Springfield", region: "Illinois", country: "United States", lat: 39.8, lon: -89.6),
            place("Springfield", region: "Missouri", country: "United States", lat: 37.2, lon: -93.3),
            place("Springfield", region: "Massachusetts", country: "United States", lat: 42.1, lon: -72.6)
        ])
        XCTAssertEqual(matches.count, 3, "namesakes must all be offered — choosing between them is the whole feature")
        XCTAssertEqual(matches.map(\.subtitle), [
            "Illinois, United States",
            "Missouri, United States",
            "Massachusetts, United States"
        ])
        // Distinct coordinates: the bug being fixed is silently taking one.
        XCTAssertEqual(Set(matches.map(\.latitude)).count, 3)
    }

    func testDuplicateRowsForOneCityCollapse() {
        // A single search routinely returns the city several times over.
        let matches = CityMatch.distill([
            place("Seattle", region: "Washington", country: "United States", lat: 47.6, lon: -122.3),
            place("Seattle", region: "Washington", country: "United States", lat: 47.6, lon: -122.3),
            place("SEATTLE", region: "washington", country: "United States", lat: 47.6, lon: -122.3)
        ])
        XCTAssertEqual(matches.count, 1, "three identical-looking rows is a worse choice than one")
        XCTAssertEqual(matches.first?.city, "Seattle", "the first spelling wins, not the shoutiest")
    }

    // MARK: - Filtering

    func testStreetAddressesAreNotCities() {
        let matches = CityMatch.distill([
            place("Springfield", region: "Illinois", country: "United States"),
            place("Springfield", region: "Illinois", country: "United States", thoroughfare: "Main St")
        ])
        XCTAssertEqual(matches.count, 1)
        XCTAssertNil(matches.first?.subtitle.range(of: "Main"))
    }

    func testResultWithoutLocalityFallsBackToItsName() {
        // Some territories return no `locality`; dropping them silently would
        // make real places unreachable.
        let matches = CityMatch.distill([place(nil, region: nil, country: "Vatican City", name: "Vatican City")])
        XCTAssertEqual(matches.first?.city, "Vatican City")
        XCTAssertEqual(matches.first?.subtitle, "Vatican City")
    }

    func testRowWithNoUsableNameIsDropped() {
        XCTAssertTrue(CityMatch.distill([place(nil, name: nil)]).isEmpty)
        XCTAssertTrue(CityMatch.distill([place("   ", name: "  ")]).isEmpty)
    }

    // MARK: - Subtitle assembly

    func testSubtitleOmitsMissingAndBlankParts() {
        XCTAssertEqual(CityMatch.distill([place("Mecca", region: nil, country: "Saudi Arabia")])
                        .first?.subtitle, "Saudi Arabia")
        XCTAssertEqual(CityMatch.distill([place("Mecca", region: "  ", country: "Saudi Arabia")])
                        .first?.subtitle, "Saudi Arabia",
                       "a blank region must not leave a dangling comma")
        XCTAssertEqual(CityMatch.distill([place("Atlantis")]).first?.subtitle, "",
                       "no region or country is empty, never ', '")
    }

    func testIdentityIsStableAcrossSearches() {
        let first = CityMatch.distill([place("Seattle", region: "Washington", country: "United States")])
        let again = CityMatch.distill([place("Seattle", region: "Washington", country: "United States")])
        XCTAssertEqual(first.first?.id, again.first?.id,
                       "row identity must survive a re-search or SwiftUI re-animates the list")
    }

    func testEmptyInputYieldsEmptyList() {
        XCTAssertTrue(CityMatch.distill([]).isEmpty)
    }

    // MARK: - Coordinates actually carry through

    func testChosenCoordinatesArePreserved() {
        let matches = CityMatch.distill([
            place("Seattle", region: "Washington", country: "United States", lat: 47.6062, lon: -122.3321)
        ])
        XCTAssertEqual(matches.first?.latitude ?? 0, 47.6062, accuracy: 0.0001)
        XCTAssertEqual(matches.first?.longitude ?? 0, -122.3321, accuracy: 0.0001)
    }
}
