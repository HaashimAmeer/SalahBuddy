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
- Unique per `(user, day_key, prayer)`; **undo deletes the post**.
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
- Prayer-time reminders remain **local** notifications — no server needed.

## 7. Data model (Postgres)

| table | shape | notes |
|---|---|---|
| `profiles` | id = auth uid, name, avatar, member_kind | RLS: readable by circle-mates |
| `circles` | id, code (unique), created_by, created_at | code is the invite |
| `circle_members` | circle_id, user_id (unique), joined_at | trigger enforces ≤ 12 and one-circle-per-user |
| `posts` | id (client uuid), user_id, circle_id, day_key, prayer, tier, logged_at, jamaat, place_label, photo_path, travel_combined | unique (user_id, day_key, prayer) |
| `excused_days` | user_id, circle_id, day_key | no reason column, ever |
| `recovery_weeks` | user_id, circle_id, week_key, xp | opaque total (see §3) |
| `custom_challenges` | id, circle_id, creator, emoji, title, target, week_key | |
| `devices` | user_id, apns_token, updated_at | |

RLS everywhere: membership in the row's circle is the read predicate; you
write only your own rows.

**Timezones.** `logged_at` is UTC; `day_key`/`week_key` are client-local
strings. Three consequences, and they are not equally bad:

1. **Your streak breaks when you fly east — FIXED.** Prayers logged in Seattle
   carry a PDT `day_key`; land in Mumbai and that day can never reach five,
   because its evening happened at 38,000 feet. `reconcile` used to read that
   as an ordinary miss. It now skips `profile.travelDayKeys`, which
   `AppState.noteTimeZoneIfChanged` fills whenever the device's UTC offset
   moves by ≥ 3h (`GameEngine.travelOffsetThreshold` — above a DST jump and
   above any neighbouring zone, both of which must never trigger it). Both the
   departure and arrival day are marked. This only ever removes a penalty: a
   complete day still increments at log time.
2. **A `day_key` can be re-lived flying west — OPEN.** India → Seattle makes
   "2026-08-22" last ~36 hours, so a genuinely-prayed second Fajr is refused by
   `unique (user_id, circle_id, day_key, prayer)`. Rare, and the loss is one
   log rather than a streak.
3. **Cross-timezone circles render each member by their own day_key — OPEN,
   and still the accepted soft spot.** A shared grid where your column and a
   Seattle friend's are 12½ hours apart makes "who posted first for Fajr"
   meaningless.

2 and 3 both need the same thing: an explicit day model rather than an implicit
one, which cascades into `isDayComplete`, `isPerfectDay`, `xp(forDay:)`, the
streak walk, `weeklyXP` and the unique constraint above. That is a project, and
it is better designed against real data than guessed at. So `posts.utc_offset`
and `PrayerLog.utcOffset` are **captured now and read by nothing** — the field
is cheap to record and impossible to backfill, and every month without it is a
month of history the eventual fix cannot use.

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
