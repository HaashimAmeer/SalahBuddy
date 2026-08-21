// Notification copy. Kept pure + in one file so the wording is reviewable in a
// diff and testable without APNs — and so it stays in the app's voice
// (warm, no shaming, no red).

import { prayerDisplayName, type PrayerKind } from "./validate.ts";

export interface Alert {
  title: string;
  body: string;
}

/// Profiles start life with `name = ''` (the auth trigger inserts a bare row),
/// so every headline needs a graceful stand-in.
export function displayName(name: string | null | undefined): string {
  const trimmed = (name ?? "").trim();
  return trimmed === "" ? "Someone" : trimmed;
}

export function postAlert(opts: {
  name: string | null | undefined;
  prayer: PrayerKind;
  jamaat?: boolean;
  placeLabel?: string | null;
}): Alert {
  const place = (opts.placeLabel ?? "").trim();
  const body = opts.jamaat
    ? "Prayed in jamaat 🕌"
    : place !== ""
    ? `At ${place}`
    : "Your circle is filling in.";
  return {
    title: `📸 ${displayName(opts.name)} posted ${
      prayerDisplayName(opts.prayer)
    }`,
    body,
  };
}

export function joinAlert(opts: { name: string | null | undefined }): Alert {
  return {
    title: `${displayName(opts.name)} joined your circle 🎉`,
    body: "Say salaam 👋",
  };
}

export function nudgeAlert(opts: {
  name: string | null | undefined;
  prayer: PrayerKind;
}): Alert {
  return {
    title: `👋 ${displayName(opts.name)} nudged you for ${
      prayerDisplayName(opts.prayer)
    }`,
    body: "There's still time — log it when you're done.",
  };
}
