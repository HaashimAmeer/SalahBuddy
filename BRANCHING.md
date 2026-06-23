# Branching: staging vs. production

SalahBuddy uses a **two-branch model**. There is no `main` anymore — it was renamed to `production`.

| Branch | Role | Default? |
|---|---|---|
| **`staging`** | Day-to-day work. New features and fixes land here first and are tested (TestFlight builds, simulator/device runs). This is where the app lives while we're getting a release ready. | ✅ **Yes** — the default branch locally and on GitHub. New clones and PRs target it. |
| **`production`** | The "we're happy with it" branch. Only contains work that has been validated on `staging`. This is what we cut real/App Store releases from. | No |

## The workflow

1. **Develop on `staging`** (the default — a fresh checkout already lands you here).
   ```bash
   git checkout staging
   # ...make changes, commit, push...
   git push origin staging
   ```
   Test from here: TestFlight beta builds and local device/simulator runs come off `staging`.

2. **When a feature set is solid, promote `staging` → `production`.**
   ```bash
   git checkout production
   git merge --ff-only staging   # fast-forward when production hasn't diverged
   git push origin production
   git checkout staging          # go back to the working branch
   ```
   If `production` has diverged (rare for a solo repo), open a PR `staging → production` instead of a local merge so the diff is reviewable.

3. **Cut the release** from `production` (archive / TestFlight promote to App Store).

## CI

CI is a **local pre-push hook** (`.githooks/pre-push`) that runs `make test` before any push and blocks it on failure — no GitHub-hosted runners (the repo is private; macOS minutes are costly). Activate it once per clone with `make hooks`. It's build + test only; archive/sign/TestFlight stay manual. Bypass a doc-only push with `git push --no-verify`.

## Rules of thumb

- **Never commit straight to `production`.** Everything earns its way there by passing through `staging` first.
- Keep `production` a strict subset of validated `staging` history — promotions should normally be fast-forwards.
- Hotfixes still go to `staging` first, then promote, unless production is actively on fire (then fix on `production` and immediately back-merge into `staging`).
- The bundle id today is `org.amacvoters.salahbuddymock` (a TestFlight mock). When a real production bundle id / separate release config is introduced, document it here.
