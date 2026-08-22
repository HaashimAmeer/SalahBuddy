import Foundation
import CoreLocation
import MapKit

/// City lookup for the fixed-location setting.
///
/// The old flow forward-geocoded whatever was typed and silently kept
/// `placemarks.first`. For a prayer app that is worse than a rough edge: type
/// "Springfield" and you get one of dozens, with nothing on screen saying
/// which — and wrong coordinates mean wrong prayer times every day, quietly,
/// with no error to notice.
///
/// So the search now RETURNS CANDIDATES and the person picks one. A name alone
/// is not a choice anybody can make correctly.

/// One row a search backend handed back, before it has been judged.
///
/// Deliberately a plain value type rather than `CLPlacemark`: the filtering and
/// de-duplication below are where the bugs live, and they should be testable
/// without a network, a device, or MapKit.
struct RawPlace: Equatable {
    var locality: String?
    var region: String?
    var country: String?
    /// Set when the result is a STREET address rather than a place — the
    /// signal used to throw away "1 Main St, Springfield" while keeping
    /// "Springfield".
    var thoroughfare: String?
    var name: String?
    var latitude: Double
    var longitude: Double
}

/// A city the user can actually choose.
struct CityMatch: Identifiable, Equatable {
    /// Derived from the place itself, not random: SwiftUI keeps row identity
    /// stable across re-searches, and two searches for the same city produce
    /// the same id.
    var id: String { key }

    var city: String
    var region: String?
    var country: String?
    var latitude: Double
    var longitude: Double

    /// What the row shows beneath the city name, and the entire reason this
    /// type exists — "Springfield" is ambiguous, "Springfield · Illinois,
    /// United States" is not.
    var subtitle: String {
        [region, country]
            .compactMap { $0 }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: ", ")
    }

    /// Identity for de-duplication. A search for one city routinely comes back
    /// several times over (the city, a neighbourhood in it, a landmark), and
    /// three identical-looking rows is a worse choice than one.
    var key: String {
        [city, region ?? "", country ?? ""]
            .map { $0.lowercased() }
            .joined(separator: "|")
    }

    /// Turn raw backend rows into a clean, ordered, de-duplicated list.
    ///
    /// Pure on purpose — every rule below is a judgement call worth a test.
    static func distill(_ raw: [RawPlace]) -> [CityMatch] {
        var seen = Set<String>()
        var out: [CityMatch] = []
        for place in raw {
            // A street address is not a city. `resultTypes = .address` happily
            // returns "1600 Pennsylvania Ave"; picking that as your prayer
            // location would work, but the list is meant to read as cities.
            guard place.thoroughfare == nil else { continue }

            // Fall back to `name` so a result that carries no `locality`
            // (some countries, and most territories) is still offerable
            // rather than silently dropped.
            let cityName = Self.firstNonEmpty(place.locality, place.name)
            guard let city = cityName else { continue }

            let match = CityMatch(city: city,
                                  region: Self.nilIfEmpty(place.region),
                                  country: Self.nilIfEmpty(place.country),
                                  latitude: place.latitude,
                                  longitude: place.longitude)
            guard !seen.contains(match.key) else { continue }
            seen.insert(match.key)
            out.append(match)
        }
        return out
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty { return v }
        }
        return nil
    }

    private static func nilIfEmpty(_ value: String?) -> String? {
        guard let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        return v
    }
}

/// The seam. `SettingsView` talks to this, never to MapKit, so the picker can
/// be driven by a stub in tests.
protocol CitySearching {
    func search(_ query: String) async -> [CityMatch]
}

/// MapKit-backed lookup.
///
/// `MKLocalSearch` rather than `CLGeocoder`: the latter is deprecated as of
/// iOS 26 ("Use MapKit"), and its replacement `MKGeocodingRequest` is iOS
/// 26-only, which this app's iOS 17 deployment target cannot require.
/// `MKLocalSearch` has been available since iOS 6.1, is not deprecated, and —
/// the point here — returns SEVERAL candidates where the geocoder returned one.
struct MapKitCitySearch: CitySearching {
    func search(_ query: String) async -> [CityMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        request.resultTypes = [.address]

        do {
            let response = try await MKLocalSearch(request: request).start()
            return CityMatch.distill(response.mapItems.map { item in
                let p = item.placemark
                return RawPlace(locality: p.locality,
                                region: p.administrativeArea,
                                country: p.country,
                                thoroughfare: p.thoroughfare,
                                name: item.name,
                                latitude: p.coordinate.latitude,
                                longitude: p.coordinate.longitude)
            })
        } catch {
            // Offline, cancelled, or no match. The caller distinguishes
            // "searched and found nothing" from "haven't searched yet", so an
            // empty list is the whole vocabulary needed here.
            return []
        }
    }
}
