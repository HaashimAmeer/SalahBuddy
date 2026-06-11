# SalahBuddy — MVP Spec (single source of truth)

iOS app (Swift/SwiftUI, iOS 17+, iPhone only, portrait) that gamifies praying the 5 daily prayers on time. Duolingo-heavy design: streak flame, XP + levels, mascot with moods, celebrations, weekly league with simulated friends. Prayer times auto-calculated via the Adhan Swift package.

Project root: `/Users/haashimameer/Documents/SalahBuddy`
Project generated with XcodeGen (`project.yml` → `SalahBuddy.xcodeproj`).

---

## 1. Game mechanics (exact rules)

### Prayer windows
For a given day, compute via Adhan:
- Fajr: fajr → sunrise
- Dhuhr: dhuhr → asr
- Asr: asr → maghrib
- Maghrib: maghrib → isha
- Isha: isha → **next day's** fajr

### Logging & XP tiers
User taps "I prayed". Tier = position of `AppClock.now` within the prayer's window:

| Tier (`LogTier`) | When | XP | Label |
|---|---|---|---|
| `.onTime` | first ⅓ of window | 30 | "On time! ⚡" |
| `.prayed` | second ⅓ | 20 | "Prayed" |
| `.lastCall` | final ⅓ | 10 | "Just made it" |
| `.qada` | after window closed, same schedule day | 5 | "Made up (Qada)" |
| (missed) | never logged by end of day | 0 | — |

- Double-logging is a no-op. Undo allowed (removes log, reverses XP/bonuses).
- A log's `dayKey` is the **schedule day** the window belongs to (Isha logged at 1 AM counts for the previous day).
- Qada logging only for *today's* prayers whose window passed. Once the day rolls over, unlogged prayers are permanently missed.

### Bonuses, streak, freezes
- **Perfect Day**: all 5 logged in-window (onTime/prayed/lastCall) → +25 XP bonus, `perfectDayCount += 1`.
- **Streak**: a day counts if **all 5 prayers logged** (any tier incl. qada). Streak increments at the moment the 5th is logged.
- **Streak freezes**: earn 1 every time streak hits a multiple of 7 (max 2 stored). On launch, reconcile every elapsed day since last reconcile: incomplete day → consume a freeze, else streak resets to 0.
- **Daily XP goal**: 100 XP (settings-visible, not editable in MVP).

### Levels
XP to advance from level n to n+1: `100 + (n-1) * 25`. Level starts at 1.
Titles (every 5 levels, clamp at end): Seeker, Committed, Consistent, Devoted, Steadfast, Radiant, Luminous.

### Crescent League (simulated, weekly)
- Week = Mon 00:00 → Sun 23:59 local. Header shows "Resets in Xd Yh".
- 9 simulated friends, **deterministic** per (friendName, ISO week key) via a seeded SplitMix64 RNG — NO `Date()`/`Math.random` style nondeterminism; same week → same trajectory.
- Each friend has a fixed persona consistency (0.55–0.95). Their weekly XP at time t = sum over prayer windows *elapsed so far this week* of a persona-probability tier draw — so the board moves during the day.
- Friends (name, emoji avatar, consistency): Ahmed 🧔 0.92, Fatima 🧕 0.95, Yusuf 🧢 0.85, Aisha 🌸 0.78, Omar 🏀 0.70, Maryam 📚 0.88, Bilal 🎯 0.65, Zainab ✨ 0.82, Idris 🌙 0.55.
- Your entry uses real XP earned this week (sum of logs+bonuses with dayKey in week).

### Badges (`Badge.all`)
| id | name | condition | SF symbol |
|---|---|---|---|
| streak3 | Kindling | streak ≥ 3 | flame |
| streak7 | On Fire | streak ≥ 7 | flame.fill |
| streak30 | Unstoppable | streak ≥ 30 | flame.circle.fill |
| perfect1 | Perfect Day | first perfect day | star.fill |
| perfect10 | Perfectionist | 10 perfect days | sparkles |
| fajr7 | Dawn Patrol | 7 cumulative in-window Fajr | sunrise.fill |
| xp1000 | Rising Star | total XP ≥ 1000 | bolt.fill |
| xp5000 | Luminary | total XP ≥ 5000 | sun.max.fill |

### Notifications (local)
- At each prayer start: "Time for {Prayer} {emoji} — keep your {n}-day streak alive!"
- 30 min before a window closes if that prayer is unlogged: "Last call for {Prayer}!"
- Schedule next 48h; reschedule on foreground and settings change. Permission requested in onboarding.

---

## 2. Architecture & file ownership

**Hard rule: agents only create/edit files they own.** Feature agents must NOT touch core files — if the core API is missing something, work around it with extensions inside your own files.

| Owner | Files |
|---|---|
| **scaffold** | `project.yml`, `Sources/App/SalahBuddyApp.swift`, `Sources/App/AppState.swift`, `Sources/App/AppClock.swift`, `Sources/App/RootView.swift`, `Sources/Core/Models.swift`, `Sources/Core/GameEngine.swift`, `Sources/Core/PrayerTimeService.swift`, `Sources/Core/LocationProvider.swift`, `Sources/Core/FriendSimulator.swift`, `Sources/Core/Store.swift`, `Sources/Core/Badges.swift`, `Sources/UI/Theme.swift`, `Tests/GameEngineTests.swift`, placeholder stubs for every feature view so the target compiles |
| **home** | `Sources/Views/Home/*` (HomeView, prayer cards, celebration overlay), `Sources/Views/Onboarding/*` |
| **components** | `Sources/Views/Components/*` (MascotView, StreakFlameView, ConfettiBurstView, ChunkyButton, ProgressRing, XPChip, BadgeIcon) |
| **league** | `Sources/Views/League/*` |
| **stats-settings** | `Sources/Views/Stats/*`, `Sources/Views/Settings/*`, `Sources/Core/NotificationManager.swift` |
| **integration** | may edit anything to wire up & fix the build |

### Data flow
Single `AppState: ObservableObject` injected via `.environmentObject` at the root. JSON persistence (Codable → files in app Documents dir) via `Store`. Settings persisted the same way. **All time reads go through `AppClock.now`** (never `Date()`) so debug time-travel works.

---

## 3. Exact cross-agent contracts

Scaffold implements these EXACTLY. Feature agents code against them blind (they run in parallel) — read the real core files too, but these signatures are guaranteed.

### Models (`Sources/Core/Models.swift`)
```swift
enum Prayer: String, CaseIterable, Codable, Identifiable {
    case fajr, dhuhr, asr, maghrib, isha
    var id: String { rawValue }
    var displayName: String      // "Fajr"…
    var symbolName: String       // fajr: sunrise.fill, dhuhr: sun.max.fill, asr: sun.min.fill, maghrib: sunset.fill, isha: moon.stars.fill
    var emoji: String            // 🌅 ☀️ 🌤 🌇 🌙
}

enum LogTier: String, Codable { case onTime, prayed, lastCall, qada
    var xp: Int; var label: String }

struct PrayerWindow { let prayer: Prayer; let start: Date; let end: Date }
struct DaySchedule { let dayKey: String; let dayStart: Date; let windows: [PrayerWindow] }

struct PrayerLog: Codable, Identifiable, Equatable {
    var id: UUID; var prayer: Prayer; var dayKey: String   // "yyyy-MM-dd" local
    var loggedAt: Date; var tier: LogTier; var xp: Int }

struct UserProfile: Codable {
    var name: String; var totalXP: Int
    var streak: Int; var longestStreak: Int; var streakFreezes: Int
    var lastStreakDayKey: String?; var lastReconciledDayKey: String?
    var earnedBadges: [String: Date]; var perfectDayCount: Int; var joinedAt: Date }

enum CalcMethod: String, Codable, CaseIterable { case northAmerica, muslimWorldLeague, egyptian, ummAlQura, karachi
    var displayName: String }
enum AsrMadhab: String, Codable, CaseIterable { case shafi, hanafi }

struct AppSettings: Codable {
    var calcMethod: CalcMethod        // default .northAmerica
    var madhab: AsrMadhab             // default .shafi
    var useDeviceLocation: Bool       // default true
    var fixedLatitude: Double         // default 47.6062
    var fixedLongitude: Double        // default -122.3321
    var locationName: String          // default "Seattle"
    var notificationsEnabled: Bool    // default false
    var dailyGoal: Int                // default 100
    var hasOnboarded: Bool            // default false
}

struct Badge: Identifiable { let id: String; let name: String; let symbolName: String; let detail: String }
// Badge.all in Badges.swift

enum PrayerStatus: Equatable {
    case upcoming(opensAt: Date)
    case open(closesAt: Date)
    case logged(LogTier)
    case missedWindow            // window passed today, qada still possible
}

struct LogResult: Equatable {
    var prayer: Prayer; var tier: LogTier; var xpEarned: Int; var bonusXP: Int
    var newBadgeIDs: [String]; var leveledUp: Bool; var perfectDay: Bool; var streakExtended: Bool }

struct LeaderboardEntry: Identifiable {
    var id: String; var name: String; var avatar: String   // emoji
    var xp: Int; var isYou: Bool }

struct DayRecap { var dayKey: String; var date: Date
    var loggedCount: Int; var inWindowCount: Int; var xp: Int; var isPerfect: Bool }
```

### AppState (`Sources/App/AppState.swift`)
```swift
@MainActor final class AppState: ObservableObject {
    @Published private(set) var profile: UserProfile
    @Published private(set) var logs: [PrayerLog]          // full history
    @Published var settings: AppSettings                   // didSet → persist + refresh()
    @Published private(set) var todaySchedule: DaySchedule?
    @Published var celebration: LogResult?                 // set by log(); UI presents then nils it

    var todayLogs: [PrayerLog] { get }
    var todayXP: Int { get }                               // logs + bonuses today
    var level: Int { get }
    var levelTitle: String { get }
    var xpIntoLevel: Int { get }
    var xpNeededForLevel: Int { get }

    func status(of prayer: Prayer) -> PrayerStatus
    func potentialTier(for prayer: Prayer) -> LogTier?     // tier if logged right now (nil if upcoming)
    func log(_ prayer: Prayer)
    func undoLog(_ prayer: Prayer)
    func leaderboard() -> [LeaderboardEntry]               // sorted desc, includes you
    func leagueResetDate() -> Date
    func recaps(daysBack: Int) -> [DayRecap]               // oldest → newest, includes today
    func refresh()                                         // recompute schedule + reconcile streak; call on foreground/day change
    // DEBUG helpers
    func fillDemoHistory()                                 // 21 days of plausible logs, rebuilds profile from logs
    func resetAllData()
}
```

### Theme (`Sources/UI/Theme.swift`)
```swift
enum Theme {
    static let green   = Color(hex: 0x2DBE6C)  // primary action / success
    static let greenDark = Color(hex: 0x1F9954)
    static let gold    = Color(hex: 0xF5B722)  // XP, badges, streak
    static let cream   = Color(hex: 0xFDF8EF)  // app background
    static let card    = Color.white
    static let ink     = Color(hex: 0x2F3E36)  // primary text
    static let inkSoft = Color(hex: 0x8A9A90)  // secondary text
    static let coral   = Color(hex: 0xF26B5B)  // missed / danger
    static let sky     = Color(hex: 0x4DA8DA)
    static let lilac   = Color(hex: 0x9B7EDE)
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font  // .system(.. design: .rounded)
}
extension Color { init(hex: UInt) }
```

### Components (`Sources/Views/Components/`) — components agent implements EXACTLY; others call blind
```swift
enum MascotMood { case celebrating, happy, neutral, sleepy, worried }
struct MascotView: View   { let mood: MascotMood; let size: CGFloat }          // memberwise init
struct StreakFlameView: View { let streak: Int; let isLitToday: Bool }
struct ConfettiBurstView: View { let trigger: Int }    // replays a burst whenever trigger increments
struct ChunkyButton: View { let title: String; let color: Color; let isEnabled: Bool; let action: () -> Void }
struct ProgressRing: View { let progress: Double; let lineWidth: CGFloat; let color: Color }
struct XPChip: View { let xp: Int }
struct BadgeIcon: View { let badge: Badge; let earned: Bool }
```
Mascot = "Hilal", a friendly crescent-moon character drawn with pure SwiftUI shapes (crescent body, face, blush, tiny orbiting star). No image assets. Moods change the face/pose; celebrating bounces, sleepy has closed eyes + zzz, worried has raised brows.

### AppClock (`Sources/App/AppClock.swift`)
```swift
enum AppClock {
    static var offset: TimeInterval { get set }   // persisted in UserDefaults "debug.timeOffset"
    static var now: Date { Date().addingTimeInterval(offset) }
    static func dayKey(for date: Date) -> String  // "yyyy-MM-dd" local calendar
}
```

---

## 4. Screens

**RootView**: if `!settings.hasOnboarded` → OnboardingView, else TabView with 4 tabs: Today (house.fill), League (trophy.fill), Journey (map.fill), Settings (gearshape.fill). A 1-second timer in RootView drives countdowns and triggers `refresh()` on dayKey change; also refresh + reschedule notifications on `scenePhase == .active`.

**Onboarding** (home agent): single playful flow — mascot welcome, name field, location permission button, notification permission button, chunky "Let's go!" (sets `hasOnboarded`).

**Today / HomeView** (home agent):
- Top bar: greeting ("Assalamu alaikum, {name}"), StreakFlameView, XPChip.
- Daily-goal ProgressRing (todayXP/dailyGoal) + level pill.
- Mascot (~120pt) with speech bubble: countdown to next prayer, encouragement, mood logic: celebrating (within ~4s of a log), worried (open window unlogged, <30 min left), sleepy (before fajr / after isha+2h), happy (≥3 in-window today), else neutral.
- 5 prayer cards: name+emoji+time; per status: upcoming = dimmed w/ "Opens in 2h 14m"; open = highlighted card, live tier hint ("+30 XP if you pray now"), big ChunkyButton "I prayed 🤲"; logged = check + tier label + "+N XP", long-press to undo; missedWindow = muted, small "Make up (Qada) +5 XP" button.
- Celebration overlay on `celebration != nil`: dim background, confetti burst, mascot celebrating, "+N XP" fly-up; extra lines for Perfect Day / level-up / new badge / streak extended. Tap to dismiss (nil it).

**League / LeagueView** (league agent): gradient header "🌙 Crescent League" + "Resets in 3d 4h". Ranked rows (avatar emoji in colored circle, name, XP); your row highlighted with border + "(You)"; ranks 1–3 get 🥇🥈🥉 and gold-tinted promotion zone; subtle row reorder animation; footer mascot mini-comment based on your rank.

**Journey / StatsView** (stats-settings agent): level card (big level number, title, progress bar); Swift Charts bar chart of last-7-days XP; 5-week calendar heatmap colored by inWindowCount (0–5, gray→deep green); stat tiles (longest streak, perfect days, total prayers, total XP); badge grid (earned = colored + date, unearned = grayscale).

**Settings** (stats-settings agent): name edit; calc method + madhab pickers; "Use my location" toggle + current location name + today's computed times listed (verification); notifications toggle (handles denied state → link to system Settings); About. `#if DEBUG` Developer section: time-travel (+1h, +6h, +1 day, reset offset — writes `AppClock.offset` then `refresh()`), "Fill 3-week demo history", "Reset all data".

---

## 5. Design language (Duolingo-energy)

- `Theme.cream` background everywhere; white cards `cornerRadius 20`, soft shadow `(black 6%, y:3, blur:8)`.
- ALL text uses `Theme.rounded(...)` (SF Rounded). Big, bold, friendly. Numbers extra-large.
- ChunkyButton = Duolingo-style 3D press: filled capsule/rounded-rect with darker bottom edge (offset shadow layer), depresses 2–3pt on press, haptic on tap (`UIImpactFeedbackGenerator`).
- Springy animations (`.spring(response: 0.35, dampingFraction: 0.7)`), `.sensoryFeedback`/haptics on log + celebration.
- Color-code prayers subtly: fajr sky, dhuhr gold, asr green, maghrib coral, isha lilac.

---

## 6. project.yml (scaffold)

```yaml
name: SalahBuddy
options:
  bundleIdPrefix: com.haashim
  deploymentTarget: { iOS: "17.0" }
  createIntermediateGroups: true
packages:
  Adhan: { url: https://github.com/batoulapps/adhan-swift, from: "1.4.0" }
settings:
  base:
    DEVELOPMENT_TEAM: <grep from /Users/haashimameer/Documents/Apogee/FitNxt-iOS/FitNxt.xcodeproj/project.pbxproj; omit if not found>
targets:
  SalahBuddy:
    type: application
    platform: iOS
    sources: [Sources]
    dependencies: [{ package: Adhan }]
    info:
      path: Sources/Info.plist
      properties:
        UILaunchScreen: {}
        NSLocationWhenInUseUsageDescription: "SalahBuddy uses your location to calculate accurate prayer times."
        UISupportedInterfaceOrientations: [UIInterfaceOrientationPortrait]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.haashim.salahbuddy
        TARGETED_DEVICE_FAMILY: "1"
  SalahBuddyTests:
    type: bundle.unit-test
    platform: iOS
    sources: [Tests]
    dependencies: [{ target: SalahBuddy }]
schemes:
  SalahBuddy:
    build: { targets: { SalahBuddy: all } }
    test: { targets: [SalahBuddyTests] }
```
(Adjust Adhan version/product name if SPM resolution fails — verify with `xcodebuild -resolvePackageDependencies`. Import is `import Adhan`; method mapping: northAmerica → `.northAmerica`, etc.; madhab `.shafi`/`.hanafi`.)

Compile check (no signing needed): `xcodebuild -project SalahBuddy.xcodeproj -scheme SalahBuddy -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`

---

## 7. Edge cases & failure modes (must be handled)

1. **Location denied/unavailable** → fall back to fixed coords (Seattle default); schedule always computable. Settings shows which source is in use.
2. **First run** — empty store files: defaults everywhere, onboarding shown, schedule computes immediately with fallback coords.
3. **Day rollover while app open** — RootView 1s tick detects dayKey change → `refresh()` (new schedule, streak reconcile).
4. **Isha crossing midnight** — window end = next-day fajr; tier & dayKey come from the *schedule day*, not the tap's calendar day.
5. **Streak reconcile on launch/foreground** — walk days from `lastReconciledDayKey` to yesterday; incomplete day → consume freeze else reset streak. Never reconcile today.
6. **Timezone/DST travel** — schedule recomputed from current calendar each refresh; per-day Adhan computation handles DST.
7. **Double log / undo** — log() no-ops when already logged; undo reverses XP, bonuses, streak increment, but NOT badges (keep, simpler).
8. **Notification permission denied** — toggle reflects reality; deep-link to app settings.
9. **Demo history fill** — rebuilds profile (XP/streak/badges/perfect days) from generated logs so state stays consistent.
10. **Corrupt store JSON** — Store falls back to defaults rather than crashing.

## 8. Testing strategy

`Tests/GameEngineTests.swift` (XCTest, pure-logic only — no UI):
- Tier boundary math (exact ⅓ edges, before-start nil, after-end qada).
- Level formula + titles monotonicity.
- Streak: increment on 5th log, freeze consumption, reset when freezes exhausted, longestStreak tracking.
- Perfect-day detection incl. qada disqualifying.
- FriendSimulator determinism (same week key → identical XP at same instant) and monotonic weekly accrual.

Run: `xcodebuild test -project SalahBuddy.xcodeproj -scheme SalahBuddy -destination 'platform=iOS Simulator,name=<an available iPhone sim>'`. Build + tests must be green before the work is called done.
