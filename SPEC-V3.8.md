# SalahBuddy v3.8 — Requirements (design sessions, Jun 11–12 2026)

Single source of truth for the next iteration. Builds on the shipped v3.7 codebase. Consolidates two design sessions (the scoring/profile/Today-squares session and the Dhikr-page session) plus explicit follow-up decisions.

**Status legend:** ✅ Decided · 🔁 Confirmed — keep current · 🟡 Open · 🅿️ Parked / future · 🐞 Bug

---

## 1. Navigation — a dedicated Dhikr tab

- ✅ **Add Dhikr as its own tab.** Tab bar becomes **5 tabs: Today · Circle · Journey · Dhikr · Settings.** Accepted that buttons get a little smaller ("we can try five").
- ✅ **Journey stays Journey; profile stays in Settings.** Rejected folding everything into a renamed "Profile" page with memories as a sub-section — Journey is the overarching personal view, Settings holds profile/config.
- 🅿️ A center post/camera affordance in the tab bar was floated ("camera maybe…") — not decided.

---

## 2. Scoring & XP

### Prayer tiers
- 🔁 **Keep the current ladder:** on-time **30** / prayed **20** / getting-late **15** / just-made-it **12** / made-up (qada) **5**. After a long debate about widening the gaps (50/40/30/20/10 etc.) they returned to "the original was fine." *(qada→5 already shipped in v3.7.)*
- 🔁 **No hard daily cap on prayer XP.** A strong day naturally tops out around ~200; that's the ceiling, not a clamp.

### Jamaat — now a floor, not an additive bonus
- ✅ **Praying in a group boosts that prayer up to 30 XP (a floor), whether at the masjid or not.** If you already earned ≥30 (first quarter) it adds nothing; if you prayed in the final quarter (12), jamaat lifts it to 30. Replaces the old flat +5.
- ✅ **Rationale:** the old bonus penalized going to the masjid, since Asr/Isha jamaat times are often late. Group prayer now simply counts as on-time.
- ✅ **Jumma (Friday Dhuhr) folds into the same 30 floor** — no separate Jumma bonus anymore.

### Perfect day
- 🔁 **Keep perfect-day bonus at +25.**

### Parked
- 🅿️ Multiplier idea (e.g. a Friday boost) — floated, not pursued.

---

## 3. Recharge / Dhikr — permanent feature for everyone

Today it's gated to breaks. v3.8 makes it first-class.

- ✅ **Always available to everyone**, not just on a break — surfaced as its own **Dhikr tab** (§1), reusing the existing tasbih counter + good-deeds + "X XP today, up to N, then it's all for Allah" phrasing.
- ✅ **Daily XP caps depend on state** (this is the model that resolves the long cap debate):
  - **On a break (can't pray):** dhikr alone can earn up to **200/day**. They can't pray, so there's no early-prayer incentive to protect, and it keeps them competitive despite the Monday weekly reset.
  - **Can pray (not on a break):** **prayer + dhikr combined capped at 150/day.** Dhikr tops up a late/imperfect day toward a solid score but can **never reach a perfect-prayer day** — praying early always stays strictly better. (Firm principle; the 150 number is the agreed target.)
  - **Strong/perfect prayer day:** reaches up to **~200** from prayer itself (uncapped), so it always beats a dhikr-assisted 150.
- 🟡 **Reconciliation note:** with jamaat now a *floor* (max 30/prayer) the natural prayer max is 150 + 25 perfect = **175**, not 200. To make "perfect prayers reach 200" literally true we'd need a small extra allowance (e.g. let dhikr top a fully-prayed day up to 200, or another bonus). Decide whether 200 is the real ceiling or just the headline.
- ✅ **Leaderboard (resolved while building):** dhikr/deeds XP now **counts on the weekly scoreboard** (and toward level), so a break/period person reaching 200 actually keeps pace after the Monday reset. The **crown race stays prayer-only**. This supersedes the old "dhikr is private" rule — flag if you'd rather keep it private.
- ✅ **Caps built:** break → 200; can-pray → `max(0, 150 − today's prayer XP)`, so a perfect prayer day (~175) always beats a dhikr-assisted 150. The natural prayer max is ~175 (jamaat is a floor); 200 is the break ceiling.

---

## 4. Circle — leaderboard truncation

- ✅ **Show top 3, then "…", then your own row** wherever you rank below 3rd, instead of the full list. Keeps the page from clogging.
- 🔁 The "This week together" grid still shows everyone.

---

## 5. Today page — the four photo squares

Driven by two reference mockups (the hand-drawn 2×2 and the in-app screenshot).

- ✅ **Remove the location pill** from the small squares.
- ✅ **Keep the time** label.
- ✅ **Try an edge-to-edge 2×2 layout:** square photo cells, **no gaps** between them, straight inner dividers, rounded corners **only on the outer container** (the "Asr · Window ended" header on top, footer on the bottom). Explicitly experimental — she's skeptical it fits the all-curved aesthetic but wants to see it.
- 🟡 **Divider weight:** the screenshot shows **thick black lines** (likely placeholder). Default to a thin hairline in the soft-mint palette unless the bold black grid is intended — confirm.
- 🟡 **State rendering:** in a flush grid, the camera CTA ("Tap to post"), waiting, missed, and excused states need a new flush-square treatment (the reference shows blank white squares).
- ✅ **Keep paging/swipe** (4 at a time + dots + "N friends · swipe") — don't show everyone at once (buries Make-up / Earlier today).
- ✅ **Tap a square → larger view** with the extra info (location, etc.) that was removed from the tile.
- 🟡 **Name + time** overlay the photo bottom-left; needs a legibility scrim once photos are flush.
- 🅿️ Alternative to test: user's own photo larger than friends'.
- ✅ **Recharge/dhikr card on Today: move lower and make it smaller** (now that Dhikr has its own tab, its Today presence is secondary).
- 🔁 Keep section order: Make-up → Earlier today → Coming up (earlier-today first, for the incentive).
- 🅿️ Earlier-today as a swipe/toggle "different view" — still wanted but und-designed; current expand-to-timeline stays for now.

---

## 6. Journey page

- ✅ **Move the Challenges card above Memories** — it's currently buried at the bottom.
- 🅿️ **"Where you've prayed" map** — Spotify-Wrapped / Apple-Fitness vibe: a map of prayer locations, tap a pin → count + maybe photos (Apple-Maps-with-photos style). Enhances the existing Places card. **Needs a privacy opt-in.** Exploratory.

---

## 7. Profile & identity

- ✅ **Make onboarding answers editable** in the profile/Settings: **gender** and **hardest prayer**, plus possibly a **main goal** — not just name/photo (which v3.7 already added).
- ✅ **User's avatar = their profile photo** in the circle squares (replacing the emoji), keeping the name. Applies anywhere the user's emoji currently shows. *(Buddies remain simulated emojis.)*
- ✅ **Brother emoji → 🧔🏽‍♂️** *(currently 🧔🏽 in code — needs the ♂️ variant).*
- 🟡 **"Prefer not to say"** emoji is still disliked — pick a replacement.

---

## 8. Nudge UX

- ✅ The "Haven't prayed yet" nudge isn't discoverable ("I wouldn't know to press this"). Make it **action-oriented**:
  - Relabel toward **"Nudge your friends"** so it reads as an action.
  - Clearer that the chips are tappable; keep the satisfying checked-off feedback.
  - 🟡 Ideally **show what the recipient sees** (e.g. a "Haashim's reminding you" pill) so it's clear what nudging does.

---

## 9. "Who did you pray with" — future feature

- 🅿️ Record/show who you prayed with. Placement debated: **bottom of Today** (after "Coming up", its own "tap in" section) **or on the Journey page**. Leaning Journey. Not built yet.

---

## 10. Bugs & polish

- 🐞 **Camera capture shows/uses the previous photo** (+ a crop concern) — "a bug featuring the old photo."
- 🐞 **Guided-tour card clipped by the notch** — the spotlight card (e.g. "Post your prayer") renders flush against the top, under the Dynamic Island. The overlay ignores the safe area and doesn't clamp the card. *(Fixed: card now anchors inside the safe area, top or bottom.)*
- ✨ **Guided-tour spotlight ring too tight** — widened the cutout padding (−6 → −14/−12) so the green outline sits farther from the highlighted element.
- 🐞 **App-wide stutter / jank** — the `.tutorialTarget` modifier added for the tour publishes each section's global frame as a preference *unconditionally*, so the root re-renders every frame during any scroll, even with no tour running. *(Fixed: publishing is gated behind an active-tour flag.)* Secondary, pre-existing: the 1-second `RootView` ticker pushing `appNow` into the environment each second; `StreakFlameView`'s 30fps animation.
- 🐞 **"Extra data points" section looks weird** — a stats/data view renders oddly; flagged "fix later."

---

## Open questions to lock before building

1. **Dhikr & the leaderboard** — does dhikr XP count toward the weekly circle total (so break/period folks stay competitive), or remain private? And is 200 the true daily ceiling given jamaat is now a floor (natural max ~175)?
2. **Today squares** — commit to flush 2×2 as the first experiment; hairline vs. bold-black dividers; equal-size or your-photo-bigger.
3. **"Prefer not to say"** emoji choice.
4. **"Who did you pray with"** placement (Today vs. Journey) when we get to it.
