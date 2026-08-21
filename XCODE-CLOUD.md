# Xcode Cloud → TestFlight

Xcode Cloud builds every push to `staging` on Apple's macOS infrastructure and
uploads it to TestFlight, so development can happen entirely from the cloud
(Claude Code on the web, or any machine without Xcode) and each build lands on
the iPhone a few minutes later.

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

## Day-to-day from the cloud

Push to `staging` → Xcode Cloud tests + archives → green build hits
TestFlight → install/update from the TestFlight app on the iPhone. A red
build emails the failure and shows full logs in Xcode's Cloud tab and App
Store Connect.

Manual archives from Xcode still work exactly as before — bump
`CURRENT_PROJECT_VERSION` in `project.yml` by hand for those, and keep the
number clear of the CI range.
