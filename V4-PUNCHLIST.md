# v4 punch list — what still needs a human or a device

Everything in SPEC-V4 is built and on `dev/v4`. This is the honest list of what
a cloud session **could not** verify, split by whether it needs a dashboard, a
signature, a real phone, or a decision from you.

What *was* verified, so you know where the line is:

- **Backend, locally and in CI**: 27/27 SQL assertions against a real Postgres 16
  (negative-tested by mutating the schema 21 ways and confirming each mutation
  was caught), 55/55 Deno tests, `deno check` clean.
- **Backend, against the live staging project**: migrations applied and edge
  functions deployed successfully; anonymous reads of `posts`, `profiles` and
  `circles` denied **401 by the deployed database**. RLS holds where it counts.
- **iOS**: builds and passes its unit tests on every push (GitHub macOS runners).

Nothing below is a known defect. It is the set of claims that only a device, a
dashboard, or you can settle.

---

## 1. Blocking Phase A's stated exit criterion

SPEC-V4 §10 wants "staging accepts a signed-in user via a curl-level test". The
proofs run on every push to `staging` but currently stop at sign-up.

- [ ] **Staging Supabase → Authentication → Sign In / Providers → Email**:
      enable the provider and turn **"Confirm email" OFF**.
      CI signs up throwaway users; Apple and Google both need a device, so email
      is the only path a machine can drive. A CI user can never read a
      confirmation mail.
- [ ] If sign-up still returns `email_address_invalid`, Supabase's validator is
      rejecting the domain. Set the repo **variable**
      `SUPABASE_STAGING_CI_EMAIL_DOMAIN` to one it accepts. Nothing is ever sent
      to that domain while "Confirm email" is off — it only has to validate.
      (The default is `salahbuddy.app`; `@example.com` is rejected outright.)

Until these are done the smoke job fails loudly with dashboard instructions,
which is deliberate: a green tick that proved nothing is the one outcome that
job must never produce.

## 2. Dashboard settings to confirm

- [ ] **Google provider → Authorized Client IDs** must list
      `923951498597-445nb4q5o5k66imnbbul70h88s7bct72.apps.googleusercontent.com`.
      GoTrue checks the ID token's `aud` against that list; a mismatch fails
      sign-in with a message that does not obviously say why.
- [ ] **APNs secrets**: `APNS_BUNDLE_ID` must be exactly
      `org.amacvoters.salahbuddymock`. The other three (`APNS_KEY`,
      `APNS_KEY_ID`, `APNS_TEAM_ID`) you reported as already set and
      hash-verified. Every delivery path logs-and-skips when any is missing, so
      a wrong value degrades quietly rather than crashing — which is safe, and
      also why it needs checking by eye.

## 3. Signing

- [ ] **The first `staging` build may fail code signing once.** Adding Sign in
      with Apple + Push Notifications to the App ID invalidated the existing
      provisioning profiles; Xcode Cloud regenerates them on retry. Retry before
      debugging anything.
- [ ] Optional, saves compute hours: the Xcode Cloud **Test** action still uses
      the multi-device "Recommended iPhones" alias. Switching it to a single
      simulator is only possible from Xcode's Cloud tab (the ASC web dropdown
      refuses). The tests are pure-logic units on an iPhone-only target.

## 4. Device-only — cannot be exercised by any CI

Sign-in, push and photo sync have no simulator path. In rough dependency order:

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
