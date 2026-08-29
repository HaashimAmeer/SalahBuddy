# v4 punch list — what still needs a human or a device

Everything in SPEC-V4 is built and on `dev/v4`. This is the honest list of what
a cloud session **could not** verify, split by whether it needs a dashboard, a
signature, a real phone, or a decision from you.

What *was* verified, so you know where the line is:

- **Backend, locally and in CI**: 27/27 SQL assertions against a real Postgres 16
  (negative-tested by mutating the schema 21 ways and confirming each mutation
  was caught), 55/55 Deno tests, `deno check` clean.
- **Backend, against the live staging project**: migrations applied and edge
  functions deployed successfully, and the smoke proofs scored **53 passed, 0
  failed** over HTTP — sign-up/sign-in, `create_circle`, `join_circle`,
  cross-circle isolation, and anonymous reads denied **401 by the deployed
  database** on all ten granted tables, probed both empty and populated. RLS
  holds where it counts.
- **iOS**: builds and passes its unit tests on every push (GitHub macOS runners).

Nothing below is a known defect. It is the set of claims that only a device, a
dashboard, or you can settle.

---

## 1. Phase A's stated exit criterion — MET

SPEC-V4 §10 wants "staging accepts a signed-in user via a curl-level test".
As of `9669ad0` the smoke job scores **53 passed, 0 failed** against the live
project on every push to `staging`, so this is settled and stays settled.

- [x] ~~Staging → Authentication → Email → "Confirm email" OFF~~ — done, and
      the run proves it took: three throwaway users signed up and received
      sessions with no confirmation step. (The toggle lives in the project-level
      **User Signups** block at the top of Sign In / Providers, not inside the
      Email provider dialog, and has its own Save button.)
- [x] ~~Domain rejected by Supabase's validator~~ — settled. `@example.com` is
      refused outright; the default is now `salahbuddy.app`, which the live
      project accepts. `SUPABASE_STAGING_CI_EMAIL_DOMAIN` overrides it if that
      ever changes.

What the 53 assertions actually establish, so the number means something:

- The publishable key alone reads **nothing** from `posts`, `profiles`,
  `circles`, `circle_members`, `excused_days`, `recovery_weeks`,
  `custom_challenges`, `devices`, `nudges` and `reports` — every table carrying
  a grant to `authenticated`, each tried both with the apikey alone and with an
  anon bearer, and run **twice**: once against empty tables and once with a real
  circle, profile, membership and post live. The second pass is the one that
  proves anything; a 401 from an empty table proves only that the endpoint
  answers. That table list is pinned to SQL test 12's RLS sweep so the two
  assertions can't drift apart.
- A signed-in user creates a circle, gets a 6-char code from the unambiguous
  alphabet, and a second user joins with it and sees exactly 2 members.
- A third user's unrelated circle is **invisible**: user B cannot read C's post,
  B's feed is empty, and B sees exactly one circle. That is RLS refusing, not a
  `where` clause filtering.

The job still fails loudly with dashboard instructions if any of this regresses,
which is deliberate: a green tick that proved nothing is the one outcome it must
never produce.

## 2. Dashboard settings to confirm

- [x] ~~**Google provider → Authorized Client IDs**~~ must list
      `923951498597-445nb4q5o5k66imnbbul70h88s7bct72.apps.googleusercontent.com`.
      VERIFIED in the dashboard 2026-08-27 (buildorder session) — was already
      configured; the box just never got ticked.
      GoTrue checks the ID token's `aud` against that list; a mismatch fails
      sign-in with a message that does not obviously say why.
- [x] ~~**APNs secrets**~~ — VERIFIED 2026-08-21, by arithmetic rather than by
      eye. `supabase secrets list` prints a SHA-256 of each value, so:
      `APNS_BUNDLE_ID` hashes to exactly `sha256("org.amacvoters.salahbuddymock")`
      (no trailing newline), and `APNS_TEAM_ID` to `sha256("852AXZ2B57")`, which
      is `DEVELOPMENT_TEAM` in `project.yml`. All four `APNS_*` are present.
      This mattered because every delivery path logs-and-skips on a bad value,
      so a wrong bundle id would have degraded silently into "push just doesn't
      work".

## 3. Signing

- [x] ~~**The first build may fail code signing once**~~ — CONFIRMED and
      resolved locally on 2026-08-21. A Release archive failed with
      "Provisioning profile *iOS Team Provisioning Profile: \** doesn't include
      the Push Notifications capability"; retrying with
      `-allowProvisioningUpdates` regenerated the stale DISTRIBUTION profile and
      the archive succeeded.

      Two things worth keeping. The App ID is fine — the *development* profile
      already carried `aps-environment` and `applesignin`, and a profile can
      only carry entitlements its App ID grants, so that settles it. And the
      failure is distribution-only: a device build would have worked and hidden
      this entirely.

      Also verified rather than assumed: exporting the archive with the
      `app-store-connect` method produces an ipa whose `aps-environment` is
      **production** (rewritten from `development`) with `beta-reports-active`
      set. Push entitlements will be right in a TestFlight build.
- [x] ~~Optional, saves compute hours: the Xcode Cloud **Test** action still
      uses the multi-device "Recommended iPhones" alias.~~ DONE — verified
      2026-08-27: SalahBuddyMock's Test action is a single destination, saved
      Aug 21. (One nuance since: `SavedPlacesTests` is no longer "pure logic" —
      it uses the test host's real Documents directory as its persistence seam,
      snapshotting and restoring `settings.json`/`profile.json`.)

## 4. Device-only — cannot be exercised by any CI

Sign-in, push and photo sync have no simulator path. In rough dependency order:

> **`backend/tests/fake_buddy.sh` covers the two-phone items with one phone.**
> As of 2026-08-27 it leads with `new`: the throwaway account creates its OWN
> circle and prints the invite code for your phone to join, so nothing test-ish
> ever lands in your real circle by default. `join <CODE>` (your circle, the
> sharpest §4 check) still exists but is eyes-open — it echoes what it is about
> to do and makes you type the code back — and `leave`/`cleanup` are the undo.
> `status` prints the XP total your leaderboard must agree with, which is the
> Phase C check. Note the one-circle rule: to join the buddy's circle your
> phone must first leave yours (gear ▸ Leave), and the script says so.
>
> It exercises the server contract and YOUR phone's half of the conversation.
> It says nothing about how a second real iPhone renders things, so the items
> below are narrowed, not deleted.

- [ ] **Sign in with Apple** on a real device. This is the one to watch: the
      nonce is the only part of v4 that can fail *exclusively* on hardware. The
      client hands the provider `sha256Hex(raw)` and Supabase the raw string,
      verified against the GoTrue source (`token_oidc.go` computes
      `sha256hex(params.nonce)` and compares it to the ID token's claim). If it
      fails with **"Nonces mismatch"**, tell me — do not work around it.
- [ ] **Google sign-in** on a device. GoogleSignIn 9.2.0 accepts a custom nonce,
      so the original "Google can't supply one" worry does not apply at this
      version. If it *still* fails nonce validation, the dashboard's
      **"Skip nonce checks"** toggle is the fallback and only you can flip it.
- [ ] **Two phones, one circle** (Phase B exit): create → share the code →
      join → both rosters agree.
- [ ] **The Today grid fills in live** between two phones, and **both
      leaderboards show the same numbers** (Phase C exit). Disagreeing
      leaderboards would mean the synced posts are not scoring identically on
      both devices — the single most important thing to eyeball.
- [ ] **Photos**: your photo uploads; the other phone downloads and renders it;
      your own photos still appear in Memories and theirs never do.
- [ ] **Push** (needs TestFlight — production APNs): "X posted first for Fajr",
      member-joined, and a nudge. Check a nudge twice reads as "already nudged"
      rather than an error.
- [ ] **Offline**: airplane mode, log several prayers, undo one, reconnect.
      Everything should arrive in order with the undone one absent.
- [ ] **Leave a circle**: local streak, XP and photos all survive; the app
      returns to solo.
- [ ] **Delete account**: server rows go, local history stays.
- [ ] **Report a buddy photo**: it disappears immediately for you.

## 5. Decisions — SETTLED 2026-08-21/22

- [x] ~~**The master Notifications switch blocks push registration entirely.**~~
      DECIDED: the switch stays absolute — joining a circle never forces a
      permission sheet on someone who turned notifications off — but the dead
      end is no longer silent. `CirclePushHint` appears on the Circle screen in
      a REAL circle when notifications are off, and is dismissible for good
      (`AppSettings.circlePushHintDismissed`). It distinguishes the two states
      that were previously identical dead ends: someone who tapped "Don't Allow"
      cannot be re-prompted by iOS and is routed to system Settings, while
      someone who merely SKIPPED the onboarding card is still `.notDetermined`,
      so "Turn on" genuinely prompts.
- [x] ~~**`announcePost` does not gate on the sender's own
      `notifyFriendActivity`.**~~ DECIDED: leave it ungated. It is a RECEIVING
      preference applied per recipient, so gating the sender would silence
      friends who did opt in. No code change.
- [x] ~~**Circle size differs by mode.**~~ DECIDED, and the premise was wrong.
      **The cap is now 12 total, and demo matches exactly (11 friends + you).**
      There was never a technical reason for 8 — it came from a v2/v3 comment
      about the SIMULATED circle, which v4 inherited without re-deriving and
      reinterpreted as 8 seats rather than 8 friends. That is the whole origin
      of the demo/real off-by-one this section used to defend as deliberate.
      12 seats a family or a masjid friend group and stays inside what the
      35-day reconciling pull was built for (~1,400 posts -> ~2,100).
      Migration `20260822000100_circle_cap_12.sql`.
- [x] ~~**No production Supabase project.**~~ DECIDED: stay deferred until v4 is
      validated on a device. Unchanged from §6.

## 6. Deferred, with reasons

- **No production Supabase project.** The free tier caps the account at two
  active projects and both slots are taken, so `backend.yml`'s production deploy
  is deliberately unwired rather than referencing secrets that do not exist.
  Wiring it is a copy of `deploy-staging` with the branch and secret names
  swapped — and leave the smoke job pointed at staging, since it signs up
  throwaway users and posts rows.
- ~~**`delete_account()` leaves the `auth.users` row.**~~ SHIPPED 2026-08-27:
  the `sweep-orphans` edge function (service-role only, report-by-default,
  conservative ANDed keep-rules) — see §8 for the two human steps that arm it.
- ~~**Retention is not scheduled.**~~ SHIPPED 2026-08-27:
  `.github/workflows/maintenance.yml`, nightly 09:17 UTC + `workflow_dispatch`,
  drains retention then runs the orphan sweep. Blocked on one secret — §8.
- **Universal links** (`…/join/<CODE>`) wait on a domain existing. Invites are
  code-first, as §2 specifies.

---

## 7. Shipped since the list was last accurate (2026-08-21/22)

Recorded here because this file is the continuity document and it went stale.

**TestFlight compliance.** `ITSAppUsesNonExemptEncryption: false` now ships in
`project.yml`. Every upload used to arrive as "Missing Compliance" needing a
manual click, and — what looked like a second bug — **no tester group was
assigned either**. One cause: App Store Connect will not RELEASE a build to
testers until the export question is settled, so an unanswered build never
reaches the internal group. **UNVERIFIED: build 22 is the first to carry it.**

**Day one no longer opens with a bill.** Windows that closed before
`profile.joinedAt` are `PrayerStatus.beforeJoining` — no "you missed out on
+120 XP", no "Missed" labels. They stay make-up-able at the normal qada +5,
with the header asking "Already prayed today?" instead. The rule already
existed for circle members (`gridEntries` gates on their joinedAt); it was
simply never pointed at you.

**Good deeds un-tick.** `GameEngine.recoveryEarnedAfterUndo` — the reversal
cannot be `totalXP -= deedXP` (a deed ticked past the cap earned nothing) nor a
recompute (the cap SHRINKS as prayer XP arrives, so banked XP would be
stripped).

**Perf.** Onboarding stutter: the step change was animated twice and the
keyboard's dismissal was being re-timed to our spring — invisible on the
Simulator because it defaults to a connected hardware keyboard. `HomeView.body`
called `currentTodayBlock` three times per second. `RootView` held the 1s
heartbeat as its own `@State`, re-evaluating the whole 5-tab shell every second;
now `AppClockProvider`.

**Tour.** Card sat at a screen edge rather than beside its target; oversized
targets are no longer ringed; 7 steps down to 4; one tap on Next was running
three animations. **Not device-verified.**

**Asr madhab toggle** replaced with `SegmentedChoice` — `.pickerStyle(.segmented)`
rendered grey-on-grey-on-grey against the mint.

**Timezones — the big one.** See SPEC-V4 §7 for the full record.
- Eastward streak loss FIXED (`profile.travelDayKeys`, skipped by `reconcile`,
  3h threshold chosen so DST never trips it).
- Westward re-lived day FIXED: identity is now `(dayKey, prayer, offset within
  tolerance)`; grouping is untouched, so nothing changes for anyone who does not
  fly. Migrations `…000300`/`…000400`.
- Cross-zone push relevance FIXED: `notify` compares local clock readings, not
  just dates. Migration `…000500`.
- The shared-grid presentation question is recorded as INTENDED, not a defect.

~~**Known gap:** "nudges and joins are never filtered" is enforced only by which
call sites pass `relevance`, and `notify/index.ts` exports nothing, so there is
no test for the wiring.~~ CLOSED 2026-08-27: handlers live in
`notify/handlers.ts` (index.ts is `Deno.serve` and nothing else), and
`tests/deno/notify_test.ts` drives all three kinds through a PostgREST-shaped
fake (`fake_supabase.ts`, projection-aware) — the §6 fan-out table, the
friend-activity toggle, and the local-clock rule all have failing mutations.

**Local tooling:** `deno` is installed (brew, 2026-08-27). `run_sql_tests.sh`
needs `PGHOST=/tmp PGPORT=5432 PGUSER=haashimameer PGDATABASE=postgres`.

Current suites (2026-08-28): **646 iOS, 32 SQL, 147 Deno.** The one local run
of the v5-cycle merge had 2 failures, both test-fixture bugs in never-executed
agent tests (a misread shared fixture; random UUIDs across two fixture calls);
both repaired — the repaired pair re-verifies on CI's runners, not this Mac.

---

## 8. Shipped 2026-08-27 — the build-order batch, and what it needs from you

One session cleared the remaining build-order items (each built by an agent,
adversarially reviewed, and re-reviewed): the v4.1 saved-places model + the
management sheet (verified rendering on the simulator), `AppState` saved-places
tests, the race-XP single currency + the undo/freeze receipt, the
orphaned-photo fix (the lapsed window silently ACCEPTS the log as qada and
drops the photo — both leak paths closed by one pure rule,
`GameEngine.isPhotoOrphaned`), push receipts (`AppDelegate.didReceive` existed
for nothing before — a tapped push was never seen) + roster-refresh-on-join
with a 10-minute reconcile floor, `fake_buddy.sh` circle hygiene, the notify
wiring tests, and the scheduled maintenance above.

**Human steps, in order:**

- [x] ~~**Add the Actions secret `SUPABASE_STAGING_SERVICE_ROLE_KEY`**~~ DONE
      2026-08-28, and PROVEN: a `workflow_dispatch` run swept for real —
      retention pass 1 (0 paths due yet), sweep-orphans scanned 27 accounts
      (0 deletable, all 27 under the age floor — the CI throwaways), 0 open
      reports. Photos are now aging out on a schedule for the first time.
      ⚠️ **The key is the `default` SECRET key (`sb_secret_…`) from API Keys ▸
      "Publishable and secret API keys" — NOT the legacy `service_role` JWT.**
      This project is on the new key system, so the platform injects that value
      as `SUPABASE_SERVICE_ROLE_KEY`. The legacy JWT passes the gateway and is
      then refused by our own comparison with a **403**, which looks exactly
      like a broken deploy. That cost half an hour to find.
- [ ] **After a few nightly reports look right**, arm the account sweep: repo
      variable `SUPABASE_STAGING_USER_SWEEP_APPLY=true` (or one
      `workflow_dispatch` with `apply_user_sweep`). Report mode deletes nothing.
- [ ] **Check your real circle for leftover Test Buddy members** from the old
      `fake_buddy.sh join` days — their state files are gone, so only the app
      or the dashboard can remove them now.
- [ ] **Live-smoke `fake_buddy.sh new`** once: join its printed code from the
      phone (you'd have to leave your real circle first — or just eyeball
      `status`), `post fajr onTime`, `leave`.
- [ ] **Two-phone join check** when convenient: phone open on Circle tab,
      second device joins — the roster should gain them within seconds (APNs
      secrets were verified §2, so the join push should really send).

**Decisions — ALL RESOLVED with Haashim, 2026-08-28:**

- ~~Excused days in the race~~ — DECIDED: the race matches the scoreboard.
  `raceXP`/`raceCrossing` now take the excused set (no silent default), so a
  break day never earns the bonus anywhere. Shipped this cycle.
- ~~Crown semantics~~ — DECIDED: FIRST PAST THE POST, recorded in SCORING.md
  and on `raceCrossing`. A crown falls with its deleted basis (stateless
  recompute) but survives later bookkeeping; the bar can read 280/300 under a
  standing crown. Race-to-a-target convention. Do not "fix".
- ~~Lapsed-window camera silence~~ — DECIDED: warn before AND after. The
  confirm stage carries a live closing-soon countdown (lead:
  `GameEngine.lapseWarningLead`, 120s) and a lapse posts an honest
  "saved as a make-up (+5); photo not kept" card. Shipped this cycle.
- ~~Old orphaned photos~~ — DECIDED: leave them. The leak is capped; a sweep's
  only win is disk space and its failure mode deletes a real memory.
- `CircleSyncTuning.reconcileInterval` stays 10 min until two-phone testing
  argues otherwise.

---

## 9. Shipped 2026-08-28 — the v5 cycle (widgets, Live Activity, triage desk)

One ultracode cycle (7 Opus builders, 7 adversarial reviews, 6 fix agents):
the break-day race fix + crown decision above, the camera lapse warnings, the
**reports triage desk** (`backend/scripts/triage_reports.sh` + migration
`20260828000100`, counts-only in the nightly job — guideline 1.2's reader
exists now), and **all of SPEC-V5**: P1 shared container + iOS 18 floor, P2
static widget (small/medium/lock-screen, demo renders), P3 photos + NSE +
quiet reload push + the privacy setting (photos by default), P4 Live Activity
with push-to-start, the nudge button, and the Control Center control.

Suites after merge: see the counts line in §7's tail. Backend: 32 SQL,
147 Deno.

**✅ The portal steps are DONE (2026-08-29).** Recorded because the failure they
caused is a convincing impostor: Xcode Cloud runs #27/#28/#29 all died at
`** EXPORT FAILED **` with "No profiles for …" — while `Test - iOS` passed and
the `.xcarchive` built fine. Nothing was wrong with the code.

- [x] App ID `org.amacvoters.salahbuddymock` — **App Groups** added (with
      `group.org.amacvoters.salahbuddymock`), alongside its existing push and
      Sign in with Apple. Done automatically by a device build with
      `-allowProvisioningUpdates`.
- [x] `org.amacvoters.salahbuddymock.widget` — created by that same build, with
      App Groups, because its entitlements forced an explicit App ID.
- [x] `org.amacvoters.salahbuddymock.notify` — **registered by hand**, and here
      is the trap: this extension ships NO entitlements, so automatic signing
      was happy to hand it the team's `XC Wildcard *` profile. That works for
      development and is refused by App Store distribution, which demands an
      explicit App ID for every bundle in the app. So a green local device
      build proves nothing about the archive. If you ever add another
      entitlement-free extension, register its App ID up front.
- [x] Provisioning profiles refreshed (development, by the local build;
      distribution, by Xcode Cloud on the next run). Table in XCODE-CLOUD.md.

Also worth knowing for next time: the App Store Connect **API key cannot create
App IDs** — `POST /v1/bundleIds` returns 403 "check with one of your Team
Admins". Xcode (signed in as a team member) can, and so can the portal UI.

**Device checks only you can run (in rough order):**

- [ ] **The P1 update path — highest-value check in the cycle**: install the
      current TestFlight build, sign in, log a prayer with a photo, then
      install this build over it. Sign-in, photos and streak must survive
      (the keychain access-group move is invisible on the Simulator).
- [ ] Add the widget; confirm it renders your window/streak (demo included)
      and that the second process really reads the App Group container.
- [ ] A friend's second post in a window: no tray banner, widget count still
      moves (the quiet reload is best-effort — occasional misses are Apple's
      throttling, not a bug). First-post banner unchanged.
- [ ] The Live Activity: appears when a window opens, fills in as the circle
      posts, ends at window close; nudge from the medium widget lands as a
      real nudge push.

**Still owed from §8:** arming the account sweep (the first report is in —
27 scanned, 0 deletable), the leftover-testuser check, and your first
`triage_reports.sh list` (the recipe is in backend/README.md's triage section;
it wants the same `sb_secret_…` key, not the legacy JWT). The Actions secret
itself is DONE and proven.
