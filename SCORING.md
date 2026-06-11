# SalahBuddy — How scoring works

One page for us (and curious users). The in-app version lives in Settings → "How scoring works".

## Prayer XP — quarters of the window

Each prayer's window (e.g. Asr → Maghrib) is split into **four quarters**. The earlier you post your photo, the more you earn — and the curve is steep enough that earlier always feels worth it:

| When you log | XP |
|---|---|
| 1st quarter | **30** |
| 2nd quarter | **20** |
| 3rd quarter | **15** |
| 4th quarter | **12** |
| Made up later same day (Qada, tap-only, no photo) | **10** |
| Never logged | 0 — shown as "you missed out on +30 XP" |

In-window always beats qada; qada always beats nothing.

## Bonuses

| Bonus | XP | Notes |
|---|---|---|
| Perfect day | +25 | All 5 prayers in their windows; qada disqualifies |
| Jamaat | +5 | Toggle after the photo |
| **Jumma** | +10 | Friday Dhuhr in congregation (replaces the jamaat bonus that day) |
| Dhikr | +5 each, max 5/day | Only while on a break; **private** — levels you up but never shows on the circle scoreboard |

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

- Weekly score = prayer XP + bonuses earned that week (dhikr excluded).
- **Race**: first member to the weekly target wins the crown. The target starts at 300 and climbs +100 with every past win.
- Hard-coded group challenges (everyone-prays-Isha ×3, Circle Perfect Day) plus **custom challenges** the circle creates (+ button): pick a prayer and a day count, everyone has to log it that many days in a row, reward = 15 XP × days.
