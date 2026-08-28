# SPEC v5 — Friends on the home screen

Widgets and the Live Activity. Drafted 2026-08-26 (the "SalahBuddy v5 Widgets"
artifact), decisions settled with Haashim 2026-08-28 — see §9, none are open.
Follows the conventions of SPEC-V4.md; file/line references are against staging.

## §0 The ask

Three things, which turn out to be three different engineering problems:

1. **See your friends' posts without opening the app.** Mostly plumbing — the
   data is already on disk.
2. **Do something from the widget.** Possible, but the vocabulary is two
   controls wide, and it drags the auth layer into an extension.
3. **Watch it update as things happen.** Not possible for a home-screen widget
   in the way you'd hope. Genuinely possible with a Live Activity, which is
   arguably the better product anyway.

## §1 What already exists (v4 leverage)

- **The mirror is already the whole feed.** `circle.json` holds every friend's
  posts offline — name, emoji, prayer, tier, `loggedAt`, photo path. A widget
  needs the network for photo *bytes*, never for content.
- **Push already fires on the exact event.** `notify` fans out on a friend's
  first post per window.
- **`sendAPNs` already takes a push type** (`_shared/apns.ts` reads
  `opts.pushType ?? "alert"`). Live Activities need a different `apns-topic`
  suffix, and that's the only line that assumes a bare bundle id.
- **Every file path funnels through one property**: `Store.directory`
  (`Sources/Core/Store.swift`) — PhotoStore, BuddyPhotoCache, the mirror, the
  outbox and settings all derive from it.

## §2 The shared container (the prerequisite for everything)

A widget is a separate process with its own sandbox; it cannot read the app's
Documents. Point `Store.directory` at an App Group container and everything
below follows. One-time, idempotent migration on launch copies Documents into
the group container. The Supabase session moves to a shared keychain access
group (`<TeamID>.group.…`, team 852AXZ2B57) — needed only because of the nudge
button (§4).

Three teeth:

1. **App Groups and keychain access groups are different entitlements.** Both,
   on both targets, plus the App ID capability in the portal (the explicit App
   ID already exists — push and SIWA work — so this is a toggle, not a new
   identity).
2. **Existing sessions live under the old keychain group.** Read-once-and-
   re-store on launch, or the update silently signs everyone out.
3. **Two processes refreshing one rotating refresh token can invalidate each
   other.** The extension NEVER refreshes: expired token → don't call, deep-link
   into the app instead.

## §3 What the widget reads

The widget re-derives nothing — no GameEngine, no BuddySimulator, no Adhan in
the extension. The app writes `group/…/widget.json` on every mirror/state
change; the widget is a dumb renderer over it. Demo and real circles render
through the identical path.

```jsonc
{
  "writtenAt": "…", "mode": "real",
  "window": { "prayer": "asr", "dayKey": "…", "opensAt": "…", "endsAt": "…" },
  "you":    { "logged": false, "streak": 41 },
  "circle": {
    "prayedCount": 3, "memberCount": 5,
    "posts":   [ { "name": "Mina", "emoji": "🌸", "tier": "onTime",
                   "loggedAt": "…", "thumb": "a3f9…c1.jpg" } ],  // newest first, cap 4
    "waiting": [ { "userID": "…", "name": "Harun", "emoji": "🧢",
                   "nudgedThisWindow": false } ]                  // nudge targets
  }
}
```

**The photo problem.** Buddy photos download lazily today (only when a
`PhotoSquare` scrolls on screen), so the newest post is usually not on disk.
Fix in the APP: when a pull lands new posts, eagerly fetch the current window's
buddy photos into `BuddyPhotoCache` and write a ~300px thumbnail alongside
each. The widget stays offline, dumb, and under its memory ceiling.

| Family | Shows | Photos |
|---|---|---|
| systemSmall | current window, "3 of 5 prayed", emoji row | no |
| systemMedium | 4-up row of this window's posts + nudge button | yes |
| systemLarge | week grid or race-to-target scoreboard | yes |
| accessoryRectangular | "Asr · 3 of 5 prayed" (lock screen) | no |
| Control (Control Center) | "Nudge the circle" | no |

The lock-screen size is text-only and sidesteps §7's consent question entirely.

## §4 How interactive it can actually be

Widget vocabulary: `Button(intent:)`, `Toggle(isOn:intent:)`, tap targets that
deep-link, `ControlWidget`. No scrolling, paging, gestures, animation, or
self-driven timers. The intent runs headless; write the new state into the
container inside `perform()` before returning so the reload renders it.

**Nudge is the one that fits** — `kind: "nudge"` already exists in `notify`.
Logging your own prayer can NOT be a widget button (v2 made the photo
mandatory); that tap deep-links into the camera flow.

The nudge button is what forces the shared keychain: `Supa.client` uses the SDK
default `KeychainLocalStorage()` with no access group — invisible to other
processes. Fix: `KeychainLocalStorage(accessGroup:)` + the entitlement on both
targets. Do it in P1, together with the App Group.

## §5 Staying live

No API exists for "server pushes an update to a home-screen widget". Three
paths:

- **A — self-scheduled timeline** (`.after(…)`, ~40–70 reloads/day budget).
  Right for prayer-window boundaries (computable locally); wrong for friend
  events.
- **B — push → NSE → reload.** Add `mutable-content: 1` to the existing alert,
  ship a Notification Service Extension that calls `reloadAllTimelines()`.
  Widget is current ~a second after a friend posts. Best available for a
  home-screen widget.
- **C — push → Live Activity** (`apns-push-type: liveactivity`). The only path
  that reaches a surface without an extension hop, without the refresh budget,
  with the app closed. §6.

Silent push (`content-available: 1`) is a trap: throttled, no guarantee. Bonus
only, never the mechanism.

**The `not_first` wrinkle.** `notify` only pushes on the FIRST post per window
(`reason: "not_first"`) — correct for the tray, wrong for a widget that would
sit on a stale "3 of 5". Keep the collapsed alert exactly as is; add a separate
quiet reload-only push for subsequent posts, best-effort.

## §6 The Live Activity

A prayer window is a bounded event with known start/end and changing state —
precisely what ActivityKit exists for. Lock Screen + Dynamic Island:
"Asr · 2h 14m left · 3 of 5 prayed", filling in as the circle posts, ending
itself when the window closes. Push-to-start (`pushToStartToken`) lets the
backend BEGIN the activity when the window opens, app closed.

Constraints: no images over push (4 KB content state — emoji/names/counts/tier
colours only; photos only if already in the shared container); ~8h lifetime cap
(fine — per-window, not per-day); **Live Activity tokens are per-activity and
ephemeral** — `devices` is keyed on a stable `apns_token`, so this needs its
OWN table, not a column.

## §7 Invariants that must not break

- **retention** — buddy photos expire at 30 days and `BuddyPhotoCache.sweep()`
  matches; the widget reads that same cache and honours the same sweep
  (thumbnails included). Never a widget-only photo store.
- **reports** — `PhotoReports`' local hide is applied when `widget.json` is
  written. A hidden photo reappearing on the home screen is worse than it never
  having been hideable.
- **breakReason** — never enters `widget.json`. The mirror has no field it
  could travel in; keep it that way.
- **consent** — friends' faces on a home screen are a bigger step than in-app.
  The widget setting (photos / blurred / names-and-tier) ships the same phase
  photos do.

## §8 Phases (ordered by dependency)

- **P1 — shared container.** App Group + keychain access-group entitlements on
  both targets; `Store.directory` repointed with an idempotent launch
  migration; read-once-re-store for the session; deployment floor raised to
  iOS 18 (§9-04). Widget target declared in `project.yml` — never hand-edit
  the `.xcodeproj`. *Exit: an update preserves sign-in, photos and streak.*
- **P2 — the widget, static.** `widget.json` writer in `AppState`; small +
  medium + lock-screen families, names and tiers only; reloads on backgrounding
  and window boundaries. *Exit: shippable on its own.*
- **P3 — photos and the NSE.** Eager prefetch + thumbnails; NSE calling
  `reloadAllTimelines()`; `mutable-content: 1` on the existing alert; the quiet
  reload push for `not_first` posts; the privacy setting (default: photos,
  §9-02). *Exit: a friend posts, your home screen is current within seconds.*
- **P4 — Live Activity and the nudge.** Activity for the current window with
  push-to-start; new token table (migration); liveactivity push type in the
  fan-out; the `apns-topic` suffix; nudge button on the medium widget; Control
  Center control. *Exit: the window fills in live on the Lock Screen, and you
  can nudge Harun without opening anything.*

## §9 Decisions — SETTLED 2026-08-28, none open

1. **Scope: all of P1–P4 in one cycle.**
2. **Privacy default: photos ON**, with the day-one setting
   (photos / blurred / names-and-tier) shipping alongside them in P3.
3. **Demo mode: the widget renders the simulated circle too** — identical
   rendering path, and the widget works for every solo user from day one.
4. **Deployment target: raise the floor to iOS 18** (audience is TestFlight;
   Haashim's device is far past it). No availability gates for the Control.
