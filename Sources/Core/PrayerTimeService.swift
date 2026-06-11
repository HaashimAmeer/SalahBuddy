import Foundation
import Adhan

/// Computes the day's prayer windows via the Adhan package.
enum PrayerTimeService {

    /// Schedule for the calendar day containing `date`.
    /// Isha's window ends at the NEXT day's fajr (it may cross midnight).
    /// Returns nil only if Adhan can't compute times (extreme latitudes).
    static func schedule(for date: Date,
                         latitude: Double,
                         longitude: Double,
                         method: CalcMethod,
                         madhab: AsrMadhab,
                         calendar: Calendar = .current) -> DaySchedule? {
        let dayStart = calendar.startOfDay(for: date)
        guard let today = prayerTimes(on: dayStart, latitude: latitude, longitude: longitude,
                                      method: method, madhab: madhab, calendar: calendar),
              let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: dayStart),
              let tomorrow = prayerTimes(on: tomorrowStart, latitude: latitude, longitude: longitude,
                                         method: method, madhab: madhab, calendar: calendar)
        else { return nil }

        let windows = [
            PrayerWindow(prayer: .fajr, start: today.fajr, end: today.sunrise),
            PrayerWindow(prayer: .dhuhr, start: today.dhuhr, end: today.asr),
            PrayerWindow(prayer: .asr, start: today.asr, end: today.maghrib),
            PrayerWindow(prayer: .maghrib, start: today.maghrib, end: today.isha),
            PrayerWindow(prayer: .isha, start: today.isha, end: tomorrow.fajr),
        ]
        return DaySchedule(dayKey: AppClock.dayKey(for: dayStart), dayStart: dayStart, windows: windows)
    }

    private static func prayerTimes(on dayStart: Date,
                                    latitude: Double,
                                    longitude: Double,
                                    method: CalcMethod,
                                    madhab: AsrMadhab,
                                    calendar: Calendar) -> PrayerTimes? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = calendar.timeZone
        let comps = cal.dateComponents([.year, .month, .day], from: dayStart)
        let coords = Coordinates(latitude: latitude, longitude: longitude)
        var params = adhanParams(for: method)
        params.madhab = (madhab == .hanafi) ? .hanafi : .shafi
        return PrayerTimes(coordinates: coords, date: comps, calculationParameters: params)
    }

    private static func adhanParams(for method: CalcMethod) -> CalculationParameters {
        switch method {
        case .northAmerica: return CalculationMethod.northAmerica.params
        case .muslimWorldLeague: return CalculationMethod.muslimWorldLeague.params
        case .egyptian: return CalculationMethod.egyptian.params
        case .ummAlQura: return CalculationMethod.ummAlQura.params
        case .karachi: return CalculationMethod.karachi.params
        }
    }
}
