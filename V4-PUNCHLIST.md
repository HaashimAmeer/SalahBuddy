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

- [ ] **Google provider → Authorized Client IDs** must list
      `923951498597-445nb4q5o5k66imnbbul70h88s7bct72.apps.googleusercontent.com`.
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
- [ ] Optional, saves compute hours: the Xcode Cloud **Test** action still uses
      the multi-device "Recommended iPhones" alias. Switching it to a single
      simulator is only possible from Xcode's Cloud tab (the ASC web dropdown
      refuses). The tests are pure-logic units on an iPhone-only target.

## 4. Device-only — cannot be exercised by any CI

Sign-in, push and photo sync have no simulator path. In rough dependency order:

> **`backend/tests/fake_buddy.sh` covers the two-phone items with one phone.**
> It signs up a real throwaway account against staging, joins your circle with
> the invite code, and posts prayers — so your phone sees a genuine second
> member without a second device. `status` prints the XP total your leaderboard
> must agree with, which is the Phase C check.
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

## 5. Decisions that are yours, not mine

Both are one-line changes; I picked the more conservative reading.

- [ ] **The master Notifications switch blocks push registration entirely.**
      Someone who declined notifications at onboarding and later joins a circle
      is therefore never re-prompted and gets no nudges. That respects their
      explicit "off", but it means the nudge button silently does nothing for
      them. The alternative is prompting anyway when they join a circle.
- [ ] **`announcePost` does not gate on the sender's own
      `notifyFriendActivity`.** That toggle is a *receiving* preference, applied
      per recipient by the backend, so gating the sender would silence friends
      who did opt in. Flag if you read it the other way.
- [ ] **Circle size differs by mode, deliberately**: a real circle seats **8
      members total** (7 friends + you, enforced server-side); the demo circle
      keeps its 8 simulated friends + you. The invite copy quotes whichever
      applies, so the numbers on screen change between modes.

## 6. Deferred, with reasons

- **No production Supabase project.** The free tier caps the account at two
  active projects and both slots are taken, so `backend.yml`'s production deploy
  is deliberately unwired rather than referencing secrets that do not exist.
  Wiring it is a copy of `deploy-staging` with the branch and secret names
  swapped — and leave the smoke job pointed at staging, since it signs up
  throwaway users and posts rows.
- **`delete_account()` leaves the `auth.users` row.** Removing it needs the
  service-role admin API. The app signs out immediately so the account is
  unreachable, but an admin sweep should eventually clear the orphans — including
  the ones CI creates on every staging push.
- **Retention is not scheduled.** `purge_expired_photo_rows` + the `retention`
  edge function work and are lease-guarded (`claim_retention_run`), and the
  client triggers them opportunistically, but nothing runs them on a timer.
  pg_cron + pg_net, or a scheduled workflow, is the upgrade.
- **Universal links** (`…/join/<CODE>`) wait on a domain existing. Invites are
  code-first, as §2 specifies.
