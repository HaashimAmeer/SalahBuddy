import XCTest
@testable import SalahBuddy

/// v5 (mockup): starred photos are a new saved field, so a save written
/// before it existed must still open.
final class StarredPhotosTests: XCTestCase {

    func testAnOldSaveWithoutStarsStillDecodes() throws {
        var profile = UserProfile.fresh(now: Date(timeIntervalSince1970: 1_790_000_000))
        profile.starredPhotos = ["a.jpg"]
        let data = try JSONEncoder().encode(profile)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "starredPhotos")
        let old = try JSONSerialization.data(withJSONObject: json)
        XCTAssertEqual(try JSONDecoder().decode(UserProfile.self, from: old).starredPhotos, [])
    }

    func testStarsRoundTrip() throws {
        var profile = UserProfile.fresh(now: Date(timeIntervalSince1970: 1_790_000_000))
        profile.starredPhotos = ["b.jpg", "a.jpg"]
        let decoded = try JSONDecoder().decode(UserProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded.starredPhotos, ["b.jpg", "a.jpg"])
    }
}
