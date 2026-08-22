// notify — circle push notifications (SPEC-V4 §6).
//
// `verify_jwt = true`: the caller's own user JWT authenticates them, so this
// function carries NO repo-managed secret. The platform verifies the signature;
// we then re-derive everything that matters from the database with the
// service-role key. The body only says what the caller CLAIMS — who they are,
// what circle they're in, whether they own that post and whether the nudge is
// rate-limited are all answered by Postgres.
//
// POST body, one of:
//   { "kind": "post",  "postId": "<uuid>" }
//   { "kind": "join" }
//   { "kind": "nudge", "recipientId": "<uuid>", "dayKey": "yyyy-MM-dd",
//     "prayer": "fajr|dhuhr|asr|maghrib|isha" }
//
// Always answers 200 with a JSON body describing what happened; 400 for a
// malformed body and 401 for a bearer we cannot resolve to a user.

import {
  buildAPNsPayload,
  deliverToDevices,
  type DeviceRow,
} from "../_shared/apns.ts";
import { bearerToken } from "../_shared/auth.ts";
import {
  callerClient,
  circleIdFor,
  circleMemberIds,
  claimJoinAnnouncement,
  claimPostNotification,
  type Client,
  deleteDevice,
  devicesFor,
  isFirstPostInWindow,
  postById,
  profileFor,
  resolveCallerId,
  serviceClient,
  setDeviceEnvironment,
} from "../_shared/db.ts";
import {
  errorResponse,
  handleOptions,
  HttpError,
  json,
  readJsonBody,
  requireMethod,
} from "../_shared/http.ts";
import {
  type Alert,
  joinAlert,
  nudgeAlert,
  postAlert,
} from "../_shared/messages.ts";
import {
  dayKeyWithinWindow,
  isPrayerKind,
  type NotifyRequest,
  parseNotifyRequest,
  type PrayerKind,
} from "../_shared/validate.ts";
import {
  type DayWindow,
  partitionByRelevance,
  relevanceWindow,
} from "../_shared/zones.ts";

Deno.serve(async (req: Request): Promise<Response> => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  try {
    return await handle(req);
  } catch (err) {
    return errorResponse(err);
  }
});

async function handle(req: Request): Promise<Response> {
  requireMethod(req, ["POST"]);

  const jwt = bearerToken(req.headers.get("Authorization"));
  if (!jwt) throw new HttpError(401, "missing_authorization");

  const request = parseNotifyRequest(await readJsonBody(req));

  const admin = serviceClient();
  const callerId = await resolveCallerId(admin, jwt);
  if (!callerId) throw new HttpError(401, "invalid_token");

  // Everything below is DB truth, not body truth.
  const circleId = await circleIdFor(admin, callerId);
  if (!circleId) {
    return json({
      ok: true,
      kind: request.kind,
      sent: false,
      reason: "no_circle",
    });
  }
  const senderName = (await profileFor(admin, callerId))?.name ?? null;

  switch (request.kind) {
    case "post":
      return await notifyPost(
        admin,
        { callerId, circleId, senderName },
        request.postId,
      );
    case "join":
      return await notifyJoin(admin, { callerId, circleId, senderName });
    case "nudge":
      return await notifyNudge(
        admin,
        req,
        { callerId, circleId, senderName },
        request,
      );
  }
}

interface Caller {
  callerId: string;
  circleId: string;
  senderName: string | null;
}

async function notifyPost(
  admin: Client,
  caller: Caller,
  postId: string,
): Promise<Response> {
  const post = await postById(admin, postId);
  // Ownership is the DB's answer, not the caller's: you can only announce
  // a post that is yours and sits in your circle.
  if (
    !post || post.user_id !== caller.callerId ||
    post.circle_id !== caller.circleId
  ) {
    return json({
      ok: true,
      kind: "post",
      sent: false,
      reason: "post_not_found",
    });
  }
  if (!isPrayerKind(post.prayer)) {
    return json({
      ok: true,
      kind: "post",
      sent: false,
      reason: "unknown_prayer",
    });
  }

  // §6 is "X posted FIRST for Fajr", not "X posted". Checked before the lease is
  // claimed so a later poster's postId stays announceable if the first one is
  // ever deleted — and so a circle of 8 produces one alert per window, not 7.
  if (!await isFirstPostInWindow(admin, post)) {
    return json({ ok: true, kind: "post", sent: false, reason: "not_first" });
  }
  // The lease: one announcement per post, ever. Nothing else in this function is
  // stateful, so without it the same postId can be re-announced in a loop.
  if (!await claimPostNotification(admin, post.id)) {
    return json({
      ok: true,
      kind: "post",
      sent: false,
      reason: "already_notified",
    });
  }

  const alert = postAlert({
    name: caller.senderName,
    prayer: post.prayer,
    jamaat: post.jamaat,
    placeLabel: post.place_label,
  });
  // ONE clock read for both halves of the relevance decision. The poster's
  // window and every recipient's local day have to be judged at the same
  // instant: two `Date.now()` calls milliseconds apart can straddle a midnight
  // somewhere, and the invariant that nobody in the poster's own zone is ever
  // filtered would break for exactly the people awake at that moment.
  const now = Date.now();
  return await fanOut(admin, caller, alert, {
    // The one filter that is about WHERE the recipient is rather than what
    // they asked for. See `relevance` in PushOptions.
    // logged_at supplies the poster's own clock reading, which is what makes
    // the time-of-day half of the filter possible — without it the window
    // degrades to date-only and a Mumbai member is buzzed at 17:30 about a
    // Seattle Fajr. Date.parse of a null/absent column yields NaN, and
    // relevanceWindow reads a non-finite value as "unknown, do not filter".
    relevance: relevanceWindow(post.day_key, post.utc_offset, now,
                               Date.parse(post.logged_at)),
    relevanceAt: now,
    threadId: `circle-${caller.circleId}`,
    category: "CIRCLE_POST",
    // One notification per prayer per friend: a burst of posts for the same
    // window collapses instead of stacking.
    collapseId: `post-${post.user_id}-${post.day_key}-${post.prayer}`,
    // Opt-in only: this is the friend-activity toggle, which is off by default.
    friendActivityOnly: true,
    expiration: expiresIn(POST_TTL_SECONDS),
    data: {
      kind: "post",
      circleId: caller.circleId,
      postId: post.id,
      userId: post.user_id,
      dayKey: post.day_key,
      prayer: post.prayer,
    },
  });
}

async function notifyJoin(admin: Client, caller: Caller): Promise<Response> {
  // Same lease shape as a post: the membership row is claimed once, so a client
  // POSTing {kind:"join"} in a loop cannot fan out to the circle on every call.
  if (!await claimJoinAnnouncement(admin, caller.callerId, caller.circleId)) {
    return json({
      ok: true,
      kind: "join",
      sent: false,
      reason: "already_announced",
    });
  }
  const alert = joinAlert({ name: caller.senderName });
  return await fanOut(admin, caller, alert, {
    threadId: `circle-${caller.circleId}`,
    category: "CIRCLE_JOIN",
    collapseId: `join-${caller.callerId}`,
    expiration: expiresIn(JOIN_TTL_SECONDS),
    data: { kind: "join", circleId: caller.circleId, userId: caller.callerId },
  });
}

async function notifyNudge(
  admin: Client,
  req: Request,
  caller: Caller,
  request: Extract<NotifyRequest, { kind: "nudge" }>,
): Promise<Response> {
  if (request.recipientId === caller.callerId) {
    return json({ ok: true, kind: "nudge", sent: false, reason: "self_nudge" });
  }
  // The rate limit's primary key contains dayKey, so an unbounded dayKey is not
  // a rate limit at all. record_nudge re-checks this against the DB clock — the
  // check here just turns "walked off the calendar" into an honest 400.
  if (!dayKeyWithinWindow(request.dayKey)) {
    throw new HttpError(
      400,
      "invalid_day_key",
      "dayKey must be within a day of today",
    );
  }
  // The recipient must actually be a circle-mate — checked here as well as by
  // the nudges INSERT policy, so a bogus recipientId never reaches the RPC.
  const recipientCircle = await circleIdFor(admin, request.recipientId);
  if (recipientCircle !== caller.circleId) {
    return json({
      ok: true,
      kind: "nudge",
      sent: false,
      reason: "not_in_circle",
    });
  }

  // record_nudge runs as the CALLER so auth.uid() is the sender: the rate limit
  // (§6, one per sender/recipient/prayer window) is the nudges primary key.
  const asCaller = callerClient(req.headers.get("Authorization") ?? "");
  const { data, error } = await asCaller.rpc("record_nudge", {
    p_recipient: request.recipientId,
    p_day_key: request.dayKey,
    p_prayer: request.prayer,
  });
  if (error) {
    // SB400 is record_nudge's own "that day_key is not a prayer window" — a
    // caller error, not ours, so it must not come back as an opaque 500.
    if ((error as { code?: string }).code === "SB400") {
      throw new HttpError(400, "invalid_day_key", "dayKey is out of window");
    }
    throw new HttpError(500, "record_nudge_failed", error.message);
  }
  if (data !== true) {
    return json({
      ok: true,
      kind: "nudge",
      sent: false,
      reason: "rate_limited",
    });
  }

  const alert = nudgeAlert({
    name: caller.senderName,
    prayer: request.prayer as PrayerKind,
  });
  const devices = await devicesFor(admin, [request.recipientId]);
  return await push(admin, devices, alert, {
    kind: "nudge",
    threadId: `circle-${caller.circleId}`,
    category: "CIRCLE_NUDGE",
    collapseId:
      `nudge-${request.recipientId}-${request.dayKey}-${request.prayer}`,
    // A nudge is window-bound ("there's still time"), so it must not sit in
    // Apple's store-and-retry queue and surface two days later for a prayer
    // that is long gone. One hour is generous for a phone that blinked.
    expiration: expiresIn(NUDGE_TTL_SECONDS),
    // The counts below would tell one member how many live push registrations
    // another member has. Harmless-looking, but it is about a single named
    // person, so the nudge reply says only whether it went.
    countsPrivate: true,
    data: {
      kind: "nudge",
      circleId: caller.circleId,
      fromUserId: caller.callerId,
      dayKey: request.dayKey,
      prayer: request.prayer,
    },
  });
}

/// Apple's default is store-and-retry forever; every push here has a shelf life.
const NUDGE_TTL_SECONDS = 60 * 60;
const POST_TTL_SECONDS = 6 * 60 * 60;
const JOIN_TTL_SECONDS = 24 * 60 * 60;

function expiresIn(seconds: number): number {
  return Math.floor(Date.now() / 1000) + seconds;
}

interface PushOptions {
  kind?: string;
  threadId?: string;
  category?: string;
  collapseId?: string;
  expiration?: number;
  friendActivityOnly?: boolean;
  countsPrivate?: boolean;
  /// The span of local days this alert is still current news on
  /// (`_shared/zones.ts`). Set for POSTS only: a post is about one prayer
  /// window on one schedule day, so a circle-mate whose own day has already
  /// moved past it is being told about something that is over.
  ///
  /// Deliberately absent for JOIN — "Yusuf joined your circle" is not about a
  /// day at all — and unreachable from NUDGE, which never goes through
  /// `fanOut`: a nudge is aimed at ONE named person who was just picked out of
  /// a grid, and silently dropping it would break the one push in §6 a human
  /// deliberately sent.
  ///
  /// `null` means "do not filter" and is the honest answer when the poster's
  /// own zone is unknown.
  relevance?: DayWindow | null;
  /// The instant `relevance` was computed at, reused for every recipient.
  relevanceAt?: number;
  data?: Record<string, unknown>;
}

/// Everyone in the circle except the caller — minus anyone the alert has
/// already gone stale for.
async function fanOut(
  admin: Client,
  caller: Caller,
  alert: Alert,
  opts: PushOptions,
): Promise<Response> {
  const recipients = await circleMemberIds(
    admin,
    caller.circleId,
    caller.callerId,
  );
  const devices = await devicesFor(admin, recipients, {
    friendActivityOnly: opts.friendActivityOnly,
  });
  // Per DEVICE, not per user: the phone in a traveller's pocket re-registers
  // with its new offset on the next foreground, while the iPad left at home
  // still says the old one, and each is judged where it actually is. A device
  // with no recorded offset is always kept — unknown never means silence.
  const { current, stale } = partitionByRelevance(
    devices,
    opts.relevance ?? null,
    opts.relevanceAt ?? Date.now(),
  );
  return await push(admin, current, alert, {
    ...opts,
    kind: opts.kind ?? String(opts.data?.kind ?? "post"),
    outOfZone: stale.length,
  });
}

async function push(
  admin: Client,
  devices: DeviceRow[],
  alert: Alert,
  opts: PushOptions & { outOfZone?: number },
): Promise<Response> {
  const payload = buildAPNsPayload({
    alert,
    threadId: opts.threadId,
    category: opts.category,
    data: opts.data,
  });
  // deliverToDevices log-and-skips when APNs is unconfigured, so a staging
  // project without a push key still answers 200 and the caller carries on.
  const summary = await deliverToDevices(devices, payload, {
    collapseId: opts.collapseId,
    expiration: opts.expiration,
    onUnregistered: (token) => deleteDevice(admin, token),
    onEnvironmentChanged: (token, environment) =>
      setDeviceEnvironment(admin, token, environment),
  });
  if (opts.countsPrivate) {
    return json({ ok: true, kind: opts.kind, sent: summary.delivered > 0 });
  }
  return json({
    ok: true,
    kind: opts.kind,
    sent: summary.delivered > 0,
    devices: summary.attempted,
    delivered: summary.delivered,
    skipped: summary.skipped,
    dropped: summary.unregistered.length,
    // Devices whose local day had already moved past this post. Reported so a
    // "why did nobody get it" question has an answer that is not a guess;
    // `NotifyReply` on the Swift side decodes unknown fields tolerantly.
    outOfZone: opts.outOfZone ?? 0,
  });
}
