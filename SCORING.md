# SalahBuddy — How scoring works

One page for us (and curious users). The in-app version lives in Journey → "How scoring works".

## Prayer XP — quarters of the window

Each prayer's window (e.g. Asr → Maghrib) is split into **four quarters**. The earlier you post your photo, the more you earn — and the curve is steep enough that earlier always feels worth it:

| When you log | XP |
|---|---|
| 1st quarter | **30** |
| 2nd quarter | **20** |
| 3rd quarter | **15** |
| 4th quarter | **12** |
| Made up later same day (Qada, tap-only, no photo) | **5** |
| Never logged | 0 — shown as "you missed out on +30 XP" |

In-window always beats qada; qada always beats nothing.

## Praying in a group (v3.8 — a floor, not a bonus)

Toggle **Prayed in jamaat** (or **Jumma** on Friday Dhuhr) after the photo and the prayer's XP is **lifted up to 30** (the on-time value) — it never *adds* on top. So a late masjid prayer isn't penalised, and if you already prayed in the first quarter it's already 30. Jumma folds into the same floor (no separate Friday bonus).

## Bonuses

| Bonus | XP | Notes |
|---|---|---|
| Perfect day | +25 | All 5 prayers in their windows; qada disqualifies |

## Dhikr & deeds (v3.8 — permanent, for everyone; v4 — counts for everyone in the circle)

Tasbih and good deeds live on the **Dhikr tab**, always available, and earn XP toward your level and the **weekly circle scoreboard**. The daily cap depends on your state:

- **On a break** (period/illness): up to **200/day** from dhikr alone — so someone who genuinely can't pray still reaches a full day and isn't left behind by the Monday reset.
- **Otherwise**: dhikr only tops a prayed-but-imperfect day **up to 150** total (prayer + dhikr). A strong/perfect prayer day (~175) always beats it, so praying early still wins.

The act of dhikr is never blocked once the XP cap is reached — it just stops adding points.

**On the scoreboard it is an OPAQUE weekly total** (SPEC-V4 §3). Every member's week carries one number for recovery XP — yours and every friend's alike — and that number is all anybody sees: never which day it came from, never whether it was tasbih or a good deed, never that somebody was resting. It is what keeps a break/period week competitive without the scoreboard announcing the break. The crown **race** stays prayer-only (see "The circle").

## Traveling (combining / jam')

Turn on **Traveling** (toggle on Today, or accept the auto-suggestion when you're >80 km from your saved Home). While on:

- **Dhuhr+Asr** and **Maghrib+Isha** each merge into one card. Fajr is never combined.
- One photo logs **both** prayers of the pair at once. Both earn the tier computed against the merged window — so combining early still earns the most (full XP each, no penalty for combining; it's a valid concession).
- Both count toward your streak and perfect day; both squares show the shared photo.
- Turn it off when you're home.

## Streaks & freezes

- A day counts toward your streak when **all 5** prayers are logged (any tier).
- Every 7 consecutive days banks a **streak freeze** (max 2). A missed day consumes a freeze instead of resetting you.
- **Breaks** ("Can't pray right now"): streak fully paused, no cap, resume with one tap. Your circle sees a gentle "excused", never the reason. The flow is gender-aware (from onboarding):
  - **Sisters**: a normal-framed **period** break — prayers are *waived* (no make-ups, religiously correct), streak safe, dhikr earns private XP. Up to ~10 days is treated as expected, with a soft check-in after 10.
  - **Brothers**: no period option. "Traveling" routes to combining (you can still pray); only genuine illness starts a break (soft check-in after 5 days).
  - **Prefer not to say**: the unified break with all reasons.

## Levels

XP needed to clear level n → n+1: `100 + (n−1) × 25`. New title every 5 levels: Seeker, Committed, Consistent, Devoted, Steadfast, Radiant, Luminous. Full ladder: Journey → level row → "See all levels".

## The circle (weekly, resets Monday 00:00 local)

- Weekly score = prayer XP + bonuses **+ that week's recovery (dhikr/deeds) XP as one opaque total** — the same rule for you and for every friend (SPEC-V4 §3).
- **Race**: first member to the weekly target wins the crown — **prayer XP only**, so a big dhikr week never buys one. "Prayer XP" here is the logs *plus the perfect-day bonuses they earned* — the same number the race's progress bar shows, since the bonus is bought with exactly what the race rewards (all five, in their windows). The one thing left out is the opaque recovery total. The target starts at 300 and climbs +100 with every past win.
- **The weekly recap's circle page** (Journey, real circles only) recaps the last finished Mon–Sun week with the same two numbers: the standings as the scoreboard scored them, and the best single day anybody had — prayer XP, decided by the data (highest XP, then the earlier day, then the name) so every phone in the circle shows the same answer.
- Hard-coded group challenges (everyone-prays-Isha ×3, Circle Perfect Day) plus **custom challenges** the circle creates (+ button): pick a prayer and a day count, everyone has to log it that many days in a row, reward = 15 XP × days.
