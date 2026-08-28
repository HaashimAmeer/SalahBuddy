# CI: Xcode Cloud → TestFlight, and GitHub Actions → Supabase

Xcode Cloud builds every push to `staging` on Apple's macOS infrastructure and
uploads it to TestFlight, so development can happen entirely from the cloud
(Claude Code on the web, or any machine without Xcode) and each build lands on
the iPhone a few minutes later.

Since v4 there is a **second half**: the backend under `backend/` is tested and
deployed by **`.github/workflows/backend.yml`** on Linux. The two are
path-filtered against each other — Xcode Cloud does not start for a
`backend/**`-only push, and `ios.yml`/`backend.yml` ignore each other's trees —
so one repo costs one CI run per change, not two.

## How it fits this repo

- The `.xcodeproj` is git-ignored — **`ci_scripts/ci_post_clone.sh`** installs
  XcodeGen, stamps Xcode Cloud's `CI_BUILD_NUMBER` into
  `CURRENT_PROJECT_VERSION`, and runs `xcodegen generate` before every CI
  build. Local builds are untouched (they keep the number in `project.yml`).
- Xcode Cloud disables automatic SPM resolution and pins dependencies from
  the committed **`Package.resolved`** at the repo root (the CI script copies
  it into the generated project). After changing a dependency in
  `project.yml`, run **`make lock`** and commit the refreshed file, or the
  next CI build fails with "a resolved file is required".
- The local **pre-push hook** (`make test`) only runs on clones that ran
  `make hooks` — pushes from Claude web cloud sessions skip it naturally
  (the sandbox is Linux and couldn't run it anyway). Xcode Cloud's **Test
  action is the safety net for those pushes**, so keep it enabled in the
  workflow.
- Cost: the Apple Developer Program includes **25 free compute hours/month**.
  A build+test+archive run for this project is well under 15 minutes, so the
  free tier covers ~100 builds/month. Keeping the workflow scoped to
  `staging` (not every branch) preserves that budget.

### A new TARGET is a portal step, and it gates the merge

Adding an app extension adds a second thing to sign. `make test`, `ios.yml` and
the pre-push hook all build for the simulator **unsigned**, so they stay green
and tell you nothing; the first signal is a red *Archive* on `staging` and no
build reaching TestFlight.

So before merging a branch that adds a target, its bundle id needs an explicit
**App ID in the developer portal** carrying every capability its
`.entitlements` file names. v5 §3's `SalahBuddyWidget` is the live example:
`org.amacvoters.salahbuddymock.widget`, with **App Groups**
(`group.org.amacvoters.salahbuddymock`) and **Keychain Sharing** enabled — the
same two the app's own App ID gained in v5 §2. Only Haashim can do this, and it
is a toggle on a new identity rather than any code change.

## One-time setup (needs the Mac + Xcode, ~10 minutes)

1. Open `SalahBuddy.xcodeproj` → **Integrate ▸ Create Workflow…** (or the
   Xcode Cloud tab in the Report navigator) and pick the SalahBuddy app.
2. Grant access when prompted: App Store Connect walks through installing the
   **Xcode Cloud GitHub app** on the `SalahBuddy` repo.
3. Configure the workflow:
   - **Start condition:** Branch Changes → `staging`.
   - **Environment:** latest released Xcode / macOS (defaults are fine).
   - **Actions:** *Test* (iOS Simulator, scheme `SalahBuddy`) and *Archive*
     with **TestFlight (Internal Testing Only)**.
   - **Post-action:** TestFlight Internal Testing → add yourself to the
     tester group. Internal builds need no Apple review and appear in the
     TestFlight app within minutes of a green build.
4. **Set the next build number** before the first run: in the workflow's
   context menu (or App Store Connect ▸ Xcode Cloud ▸ Settings) choose
   *Set Next Build Number* and pick something above the highest manually
   uploaded build (e.g. `10`) so CI numbers never collide with the manual
   `1.0 (1)` / `1.0 (2)` uploads.

## The backend half (`.github/workflows/backend.yml`)

Three jobs, in order, on pushes touching `backend/**` (branches `staging`,
`production` and `dev/**`; `backend/README.md` alone is excluded, because a
typo fix must not deploy):

1. **`test`** — every branch. Spins up a `postgres:16` service, applies
   `backend/tests/shim/` + every migration to a scratch database, runs every
   `backend/tests/sql/*.sql` assertion and `seed.sql` twice, then `deno check` +
   `deno test backend/tests/deno/`. This is the same script a cloud session runs
   locally (`backend/tests/run_sql_tests.sh`), so a green sandbox run means a
   green CI run.
2. **`deploy-staging`** — `staging` only, and only when the staging secrets
   exist: `supabase link` → `db push` → `functions deploy`. **Migrations are
   applied in filename order and a version is never re-run**, so a fix to an
   already-deployed migration must go in a NEW timestamped file — editing the
   old one changes the repo and nothing else.
3. **`smoke-staging`** — SPEC-V4 §10's Phase A exit criterion executed on every
   deploy: real HTTP against the live project with the **publishable (anon) key
   only**, proving RLS is the security boundary rather than key custody.

Public-repo safety rules this workflow must keep: push-triggered only (never
`pull_request_target`), secrets reach the shell through `env:` and are never
interpolated into a `run:` script, and no project ref, URL or key is written in
the file.

**Dev branches stop after `test`.** A `dev/**` push proves the migrations and
the functions; it does not touch the live project, which is why a v4 session can
iterate on SQL all day without a Supabase account.

## Export compliance is answered in `project.yml`, not by hand

`ITSAppUsesNonExemptEncryption: false` lives in the target's `info.properties`.
Without it every upload landed in TestFlight as **"Missing Compliance"** needing
a manual *Manage* click, and — this is the part that looks like a separate bug —
**no tester group was assigned either**. App Store Connect will not release a
build to testers until the export question is settled, so an unanswered build
simply never reaches the internal group the workflow's post-action points at.
One key fixes both symptoms.

`false` is the accurate answer rather than a shortcut: it declares no
*non-exempt* encryption. Everything the app does is exempt — HTTPS/TLS to
Supabase, Apple and Google sign-in over the same, and the SHA-256 in
`AuthService`'s nonce, which is a hash rather than encryption and serves
authentication regardless. Revisit only if the app ever ships its own
cryptography.

Builds uploaded BEFORE this key was added keep their warning — the plist only
travels with new builds. Clear them from the TestFlight list by hand, or leave
them to expire.

## Current state (2026-08-21)

- Workflow **"Staging"** is active: Branch Changes on `staging`, auto-cancel,
  **Test (required to pass) → Archive → TestFlight Internal**, and the
  **backend path filter is configured** ("do not start if only files in
  /backend change"). Minor optimization pending: the Test destination is the
  multi-device "Recommended iPhones" alias — switching it to a single
  simulator (only possible from Xcode's Cloud tab, the ASC web dropdown
  refuses) would cut compute-hour usage; the tests are pure-logic units on an
  iPhone-only target.
- **`.github/workflows/ios.yml`** additionally runs `make test` on GitHub's
  free public-repo **macOS runners** for every Swift-touching push — the fast
  compile-and-test verdict for cloud/web sessions, costing zero Xcode Cloud
  hours. It also **auto-pins `Package.resolved`**: when `project.yml` changes
  the dependency set, the workflow commits the refreshed pin back with
  `[ci skip]`, and `ci_post_clone.sh` self-heals by running
  `-resolvePackageDependencies`, so adding an SPM package needs no Mac.
- **Supabase: staging only.** The production project is deferred — the free
  tier caps the *account* at 2 active projects and both slots are taken.
  Repo secrets exist for staging (`SUPABASE_ACCESS_TOKEN`,
  `SUPABASE_STAGING_PROJECT_REF`, `SUPABASE_STAGING_DB_PASSWORD`); the
  production pair does NOT exist yet, so backend CI must skip the
  `production` deploy path gracefully rather than reference missing secrets.

### What production still needs

- A **second Supabase project** (frees up when a slot does, or on a paid plan),
  then `SUPABASE_PRODUCTION_PROJECT_REF` / `SUPABASE_PRODUCTION_DB_PASSWORD` as
  repo secrets and a `deploy-production` job — a copy of `deploy-staging` with
  the ref check and secret names swapped. **The smoke job stays pointed at
  staging**: it creates users and inserts rows.
- **APNs secrets on that project** (`supabase secrets set APNS_*`). Until they
  exist every push path logs and skips, by design — so a missing secret is a
  quiet no-op, not an outage.
- **A schedule for `retention`** (the ~30-day photo sweep). Nothing calls it
  yet; `pg_cron` + `pg_net` on the project, or an external scheduler presenting
  the raw service-role key. Its lease makes over-calling safe.
- **A reader for `reports`.** Triage today is a service-role query by hand;
  App Store guideline 1.2 wants a human able to see the queue.
- The app's `aps-environment` entitlement ships as `development`; Xcode Cloud
  and TestFlight archives rewrite it to `production` at export, which is why
  `PushRegistrar` keys the `devices.environment` column off `#if DEBUG`.
- The full list, with the reasoning, is `backend/README.md` → "TODO before
  production".

## Day-to-day from the cloud

Push to `staging` → Xcode Cloud tests + archives → green build hits
TestFlight → install/update from the TestFlight app on the iPhone. A red
build emails the failure and shows full logs in Xcode's Cloud tab and App
Store Connect.

Manual archives from Xcode still work exactly as before — bump
`CURRENT_PROJECT_VERSION` in `project.yml` by hand for those, and keep the
number clear of the CI range.
