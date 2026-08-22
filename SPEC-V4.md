# SPEC v4 — Real circles: friend groups + backend

*Decisions marked ✅ are locked from the 2026-08-20/21 design session
(including the post-draft answers); 🅿️ are parked/trailing items.*

v4 turns the demo into the real thing: the circle becomes actual friends on
real devices, backed by a **Supabase** backend living in this repo under
`backend/`. Everything v3.9 built solo-first is the foundation — a new user
still starts solo with zero account friction, and the backend only enters the
picture at the social boundary.

## 0. Locked context (from this session)

- ✅ **Monorepo** — backend lives in `backend/`, iOS stays at the root.
  Path-filtered CI both ways (Xcode Cloud ignores `backend/**`; a Linux
  GitHub Actions workflow runs only for `backend/**`). The old "no hosted
  runners" rule was about macOS 10× minutes — Linux minutes are free-tier.
- ✅ **Stack: Supabase** — Postgres + Auth + Storage + Realtime + Edge
  Functions. Two projects mapped to the branch model: `staging` branch →
  staging project, `production` → prod project.
- ✅ **One shared circle, cap 12** — a circle is a single shared group; every
  member sees the same roster, week grid, and leaderboard. A user belongs to
  **at most one** circle (multi-circle is a v5 conversation).
- ✅ **Auth: Sign in with Apple + Google** (Supabase Auth providers).
- ✅ **Photos: circle-only, ~30-day server retention** — your own photos stay
  on-device forever (Memories unchanged); buddy photos are fetched and expire
  server-side after ~30 days.
- ✅ **Scoring stays on-device** — `GameEngine` remains the single source of
  truth. The server stores *facts* (posts, excused days); every client runs
  the same pure math over the same synced inputs, so scores agree without a
  second scoring implementation.

## 1. Accounts — auth at the social boundary

- ✅ **Solo users need no account.** Onboarding is unchanged (4 steps, local
  profile). The app works fully offline exactly as v3.9 ships.
- Sign-in is required only to **create or join a circle** — that's the moment
  the "Build your circle" CTA presents Apple/Google sign-in.
- Profile syncs on sign-in: name, avatar (emoji or profile photo), memberKind.
  Local XP/streak history stays local — it is *your* journey, not the
  server's.
- 🅿️ **Account deletion** (App Store requirement once accounts exist):
  Settings gains "Delete account" — removes profile, membership, posts, and
  photos server-side; local data survives so the app degrades back to solo.

## 2. Circles — create, invite, join, leave

- **Create**: first sign-in from the CTA creates the circle; creator is just
  member #1 (no admin role — the group stays flat and cozy).
- ✅ **Circles get an optional name + emoji** (defaults to "Your Circle" if
  skipped) — set at creation, editable by any member.
- ✅ **Invite by code first**: share sheet sends a message containing the
  6-character code; joining is sign in → enter code. Universal links
  (`…/join/<CODE>`) are added the day a domain exists — not on the critical
  path. Any member can invite. The v3.9 invite sheet becomes this share
  flow; the roster list remains only in demo mode.
- **Join**: opening the link (or typing the code) with the app installed →
  sign in → join if a slot is free (cap 12, enforced server-side). Joining
  mid-week shows your week-so-far posts to the circle (client uploads the
  current week's logs on join — mirrors v3.9's backfill decision).
- **Leave**: anyone can leave anytime; the app returns to solo mode with all
  local history intact. Posts you made stay visible to the circle until the
  week ends, then purge with the retention job.
- ✅ **Leave-only in v4** — no removing others. Avoids social drama and an
  admin-roles design; revisit if a real friend group actually hits the
  problem.
- **Demo mode**: `BuddySimulator` survives behind `BuildEnv` (DEBUG/TestFlight
  developer card) as "Demo circle" — useful for screenshots and testing, and
  mutually exclusive with a real circle.

## 3. What syncs — posts as facts

A **post** is the shareable fact of a logged prayer:

`(user, circle, day_key, prayer, tier, logged_at, jamaat, place_label?,
photo_path?, travel_combined?)`

- The client computes tier/XP with `GameEngine` before posting; `day_key`
  is the client-computed schedule day (the Isha-after-midnight rule travels
  with the post — the server never re-derives it).
- Unique per `(user, day_key, prayer, utc_offset)`, with a NULL offset reading
  as "any zone" — the zone is part of a prayer's identity since Phase 1, see
  §7.2; **undo deletes the post**.
- **Excused days** sync as a bare flag (circle sees the gentle "resting"
  state). The *reason* never leaves the device — period privacy is absolute.
- **Offline queue**: posts created offline upload on reconnect, in order,
  idempotently (client-generated UUIDs).
- **Leaderboard** = each client running `GameEngine.weeklyXP` over synced
  posts. Deterministic, no server math.
- ✅ **Recovery (dhikr/deeds) XP counts on the scoreboard, as an opaque
  weekly total** per user — keeps break/period folks competitive without
  revealing *what* anyone did. Locks the SCORING.md §dhikr ambiguity in
  favor of "counts, privately" (update SCORING.md §63 to match when built).
- **Time-travel guard**: the developer clock offset is forced to zero while a
  real circle is active (posting fictional timestamps to real friends breaks
  everything time-travel exists to test). Demo mode keeps full time-travel.

## 4. Photos

- Upload the existing downscaled JPEG (quality 0.7) to Storage at
  `circle_id/user_id/<uuid>.jpg`; the post carries the path.
- RLS: only circle members can read; only the owner can write/delete.
- A scheduled Edge Function deletes objects (and clears `photo_path`) after
  ~30 days; leaving/deletion purges immediately after the current week.
- Client caches buddy photos on disk; your own photos never leave `PhotoStore`
  semantics (server copy is just the share).
- 🅿️ **UGC minimum for App Store** (guideline 1.2): a "report" action on any
  buddy photo (emails/flags for review) + leaving as the block mechanism.
  Required before public App Store; can trail slightly behind TestFlight.

## 5. Group challenges & recap

- `ChallengeEngine` already computes progress statelessly from logs — it now
  reads synced posts instead of simulated outcomes. No engine changes.
- **Custom challenges sync**: creating one inserts a row the circle can see;
  progress/awards stay client-computed (same inputs → same results).
- Weekly recap gains a 🅿️ circle page (best-in-circle day, crown holder) —
  after the personal recap ships value first.

## 6. Live-ness & notifications

- **Realtime**: subscribe to the circle's posts channel while the app is
  open — the Today grid fills in live, replacing the sim's derived
  `loggedAt` reveal with the real thing.
- **Push (APNs)**: a `devices` table holds tokens; a DB-webhook Edge Function
  signs APNs JWTs directly (no third-party push service) for:
  - "📸 X posted first for Fajr" (the existing friend-activity toggle, now
    real — the v3.9 solo/circle copy split already handles both states)
  - invite accepted / member joined
  - ✅ nudges ship in Phase D — "Nudge your friends" sends a real push,
    rate-limited to one nudge per sender per recipient per prayer window
- **A post's push is scoped to the day it is about (Phase 2).** "X posted
  first for Fajr" used to go to every member of the circle regardless of where
  they were standing: a 5am Fajr in Mumbai woke a friend in Seattle at 4:30pm,
  twelve hours after their own Fajr, about a window that closed before their
  lunch. `devices.utc_offset` (migration `20260822000500`, written by
  `register_device` and refreshed on every foreground via `RemoteDevice`'s
  fingerprint) lets `notify` compare each recipient's local day against the
  post's `day_key` and drop the ones it has already gone stale for. Four rules
  hold it up:
  - **the window is anchored on the POSTER**, spanning `day_key` to the
    poster's own current local day — so nobody standing in the poster's zone is
    ever filtered, and an Isha logged after midnight (which carries yesterday's
    `day_key`) still reaches the same city.
  - **the recipient is judged on their SCHEDULE day, not their calendar day.**
    Before dawn those are different dates, so the window's top is stretched by
    one day for a recipient who is still in the night (`PRE_DAWN_SECONDS`, a
    flat four hours, since the function has no coordinates to compute a real
    Fajr from). Without it the poster's own allowance is an asymmetry: London
    posting Isha at 23:30 reaches everyone in London at 23:30 and nobody in
    Berlin at 00:30, the same open Isha window either side. The stretch can
    only add recipients, never remove one.
  - **unknown never means silence.** A NULL offset — every `devices` row
    written before the migration — is always notified, and a post with no
    `utc_offset` of its own filters nobody at all. 0 is a real offset (London
    in winter), so it can never stand in for "we don't know".
  - **nudges and joins are never filtered.** A nudge is aimed at one named
    person a human just picked out of a grid, and "X joined your circle" is not
    about a day. Only the post fan-out carries the rule.
- Prayer-time reminders remain **local** notifications — no server needed.

## 7. Data model (Postgres)

| table | shape | notes |
|---|---|---|
| `profiles` | id = auth uid, name, avatar, member_kind | RLS: readable by circle-mates |
| `circles` | id, code (unique), created_by, created_at | code is the invite |
| `circle_members` | circle_id, user_id (unique), joined_at | trigger enforces ≤ 12 and one-circle-per-user |
| `posts` | id (client uuid), user_id, circle_id, day_key, prayer, tier, logged_at, jamaat, place_label, photo_path, travel_combined, utc_offset | unique nulls not distinct (user_id, circle_id, day_key, prayer, utc_offset), + `posts_zone_wildcard` trigger (a NULL offset excludes a real one) |
| `excused_days` | user_id, circle_id, day_key | no reason column, ever |
| `recovery_weeks` | user_id, circle_id, week_key, xp | opaque total (see §3) |
| `custom_challenges` | id, circle_id, creator, emoji, title, target, week_key | |
| `devices` | user_id, apns_token, environment, notify_friend_activity, utc_offset, updated_at | `utc_offset` nullable forever (§6 — 0 is a real place); written by `register_device` |

RLS everywhere: membership in the row's circle is the read predicate; you
write only your own rows.

**Timezones.** `logged_at` is UTC; `day_key`/`week_key` are client-local
strings. Three consequences followed, and the third turned out to be two
questions wearing one label — only one of which was ever a defect:

1. **Your streak breaks when you fly east — FIXED.** Prayers logged in Seattle
   carry a PDT `day_key`; land in Mumbai and that day can never reach five,
   because its evening happened at 38,000 feet. `reconcile` used to read that
   as an ordinary miss. It now skips `profile.travelDayKeys`, which
   `AppState.noteTimeZoneIfChanged` fills whenever the device's UTC offset
   moves by ≥ 3h (`GameEngine.travelOffsetThreshold` — above a DST jump and
   above any neighbouring zone, both of which must never trigger it). Both the
   departure and arrival day are marked. This only ever removes a penalty: a
   complete day still increments at log time.
2. **A `day_key` can be re-lived flying west — FIXED (Phase 1, prayer
   identity).** India → Seattle makes "2026-08-22" last ~36 hours, and the
   second Fajr is a real prayer that used to be refused. Fixed by separating a
   prayer's IDENTITY from a day's GROUPING KEY, which was the one thing
   `day_key` was quietly doing twice.
   - **Grouping did not change, and that is the point.** `day_key` alone still
     drives `isDayComplete`, `isPerfectDay`, `xp(forDay:)`, `weeklyXP`, the
     streak walk and every grid column. Only IDENTITY gained the zone, and
     identity is asked in exactly two places: "have I already prayed this
     one?" (`loggedInstance`, and the same lookup behind undo) and "which log
     does this square draw?" (`cellLog`, live day only). Anybody who does not
     change zone sees byte-for-byte what v3.9 gave them — no migration, no
     setting, nothing to opt into.
   - **Identity is `(prayer, day_key, zone)`, compared with a TOLERANCE.**
     `GameEngine.isSamePrayerInstance` asks whether a log's stored `utcOffset`
     is within `travelOffsetThreshold` (3h) of the device's current one — the
     same three hours `isTravelShift` uses, because it is the same question
     asked twice. Exact equality is the obvious rule and it is wrong: DST moves
     the offset by exactly one hour with nobody going anywhere, and under
     equality every prayer already logged that day would come back offering to
     be prayed again.
   - **Window start was the other candidate identity, and it is worse.**
     Switching Asr madhab moves Asr's window by about an hour while the device
     sits still, and every Asr ever logged would stop matching the window now
     computed for it — the whole history rendering as unlogged. Anything built
     out of a one-hour-scale quantity breaks on the two things that routinely
     move an hour. Three hours is above both and below any crossing worth
     calling travel.
   - a ZONELESS log is a WILDCARD, not a third zone. It matches everything, so
     it can never be joined by a second log for the same prayer — on the client
     (`isSamePrayerInstance`), in the mirror (`CircleSync.upserted`) and on the
     server. Getting this wrong is not cosmetic: a v3.9 backfill writes the
     zoneless row and the same account's second device writes the zoned one,
     and the pair scores that prayer twice on every circle-mate's device.
   - the server key follows: `unique nulls not distinct (user_id, circle_id,
     day_key, prayer, utc_offset)` (migration 20260822000300) plus the
     `posts_zone_wildcard` trigger (20260822000400) for the pair no unique index
     can see — a NULL beside a real offset. It raises 23505 so the client's
     existing slot repair handles it, and it stays silent on the pairs the
     constraint already refuses, because `on conflict do nothing` can swallow a
     constraint violation and cannot swallow a trigger's exception. Mirrored by
     `CircleSync.slotKey` / `slotBucket`. On real offsets the server rule is
     deliberately LOOSER than the client's — a unique index cannot say "within
     three hours" — and it is a BACKSTOP, not the primary mechanism: the device
     decides what is a second prayer, and the constraint only catches the pairs
     no honest client would send. Looser is the safe direction, and it must not
     be tightened. An admitted duplicate is one wrong square; a server stricter
     than the client would REFUSE a real second prayer, and a refusal strands
     the outbox on a row it will retry forever.
   - one member's cell can only hold one of their two prayers, so the rule is
     written down rather than left to array order: the LATEST prayer that has
     actually happened, else the earliest one still to come
     (`CircleSnapshot.post(userID:dayKey:prayer:asOf:)`). Your own row answers
     the same question by identity on the day you are standing in and by
     grouping on any past day (`GameEngine.cellLog`) — the zone you are in today
     says nothing about the zone Monday was lived in.
3. **Push announced a post to people whose day had already moved on — FIXED
   (Phase 2, notification relevance).** This was the half of the old
   cross-timezone entry that reached out and touched people: a Seattle friend's
   Fajr arriving in Mumbai at 4:30pm, on a date Mumbai finished yesterday.
   `notify` now drops a post announcement for any recipient whose own local day
   has moved past the post's `day_key`, reading `devices.utc_offset` alongside
   `posts.utc_offset` (§6 has the exact rule, its ±1 day stretch, and why
   unknown never means silence). Silence is opt-out-shaped and permanent — a
   person who mutes the app after one 4:30pm Fajr alert is not coming back — so
   this half had to close first, and it closed without the grid needing a day
   model at all.
4. **The shared week grid shows each member their own day — INTENDED, not a
   defect.** The other half of that entry was filed as a bug and, examined, is
   the semantic the screen wants. A column means "this member's own
   2026-08-22", not a slice of absolute time, because the question the Circle
   screen asks is whether each of you kept your five on YOUR OWN day — not who
   reached Fajr first in UTC. Aligning columns by absolute time would split a
   traveller's day across two of them and draw one complete day as two broken
   ones, which is worse than the thing it fixes. The residual cost is real and
   named: an empty cell is drawn `missed` or `waiting` against the VIEWER's
   window for that prayer, not the poster's, so a friend several zones east can
   read as missed for a few hours before their own window has closed. It
   resolves itself the moment they post, and nothing scores off ordering — the
   weekly scoreboard ranks by XP, not by who logged earlier.

**Two product answers, and neither needed new logic.** Phase 1 raised two
questions that sound like they need a rule, and the existing code already
answered both:

- **A calendar date holding six prayers is ONE complete day.** `isDayComplete`
  counts DISTINCT prayers on the `day_key` (`Set(...).map(\.prayer)`), so the
  second Fajr earns its own XP and changes nothing about completeness — five
  distinct prayers is five distinct prayers whether the day held five logs or
  seven. `isPerfectDay` counts the same way.
- **A 36-hour day increments the streak ONCE.** `applyStreakIncrement` returns
  the profile untouched when `lastStreakDayKey == dayKey`, so a day already
  banked cannot be banked again by a prayer arriving on the far side of a
  flight.

Both were true before Phase 1 was written; they are recorded here because the
next person tempted to fold the zone into the GROUPING key needs to know they
were checked rather than assumed.

## 8. Client architecture

- New `Sources/Core/Sync/` — `supabase-swift` SPM package, a `CircleService`
  (auth, circle CRUD, post upload/fetch, realtime), and a local mirror of
  circle data persisted like everything else in `Store` (offline-first).
- `AppState` gains one seam: `activeBuddies`/grid/scoreboard read from a
  `CircleSource` that is either the simulator (demo) or the sync mirror
  (real). `GameEngine`, views, and the v3.9 solo logic don't change —
  `isSoloMode` stays `activeBuddies.isEmpty`.
- `project.yml`: add the supabase-swift package; `make lock` after.

## 9. Backend layout & CI (monorepo)

```
backend/
  supabase/
    migrations/*.sql      # schema + RLS, applied in order
    functions/            # Deno TS edge functions (push, retention cron)
    seed.sql              # demo/staging seed
  tests/                  # pgTAP or SQL assertions + function tests (Deno)
  README.md
```

- **Cloud-session dev loop**: the sandbox has no Docker, so `supabase start`
  is out — tests run against apt-installed Postgres with migrations applied
  via psql, and Deno unit-tests the functions. Full-stack verification
  happens against the **staging** Supabase project (CLI deploy from CI).
- **CI**: GitHub Actions (Linux, path-filtered to `backend/**`): apply
  migrations to a scratch Postgres, run tests, then `supabase db push` +
  `functions deploy` to staging (prod deploys only from `production`).
- Free-tier note: Supabase pauses free projects after ~1 week idle — the
  staging project may need a dashboard unpause after a quiet stretch.

## 10. Rollout phases

1. **A — Foundation** *(pure cloud-session work)*: migrations, RLS, auth
   config, CI + deploy pipeline. Exit: staging project accepts a signed-in
   user via a curl-level test.
2. **B — Circles**: iOS auth + create/join/leave behind the Developer card.
   Exit: two TestFlight phones in one circle, roster syncing.
3. **C — Posts**: upload/fetch/realtime + photos + offline queue. Exit: the
   Today grid fills in live between two phones; leaderboard agrees on both.
4. **D — Delight**: push notifications, custom-challenge sync, circle recap,
   report action. Exit: feature parity with the sim, for real people.

Each phase lands on `staging` → Xcode Cloud → TestFlight; the sim remains the
fallback demo throughout.

## Post-draft answers (locked 2026-08-21)

All five open questions were resolved and folded into the body above:
recovery XP **counts as an opaque total** (§3) · **leave-only** exits (§2) ·
circles get an **optional name + emoji** (§2) · **nudge push ships in
Phase D**, rate-limited (§6) · invites are **code-first**, universal links
whenever a domain exists (§2). Nothing blocks Phase A.
