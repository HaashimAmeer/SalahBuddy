# SalahBuddy v2 — "Circles" iteration (single source of truth)

Builds ON TOP of the existing v1 codebase at `/Users/haashimameer/Documents/SalahBuddy` (read SPEC.md for v1 rules; v2 OVERRIDES where stated). Core pivot from the design session: **buddy accountability via BeReal-style photo proof becomes the centerpiece**. Real camera for the user; a simulated 3-buddy circle (real backend next iteration). Keep streaks/XP/levels/celebrations/time-travel. Crescent League is REMOVED, replaced by the Circle tab. Mascot Hilal is demoted to onboarding/empty-states/celebrations only.

Design pivot: "BeReal but more simple, less dark" — Gen-Z soft green, friendly, lifting people up not tearing down, rounded corners, clean sans-serif (NOT rounded font), not visually dense, subtle crescent/star accents.

---

## 1. Rule changes (v2 overrides)

### Logging
- **In-window logging REQUIRES a photo.** Tapping the prayer CTA opens the camera (single side, no dual BeReal capture). Photo saved locally; the log records it. XP tiers unchanged: onTime 30 / prayed 20 / lastCall 10 (earlier = more, as before).
- **Jamaat bonus**: after capture, an optional "Prayed in jamaat 🕌" toggle → +5 XP, tracked for challenges.
- **Qada (after window, same day)**: tap-only, NO photo, **10 XP** (was 5 — "half points"). Never appears in photo grids; appears in data views colored blue.
- **Missed framing**: show "You missed out on +30 XP" style copy (positive tone, no shaming).
- **Excused days**: a day can be marked excused ("Can't pray today") — sickness, travel, menstruation. Streak is PRESERVED (neither increments nor resets, consumes no freeze), no XP, no perfect day, reconcile skips it. Cap: **10 excused days per calendar month**. Shown lilac with a moon glyph in data views. Stored as `profile.excusedDayKeys: Set<String>`.
- Undo still allowed for in-window logs (removes photo file too). Old persisted logs keep their stored xp values (no rewrite).

### The circle (simulated)
- Members: **You + Mina 🌸 (consistency 0.92) + Harun 🧢 (0.75) + Haifa 📚 (0.85)**.
- BuddySimulator REPLACES FriendSimulator (delete it + league API): for each buddy × day × prayer, a deterministic outcome — `inWindow(tier, loggedAt within window)`, `qada(at)`, or `missed` — from a SplitMix64 RNG seeded by FNV-1a("name|dayKey|prayer"). A buddy's post becomes visible only once `AppClock.now >= loggedAt` (the grid fills in live through the day). Buddy "photos" are deterministic SwiftUI illustrations (seed from same RNG), NOT real images.
- Weekly circle scores are computed from these same simulated logs (grid and scoreboard must always agree).

### Challenges (new system, hard-coded definitions)
Progress computed statelessly from logs (yours + buddies'); completion awards XP once (record in `profile.challengeCompletions: [String: Date]`; weekly/repeatable ones key by `id|weekKey`).
Personal: `fullday` Full Day — all 5 in-window in one day (+20); `fajr3` Dawn Patrol Run — Fajr in-window 3 days in a row (+30); `week7` Perfect Week — all 5 logged every day for 7 days (+100); `jamaat3` Together — 3 jamaat logs (+30); `goal3` (only if `settings.hardestPrayer` set) — that prayer in-window 3 days in a row (+40).
Group (weekly): `isha3` Circle Isha Streak — EVERY member logs Isha 3 days in a row (coop, +50); `race300` Race to 300 — first member to 300 weekly XP (winner crown on scoreboard, +30 if you win); `circleperfect` Circle Perfect Day — every member full-day on the same day (coop, +50).

### Onboarding addition
New goal-setting step: "Which prayer is hardest for you?" (picker incl. "none") → `settings.hardestPrayer: Prayer?` → seeds `goal3` challenge.

### Notifications copy
Prayer-in: "📸 {Prayer} just came in — be the first in your circle to post!" Last-call unchanged.

---

## 2. Design system v2 (Theme rewrite — keep old token NAMES as aliases so v1 views compile, restyle visuals)

```swift
enum Theme {
    // v2 tokens
    static let bg        = Color(hex: 0xECF6EE)   // soft mint background
    static let surface   = Color.white
    static let inkDeep   = Color(hex: 0x16382A)   // dark green primary text
    static let inkMuted  = Color(hex: 0x5F7A6C)
    static let green     = Color(hex: 0x2BAE66)   // primary action
    static let greenSoft = Color(hex: 0xCDEBD8)
    static let gold      = Color(hex: 0xF5B722)   // XP/streak only
    static let qadaBlue  = Color(hex: 0x5B8DEF)
    static let amber     = Color(hex: 0xF2A65A)   // lastCall
    static let lilac     = Color(hex: 0xA98BDB)   // excused
    static let mist      = Color(hex: 0xC9CFCB)   // missed (NEVER red)
    // legacy aliases (cream→bg, card→surface, ink→inkDeep, inkSoft→inkMuted, greenDark, coral→amber, sky→qadaBlue)
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font   // .system, default design
    static func rounded(...) // keep as alias to sans so v1 call sites compile
}
```
Cards: radius 22, flat soft shadow (black 5%, y2 blur 10). Buttons: soft chunky (filled capsule, subtle pressed scale 0.97 + darker tint — flatter than v1's 3D edge). Density: generous whitespace. Subtle crescent/star accents in headers & empty states. Data-grid color language everywhere: deep green = onTime, mid green = prayed, amber = lastCall, blue = qada, lilac+moon = excused, mist gray = missed.

---

## 3. New cross-agent contracts (in core, implemented by design-core agent EXACTLY)

```swift
struct CircleMember: Identifiable, Equatable { let id: String; let name: String; let emoji: String; let isYou: Bool }
enum PostContent: Equatable { case photo(filename: String); case illustration(seed: UInt64) }
enum GridEntryState: Equatable { case waiting; case posted(PostContent, tier: LogTier, at: Date); case qada(at: Date); case missed; case excused }
struct GridEntry: Identifiable { let id: String; let member: CircleMember; let state: GridEntryState }
enum GridCellState: Equatable { case inWindow(LogTier); case qada; case missed; case excused; case future }
struct MemberWeekRow: Identifiable { let id: String; let member: CircleMember; let days: [[GridCellState]] }  // 7 days × 5 prayers, Mon-first
struct ChallengeProgress: Identifiable { let id: String; let title: String; let detail: String; let emoji: String
    let isGroup: Bool; let target: Int; let current: Int; let completedAt: Date?; let rewardXP: Int }
struct DayPhotoSummary: Identifiable { let id: String; let date: Date; let photoFilenames: [String]; let recap: DayRecap }

enum PhotoStore {  // Sources/Core/PhotoStore.swift
    static func save(_ image: UIImage, dayKey: String, prayer: Prayer) -> String   // downscale max 1200px, JPEG 0.7, Documents/photos/
    static func load(_ filename: String) -> UIImage?
    static func delete(_ filename: String)
    static func demoImage(seed: UInt64) -> UIImage   // UIGraphicsImageRenderer gradient/pattern card (for DEBUG demo data + sim-camera fallback)
}
```

### AppState v2 surface (additions/changes; v1 surface otherwise kept)
```swift
// CHANGED
func log(_ prayer: Prayer, photoFilename: String?, jamaat: Bool)   // in-window path (UI guarantees photo; nil tolerated)
func logQada(_ prayer: Prayer)                                     // replaces qada path of old log()
// REMOVED: leaderboard(), leagueResetDate(), FriendSimulator
// NEW
var circleMembers: [CircleMember]                                  // you first? NO — you LAST in grid order; isYou flag set
func gridEntries(for prayer: Prayer, dayKey: String) -> [GridEntry]
func weeklyScores() -> [(member: CircleMember, xp: Int)]           // sorted desc
func weekRows() -> [MemberWeekRow]                                 // current week, all members
func challenges() -> [ChallengeProgress]                           // personal + group (isGroup flag)
var isTodayExcused: Bool
func setTodayExcused(_ on: Bool)                                   // enforces 10/month cap (silently no-ops at cap; expose excusedUsedThisMonth for UI)
var excusedUsedThisMonth: Int
func photoSummaries(monthOf date: Date) -> [DayPhotoSummary]
var missedOutXPToday: Int                                          // foregone XP from missed windows today
```
`LogResult` unchanged. Celebration flow unchanged. Old `log(_:)`/`undoLog` semantics: undo deletes the photo file.

### New component contracts (components agent implements EXACTLY; Home/Circle/Journey call blind)
```swift
struct PrayerPhotoGrid: View { let entries: [GridEntry]; let compact: Bool }   // 2-col grid; waiting = dashed square w/ avatar emoji; posted photo shows image/illustration + name + timestamp + tier dot; qada = blue tile "Made up"; missed = mist tile; excused = lilac moon tile
struct PhotoSquare: View { let entry: GridEntry; let size: CGFloat }
struct IllustratedPrayerCard: View { let seed: UInt64 }   // deterministic cozy prayer-space illustration (mat, rug patterns, window/lamp variants) from seeded values
struct WeekGridView: View { let rows: [MemberWeekRow] }   // group data grid: member rows × 7 day-columns of 5 mini squares, GridCellState colors per §2; legend included
struct ChallengeCard: View { let progress: ChallengeProgress }   // emoji, title, progress bar current/target, reward chip, done state
struct CameraCaptureView: View { let onCapture: (UIImage) -> Void; let onCancel: () -> Void }
// CameraCaptureView: UIImagePickerController(.camera) wrapper; if camera unavailable (simulator) show fallback UI with "Use a demo photo" (PhotoStore.demoImage) and PHPicker option
```
v1 components kept (MascotView, StreakFlameView, ConfettiBurstView, ChunkyButton, ProgressRing, XPChip, BadgeIcon) — restyled to §2, signatures unchanged. ChunkyButton becomes soft-chunky per §2.

---

## 4. Screens v2

**Tabs**: Today (house.fill) · Circle (person.2.fill) · Journey (map.fill) · Settings (gearshape.fill).

**Today (rewrite, home agent)** top→bottom:
1. Compact header: date + greeting, StreakFlameView, XPChip. Below it a slim **prayer-times strip** (5 chips: name+time, current one highlighted) — at-a-glance proactive view.
2. **Current prayer block** (the centerpiece): prayer name + emoji, window countdown, then `PrayerPhotoGrid` (circle's squares for THIS prayer, filling in live). If you haven't posted: your square is the CTA — tap → `CameraCaptureView` sheet → jamaat toggle confirm → `PhotoStore.save` → `appState.log(prayer, photoFilename:, jamaat:)` → celebration (confetti kept). Live tier hint "+30 XP if you pray now". Pre-fajr, yesterday's open Isha is the current block (existing previousIshaWindow machinery; grid uses yesterday's dayKey).
3. **Make-up section** directly beneath the current block (same placement as v1 qada): today's passed-unlogged prayers as small rows — "Make up {prayer} (+10 XP)" tap-only, plus "You missed out on +N XP" gentle copy.
4. **Earlier today**: previous prayer blocks collapsed (tap to expand their compact PrayerPhotoGrid).
5. Upcoming prayers dimmed at bottom. A quiet "Can't pray today?" link → confirm dialog → `setTodayExcused(true)` (shows excused banner state instead of CTA; respects monthly cap with count shown).
NO mascot section on Today.

**Circle (new, circle agent — League folder deleted)**:
- Header "Your Circle ☪️" + week countdown.
- Weekly scoreboard: rows (emoji avatar, name, weekly XP bar, crown 👑 on race300 leader), you highlighted.
- **Group week grid**: `WeekGridView` (the "group data for this week" sticky — rows per member, colored mini-squares).
- Group challenges: `ChallengeCard` list (isha3, race300, circleperfect) with live progress.
- Empty/loading states may use small MascotView.

**Journey (extend, journey agent)**:
- Keep level card, 7-day XP chart, stat tiles, badges.
- NEW **Photo calendar**: month grid; each day shows your first photo as a thumbnail (tap day → sheet with that day's photos + per-prayer detail), powered by `photoSummaries(monthOf:)`. BeReal-memories vibe.
- Heatmap recolored to the v2 grid language (green/blue/lilac/mist).
- NEW Personal challenges section: `ChallengeCard` list.

**Settings (restyle, journey agent)**: v1 content restyled; add excused-days row ("Excused days this month: n/10"); Developer section gains nothing new EXCEPT fillDemoHistory must now also create demo photos (PhotoStore.demoImage) for ~70% of generated in-window logs and leave buddy history to BuddySimulator naturally.

**Onboarding (home agent)**: restyle to v2 + insert goal-setting step (hardest-prayer picker incl. "none") before permissions. Mascot welcome stays.

---

## 5. File ownership v2

| Owner | Files |
|---|---|
| **design-core** | Theme.swift (v2 + aliases), Models.swift (additive), GameEngine.swift (qada=10, excused-aware streak/reconcile), BuddySimulator.swift (NEW; delete FriendSimulator.swift), ChallengeEngine.swift (NEW), PhotoStore.swift (NEW), AppState.swift (v2 surface), Store.swift (migration-tolerant), RootView.swift (Circle tab), project.yml (NSCameraUsageDescription, NSPhotoLibraryUsageDescription), placeholder stubs: Views/Circle/CircleView.swift + new component stubs with exact §3 signatures, Tests/* updates |
| **home** | Views/Home/*, Views/Camera/* (capture sheet flow around CameraCaptureView), Views/Onboarding/* |
| **components** | Views/Components/* (restyle v1 set + implement §3 new set incl. CameraCaptureView) |
| **circle** | Views/Circle/* |
| **journey** | Views/Stats/*, Views/Settings/*, Sources/Core/NotificationManager.swift (copy update) |
| **integration** | anything |

Same hard rule: only touch what you own; work around missing APIs with extensions in your own files.

---

## 6. Edge cases & failure modes (v2 additions)

1. **v1 data migration**: existing logs.json/profile.json/settings.json MUST still decode (new fields optional/defaulted). Old qada logs keep stored xp=5; only NEW qada logs get 10.
2. **No camera (simulator) / permission denied**: CameraCaptureView falls back to demo-photo + library picker; log flow never dead-ends. Camera permission denial mid-flow → graceful sheet message + fallback options.
3. **Photo save failure** (disk): log still records with photoFilename nil rather than losing the prayer.
4. **Excused day already has logs**: allowed — logs keep their XP; excused only affects streak/reconcile display for unlogged slots. Unmark restores normal rules. Cap reached → link disabled with "n/10 used".
5. **Buddy determinism across time-travel**: jumping AppClock back/forward must re-derive identical buddy posts (pure functions of dayKey — no caching keyed by wall clock).
6. **Isha-past-midnight**: current-block grid and buddy posts use the schedule day's dayKey (yesterday) — both for you and buddies.
7. **Week boundaries**: weekly scores/challenges use Mon-start local weeks; Sunday-night Isha logged after midnight Monday belongs to Sunday's dayKey → previous week.
8. **Undo with photo**: deletes the file; grid returns to CTA state; jamaat bonus reversed.
9. **Demo history**: generated photos must not collide with real filenames (prefix demo-).
10. **Large photo memory**: grids load thumbnails lazily; never hold full-res UIImages in lists (PhotoStore caps at 1200px on save; grid squares render at small sizes).

## 7. Testing strategy

Update/extend `Tests/GameEngineTests.swift` (+ new test files as needed), all pure-logic:
- Qada XP now 10; in-window tiers unchanged; jamaat +5 accounting.
- Excused day: streak preserved across excused gap, no freeze consumed, monthly cap counting (calendar-month rollover), perfect-day impossible.
- BuddySimulator: determinism (same inputs → same outcomes/timestamps/seeds), posts hidden before loggedAt, visible after; weekly score equals sum over that week's outcomes.
- ChallengeEngine: fajr3 consecutive logic (gap resets), isha3 requires ALL members, race300 winner identification, completion awarded once (weekly re-award next week for group weeklies).
- Migration: decoding a v1-shaped PrayerLog JSON fixture (no photoFilename/jamaat) succeeds.
Build green per SPEC.md §6 command + full test pass required before done.
