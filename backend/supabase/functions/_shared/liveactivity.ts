// SPEC-V5 §6 — the shape of a Live Activity, as the SERVER has to spell it.
//
// This module is the mirror of `Sources/Shared/PrayerWindowActivity.swift`, and
// the two are a wire contract in the strictest sense in this repo: ActivityKit
// decodes `aps["content-state"]` straight into `PrayerWindowAttributes
// .ContentState` on the device, and a mismatch is not an error anybody sees. It
// is a push that silently does nothing. There is no reply, no log, no 4xx — the
// activity just never moves.
//
// Three rules follow from that, and every one of them is a decision:
//
//   * **No dates.** Every instant here is a NUMBER of seconds since 1970, and
//     the Swift side declares the same fields as `Double`. Two JSON decoders we
//     do not control (ours, and ActivityKit's) would otherwise have to agree on
//     a date strategy, which is exactly the kind of agreement that holds until
//     an OS update.
//   * **`tier` is a bare string**, not an enum, on both sides. A tier this
//     build has never heard of must cost the colour of one chip, never the
//     whole push — the same call `WidgetSnapshot.Post`'s decoder makes.
//   * **Everything is optional on the way in.** The app and the extension are
//     versioned separately from this function; a field added here reaches a
//     phone running last month's build, and it has to be ignored rather than
//     fatal.
//
// PURE — no clock, no network, no Deno APIs — so `tests/deno/liveactivity_test.ts`
// exercises the whole of it offline.

import {
  apnsPayloadBytes,
  buildLiveActivityPayload,
  fitsLiveActivityBudget,
  type LiveActivityEvent,
  LIVE_ACTIVITY_PAYLOAD_LIMIT,
} from "./apns.ts";

/// The Swift type ActivityKit is asked to decode `attributes` into. It is a
/// TYPE NAME crossing a wire: rename `PrayerWindowAttributes` on the Swift side
/// and every push-to-start silently stops working, which is why it is spelled
/// once, here, with this comment attached to it.
export const LIVE_ACTIVITY_ATTRIBUTES_TYPE = "PrayerWindowAttributes";

/// How many faces the content state carries. Four, matching
/// `WidgetSnapshot.postCap` and §3's 4-up row — the Dynamic Island's compact
/// presentation shows fewer still, and a Live Activity is not a feed.
export const LIVE_ACTIVITY_FACE_CAP = 4;

/// One person in the circle who has prayed this window. Emoji, name, tier —
/// §6's whole vocabulary ("emoji/names/counts/tier colours only"). There is no
/// photo field and there cannot be one: a 4 KB payload holds no picture, and
/// §7 forbids a second photo store, so the Lock Screen draws what is already in
/// the shared container or it draws an emoji.
export interface LiveActivityFace {
  name: string;
  emoji: string;
  tier: string;
}

export interface LiveActivityContentState extends Record<string, unknown> {
  prayedCount: number;
  memberCount: number;
  /// Whether THIS recipient has prayed. It is the one field that differs per
  /// phone, which is why the fan-out builds at most two payloads per event and
  /// groups the tokens under them rather than sending one payload to everybody.
  youLogged: boolean;
  faces: LiveActivityFace[];
  /// Seconds since 1970. Not the push's timestamp (that is `aps.timestamp`,
  /// which ActivityKit uses to discard out-of-order updates) — this is what the
  /// activity may show a person as "as of".
  updatedAt: number;
}

export interface LiveActivityAttributes extends Record<string, unknown> {
  prayer: string;
  dayKey: string;
  /// Seconds since 1970. See the module note on why nothing here is a date.
  endsAt: number;
}

export function buildLiveActivityAttributes(opts: {
  prayer: string;
  dayKey: string;
  endsAtSeconds: number;
}): LiveActivityAttributes {
  return {
    prayer: opts.prayer,
    dayKey: opts.dayKey,
    endsAt: Math.floor(opts.endsAtSeconds),
  };
}

export function buildLiveActivityContentState(opts: {
  prayedCount: number;
  memberCount: number;
  youLogged: boolean;
  faces?: readonly LiveActivityFace[];
  updatedAtSeconds: number;
}): LiveActivityContentState {
  return {
    // Non-negative and ordered, because the device draws a progress track off
    // these two and a count above its own total is a ring past full.
    prayedCount: Math.max(0, Math.trunc(opts.prayedCount)),
    memberCount: Math.max(0, Math.trunc(opts.memberCount)),
    youLogged: opts.youLogged,
    faces: (opts.faces ?? []).slice(0, LIVE_ACTIVITY_FACE_CAP).map((face) => ({
      name: face.name,
      emoji: face.emoji,
      tier: face.tier,
    })),
    updatedAt: Math.floor(opts.updatedAtSeconds),
  };
}

/// The whole push, trimmed until Apple will accept it.
///
/// **Why trimming and not just a cap.** `LIVE_ACTIVITY_FACE_CAP` bounds the
/// COUNT; it does not bound the bytes, and a name is user-supplied text of
/// unbounded length. Four people called something long, in a script where one
/// glyph is four UTF-8 bytes, is a payload Apple rejects WHOLE
/// (413/PayloadTooLarge) — the activity would simply stop updating for that
/// circle, for that window, with nothing to see but a 413 in a log nobody
/// reads. So the counts, which are the point, are never what gets dropped: the
/// faces go one at a time, oldest first, and the last resort is a payload with
/// no faces at all — which still says "3 of 5 prayed".
export function buildLiveActivityPush(opts: {
  event: LiveActivityEvent;
  contentState: LiveActivityContentState;
  timestampSeconds: number;
  attributes?: LiveActivityAttributes;
  staleSeconds?: number;
  dismissalSeconds?: number;
  data?: Record<string, unknown>;
}): { payload: Record<string, unknown>; bytes: number; facesDropped: number } {
  let faces: LiveActivityFace[] = [...opts.contentState.faces];
  let dropped = 0;
  for (;;) {
    const payload = buildLiveActivityPayload({
      event: opts.event,
      contentState: { ...opts.contentState, faces },
      timestampSeconds: opts.timestampSeconds,
      attributesType: opts.attributes
        ? LIVE_ACTIVITY_ATTRIBUTES_TYPE
        : undefined,
      attributes: opts.attributes,
      staleSeconds: opts.staleSeconds,
      dismissalSeconds: opts.dismissalSeconds,
      data: opts.data,
    });
    if (fitsLiveActivityBudget(payload) || faces.length === 0) {
      return {
        payload,
        bytes: apnsPayloadBytes(payload),
        facesDropped: dropped,
      };
    }
    faces = faces.slice(0, faces.length - 1);
    dropped++;
  }
}

export { LIVE_ACTIVITY_PAYLOAD_LIMIT };
