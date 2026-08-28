// notify's handlers — everything the endpoint does, minus the socket.
//
// `index.ts` is the deployed entrypoint and now does exactly one thing: hand a
// Request to `handle`. The work moved here so it can be IMPORTED, which is what
// makes the §6 fan-out rule testable at all:
//
//     a post is relevance-filtered; a join and a nudge never are.
//
// Nothing enforces that rule but the call sites — `notifyPost` passes
// `relevance` to `fanOut`, `notifyJoin` does not, and `notifyNudge` does not
// reach `fanOut` at all. No type says so, no guard clause says so, and that is
// precisely the kind of invariant somebody tidies away in a "make the three
// paths consistent" refactor. It could not be tested while it lived beside a
// top-level `Deno.serve`: the tests run with no permissions, and importing this
// module would have tried to bind a port. `tests/deno/notify_test.ts` drives all
// three handlers through a fake Supabase client and pins the table.

import {
  APNS_BACKGROUND_PRIORITY,
  APNS_BACKGROUND_PUSH_TYPE,
  buildAPNsPayload,
  buildSilentAPNsPayload,
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

export async function handle(req: Request): Promise<Response> {
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
        // A THUNK, not a client: `notifyNudge` builds the caller-scoped client
        // only after its early returns, and `callerClient` throws on a
        // deployment missing SUPABASE_URL. Handing it one eagerly would turn a
        // self-nudge on a half-configured project from a 200 into a 500.
        () => callerClient(req.headers.get("Authorization") ?? ""),
        { callerId, circleId, senderName },
        request,
      );
  }
}

export interface Caller {
  callerId: string;
  circleId: string;
  senderName: string | null;
}

export async function notifyPost(
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

  // §6 is "X posted FIRST for Fajr", not "X posted": a circle of 8 gets one
  // ALERT per window, not 7. What the rest of them get is v5 §5's quiet reload
  // push, below — so this is now which KIND of push, not whether there is one.
  const first = await isFirstPostInWindow(admin, post);
  // The lease: one notification per post, ever, whichever kind it turned out to
  // be. Nothing else in this function is stateful, so without it the same
  // postId can be re-announced in a loop — and that is as true of a silent
  // push, which nobody would see coming, as it is of a banner.
  //
  // v5 NOTE: this used to sit BELOW the first-post check, deliberately, so that
  // a later poster's postId stayed announceable if the first post were ever
  // deleted. Nothing reaches that state — `notify` is called once, by the
  // poster, right after their upload is acknowledged, and no path re-notifies
  // an existing post — whereas an unleased reload push is a fan-out any member
  // can trigger in a loop from a phone. The lease covers both paths now.
  if (!await claimPostNotification(admin, post.id)) {
    return json({
      ok: true,
      kind: "post",
      sent: false,
      reason: "already_notified",
    });
  }

  // ONE clock read for both halves of the relevance decision. The poster's
  // window and every recipient's local day have to be judged at the same
  // instant: two `Date.now()` calls milliseconds apart can straddle a midnight
  // somewhere, and the invariant that nobody in the poster's own zone is ever
  // filtered would break for exactly the people awake at that moment.
  const now = Date.now();
  // The one filter that is about WHERE the recipient is rather than what they
  // asked for. See `relevance` in PushOptions.
  // logged_at supplies the poster's own clock reading, which is what makes the
  // time-of-day half of the filter possible — without it the window degrades to
  // date-only and a Mumbai member is buzzed at 17:30 about a Seattle Fajr.
  // Date.parse of a null/absent column yields NaN, and relevanceWindow reads a
  // non-finite value as "unknown, do not filter".
  //
  // Computed once and spent by BOTH paths: a reload push about a prayer window
  // that closed twelve hours ago in the recipient's own day is telling a phone
  // to go and redraw something nobody's home screen is about.
  const relevance = relevanceWindow(post.day_key, post.utc_offset, now,
                                    Date.parse(post.logged_at));
  const data = {
    kind: "post",
    circleId: caller.circleId,
    postId: post.id,
    userId: post.user_id,
    dayKey: post.day_key,
    prayer: post.prayer,
  };

  if (!first) return await reloadForPost(admin, caller, post, { relevance, now, data });

  const alert = postAlert({
    name: caller.senderName,
    prayer: post.prayer,
    jamaat: post.jamaat,
    placeLabel: post.place_label,
  });
  return await fanOut(admin, caller, alert, {
    relevance,
    relevanceAt: now,
    threadId: `circle-${caller.circleId}`,
    category: "CIRCLE_POST",
    // One notification per prayer per friend: a burst of posts for the same
    // window collapses instead of stacking.
    collapseId: `post-${post.user_id}-${post.day_key}-${post.prayer}`,
    // Opt-in only: this is the friend-activity toggle, which is off by default.
    friendActivityOnly: true,
    // v5 §5-B: wake the app's notification service extension before the banner,
    // so `reloadAllTimelines()` runs and the home screen is current about a
    // second after a friend posts. It changes nothing a person sees.
    mutableContent: true,
    expiration: expiresIn(POST_TTL_SECONDS),
    data,
  });
}

/// v5 §5 — the `not_first` wrinkle, as its own push.
///
/// §6 only ever announced the FIRST post in a window, and that is right for the
/// tray: one banner per prayer per friend, collapsed, is what somebody asked
/// for when they turned friend activity on. It is wrong for a widget, which
/// then sits on "3 of 5" for the rest of the window while the fourth and fifth
/// people pray. So the alert is untouched and the rest of the window gets a
/// SEPARATE push carrying no alert at all.
///
/// Three deliberate differences from the announcement above, each of which a
/// test pins:
///
/// - **No alert, no sound, no badge, no thread, no category.** Nothing reaches
///   Notification Centre, nothing collapses onto (or replaces) the banner that
///   was already delivered, and there is no way for copy to leak into it — the
///   payload is built by a function that cannot take an `Alert`.
/// - **Not gated on friend activity.** That toggle is a RECEIVING preference
///   about being buzzed ("When someone in your circle posts first"), it is OFF
///   by default, and this push does not buzz. Gating it would leave the widget
///   of everybody who never turned the toggle on — i.e. almost everybody —
///   permanently stale, which is the exact failure §5 exists to fix. It carries
///   no information the recipient's own next pull would not fetch anyway.
/// - **The same relevance filter.** A phone whose local day has already moved
///   past this window has nothing to redraw, and waking it would be worse than
///   the alert it was already spared.
///
/// Best-effort by nature: Apple throttles background pushes and promises
/// nothing. §5 calls it a bonus, never the mechanism, and the counts on the
/// tile are still corrected by the next foreground either way.
async function reloadForPost(
  admin: Client,
  caller: Caller,
  post: { user_id: string; day_key: string; prayer: string },
  ctx: {
    relevance: DayWindow | null;
    now: number;
    data: Record<string, unknown>;
  },
): Promise<Response> {
  return await fanOut(admin, caller, null, {
    relevance: ctx.relevance,
    relevanceAt: ctx.now,
    // Keyed on the WINDOW rather than the poster, unlike the alert's: five
    // people praying Asr within a minute of each other should wake a phone
    // once, not five times, and every one of those pushes is asking for the
    // same single redraw.
    collapseId: `reload-${caller.circleId}-${post.day_key}-${post.prayer}`,
    // Short, because a reload is only worth anything while the window it is
    // about is still the one on the tile. Apple's default is store-and-retry
    // forever, which here would mean waking a phone tomorrow to redraw
    // yesterday.
    expiration: expiresIn(RELOAD_TTL_SECONDS),
    // Reported so the reply is legible: `sent` is about a push nobody will ever
    // see, and `not_first` is what tells a reader which one it was.
    reason: "not_first",
    data: ctx.data,
  });
}

export async function notifyJoin(
  admin: Client,
  caller: Caller,
): Promise<Response> {
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
  // NO `relevance` — deliberately, and pinned by notify_test.ts. "Yusuf joined
  // your circle" is not about a day, so there is no day for a recipient's own
  // to have moved past.
  return await fanOut(admin, caller, alert, {
    threadId: `circle-${caller.circleId}`,
    category: "CIRCLE_JOIN",
    collapseId: `join-${caller.callerId}`,
    expiration: expiresIn(JOIN_TTL_SECONDS),
    data: { kind: "join", circleId: caller.circleId, userId: caller.callerId },
  });
}

export async function notifyNudge(
  admin: Client,
  /// Builds the caller-scoped client. A thunk because it is only needed once
  /// every early return below has been passed — see the call site in `handle`.
  callerClientFor: () => Client,
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
  const asCaller = callerClientFor();
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
  // Straight to `push`, bypassing `fanOut` — which is the only place the
  // relevance filter lives. A nudge is aimed at ONE named person somebody just
  // picked out of a grid; dropping it for being "stale" would break the one
  // push in §6 a human deliberately sent.
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
export const NUDGE_TTL_SECONDS = 60 * 60;
export const POST_TTL_SECONDS = 6 * 60 * 60;
export const JOIN_TTL_SECONDS = 24 * 60 * 60;
/// v5 §5's quiet reload. The shortest of the four on purpose: it is only worth
/// delivering while the window it would redraw is still the current one, and a
/// prayer window is rarely wider than this.
export const RELOAD_TTL_SECONDS = 30 * 60;

function expiresIn(seconds: number): number {
  return Math.floor(Date.now() / 1000) + seconds;
}

export interface PushOptions {
  kind?: string;
  threadId?: string;
  category?: string;
  collapseId?: string;
  expiration?: number;
  friendActivityOnly?: boolean;
  countsPrivate?: boolean;
  /// v5 §5-B: set `mutable-content: 1`, which runs the app's notification
  /// service extension before the banner. ALERTS only — it is meaningless on a
  /// payload with no alert, and `push` ignores it there.
  mutableContent?: boolean;
  /// Echoed into the reply. Only the quiet reload push sets it today
  /// (`"not_first"`), because that is the one push whose `sent: true` describes
  /// something nobody will ever see.
  reason?: string;
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
///
/// `alert: null` is v5 §5's reload-only push. Nullable rather than a separate
/// entry point so that the relevance filter, the friend-activity clause and the
/// per-device partition are literally the same code for both — the quiet push
/// respecting the same zone rule as the loud one is a property, not a habit.
export async function fanOut(
  admin: Client,
  caller: Caller,
  alert: Alert | null,
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

export async function push(
  admin: Client,
  devices: DeviceRow[],
  alert: Alert | null,
  opts: PushOptions & { outOfZone?: number },
): Promise<Response> {
  // v5 §5: no alert means the reload-only payload, and it is chosen by the
  // ABSENCE of copy rather than by a flag — there is no way to hand this
  // function an alert and have it silently not send one, or the other way
  // round. `buildSilentAPNsPayload` cannot take an `Alert` at all.
  const silent = alert === null;
  const payload = silent
    ? buildSilentAPNsPayload({ data: opts.data })
    : buildAPNsPayload({
      alert,
      threadId: opts.threadId,
      category: opts.category,
      mutableContent: opts.mutableContent,
      data: opts.data,
    });
  // deliverToDevices log-and-skips when APNs is unconfigured, so a staging
  // project without a push key still answers 200 and the caller carries on.
  const summary = await deliverToDevices(devices, payload, {
    collapseId: opts.collapseId,
    expiration: opts.expiration,
    // Apple rejects a `content-available` payload sent as an alert, and rejects
    // a background push at priority 10. Both headers move together with the
    // payload shape, here, for that reason.
    pushType: silent ? APNS_BACKGROUND_PUSH_TYPE : undefined,
    priority: silent ? APNS_BACKGROUND_PRIORITY : undefined,
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
    ...(opts.reason ? { reason: opts.reason } : {}),
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
