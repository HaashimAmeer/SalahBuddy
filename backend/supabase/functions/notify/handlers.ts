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
  APNS_LIVE_ACTIVITY_PRIORITY,
  APNS_LIVE_ACTIVITY_PUSH_TYPE,
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
  deleteLiveActivityToken,
  devicesFor,
  isFirstPostInWindow,
  type LiveActivityTokenRow,
  liveActivityTokensFor,
  postById,
  postsInWindow,
  profileFor,
  profilesFor,
  resolveCallerId,
  serviceClient,
  setDeviceEnvironment,
} from "../_shared/db.ts";
import {
  buildLiveActivityContentState,
  buildLiveActivityPush,
  type LiveActivityFace,
} from "../_shared/liveactivity.ts";
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
  // ALERT per window, not 7. Every post, this one included, ALSO gets v5 §5's
  // quiet reload push — so this decides whether there is a banner, not whether
  // there is a push. See `reloadForPost`.
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

  // FIRST, and for every post — see `reloadForPost` for why the first one is
  // not the exception it used to be.
  const reload = await reloadForPost(admin, caller, post, {
    relevance,
    now,
    data,
  });
  // v5 §6, and for every post too: a Live Activity that only moved on the FIRST
  // post would sit on "1 of 5" for the rest of the window, which is the exact
  // thing an activity exists to not do.
  const activity = await liveActivityForPost(admin, caller, post, {
    relevance,
    now,
  });
  if (!first) {
    return reply(reload, {
      kind: "post",
      reason: "not_first",
      liveActivity: activity,
    });
  }

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
    //
    // It is the FAST half, not the whole of it: the extension cannot pull, so
    // what it reloads is whatever the app last wrote. The quiet push above is
    // the half that wakes the app to write a newer file, and an alert is
    // delivered where a background push is throttled — which is why this phase
    // sends both rather than choosing.
    mutableContent: true,
    expiration: expiresIn(POST_TTL_SECONDS),
    // Both fan-outs, in one reply. `sent`/`devices` stay the ANNOUNCEMENT's, as
    // they have always been — the quiet push reaches phones that deliberately
    // get no banner, and folding the two counts together would answer "did
    // anybody hear about this" with a number about widgets.
    reload: {
      devices: reload.devices,
      delivered: reload.delivered,
      outOfZone: reload.outOfZone,
    },
    liveActivity: activity,
    data,
  });
}

/// v5 §5 — the reload push. EVERY post, first or not.
///
/// §6 only ever announced the FIRST post in a window, and that is right for the
/// tray: one banner per prayer per friend, collapsed, is what somebody asked
/// for when they turned friend activity on. It is wrong for a widget, which
/// then sits on "3 of 5" for the rest of the window while the fourth and fifth
/// people pray. So the alert is untouched and every post ALSO fans out a
/// SEPARATE push carrying no alert at all.
///
/// **Why the first post is not the exception it looks like.** P3 sent this only
/// when `!first`, on the reading that the announcement already covered the
/// 0→1 transition. It does not, twice over:
///
/// 1. `mutable-content: 1` launches the notification SERVICE EXTENSION, not the
///    app. iOS calls `didReceiveRemoteNotification` on a suspended app only for
///    a payload carrying `content-available: 1` — so the extension ran, called
///    `reloadAllTimelines()`, and the provider re-read a `widget.json` nobody
///    had been woken to rewrite. The tile re-rendered the same bytes.
/// 2. The alert is `friendActivityOnly`, and that toggle is OFF by default. So
///    the one push the first post did send reached almost nobody, while every
///    LATER post reached everybody — the transition that matters most was the
///    one least likely to propagate, and in a circle where one person prays a
///    given window it never propagated at all.
///
/// Two pushes to the same phone is the price, and only for the first post of a
/// window, only for the minority who opted into the banner. The alert keeps
/// `mutable-content` because it is the RELIABLE half: an alert is delivered
/// where a background push is throttled, so the extension's reload is the fast
/// path and this is the one that makes it worth reloading.
///
/// Three deliberate differences from the announcement, each of which a test
/// pins:
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
/// Sent BEFORE the announcement, in the first-post case, for one reason: the
/// extension reloads whatever the app last wrote, so the app is better off
/// woken first. Neither ordering is a guarantee — APNs makes none — and nothing
/// breaks if they arrive the other way round.
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
): Promise<DeliveredCounts> {
  return await fanOutTo(admin, caller, null, {
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
    data: ctx.data,
  });
}

// --------------------------------------------------- the Live Activity (v5 §6)

/// What one Live Activity fan-out reached. Echoed into the reply beside
/// `reload`, and for the same reason: three fan-outs now leave this function
/// for one post, they deliver to different sets of phones by design, and a
/// reply that reported only the banner's count would read as a mostly-failed
/// send.
export interface LiveActivityCounts {
  /// Activity tokens this post was relevant to.
  tokens: number;
  updated: number;
  /// Activities whose window had already closed — retired rather than moved.
  ended: number;
  delivered: number;
  /// Tokens whose owner's local day had moved past this window.
  outOfZone: number;
  /// Faces the 4 KB budget could not fit. Zero in every ordinary circle; a
  /// number here is the only warning that somebody's Lock Screen is showing
  /// fewer people than it should.
  facesDropped: number;
}

const NO_LIVE_ACTIVITIES: LiveActivityCounts = {
  tokens: 0,
  updated: 0,
  ended: 0,
  delivered: 0,
  outOfZone: 0,
  facesDropped: 0,
};

/// How long an ENDED activity stays on the Lock Screen before the system
/// retires it. Long enough to be seen by somebody who picks their phone up as
/// the window closes; short enough that yesterday's Asr is not still there at
/// Maghrib.
export const LIVE_ACTIVITY_DISMISSAL_SECONDS = 5 * 60;

/// v5 §6 — move every Live Activity this post is about.
///
/// **UPDATES ONLY, and that is a decision rather than an omission.** The table
/// also holds push-to-START tokens, and nothing here spends one. The reason is
/// short and does not get better by being restated in more places, so it lives
/// in backend/README.md under "Who starts a Live Activity": a push-to-start
/// payload must carry the activity's ATTRIBUTES, attributes include the window's
/// `endsAt`, and the server cannot compute one — prayer times are derived
/// on-device from coordinates the backend deliberately does not hold. Any
/// client that could tell us when the window ends is a client that is running,
/// and a running client starts its own activity without a push. The tokens are
/// registered and kept because the day that stops being true, this is a
/// four-line change and the registration is the half that needs a real device
/// to prove.
///
/// Three deliberate properties, each pinned by `notify_test.ts`:
///
/// - **The poster is excluded**, like every other fan-out here. Their own phone
///   is running at that instant and moves its own activity through the same
///   `publishWidgetSnapshot` path that writes `widget.json` — the app is the
///   writer, on its own device, exactly as §3 says.
/// - **The same relevance filter as the alert.** An activity on a phone whose
///   local day has moved past this window is about a prayer that is over there.
/// - **`youLogged` is the only per-phone field**, so this builds at most two
///   payloads per event and groups the tokens under them. Not one push per
///   person: a circle of eight would be eight payload builds and eight 4 KB
///   serialisations for two distinct strings.
async function liveActivityForPost(
  admin: Client,
  caller: Caller,
  post: { user_id: string; day_key: string; prayer: string },
  ctx: { relevance: DayWindow | null; now: number },
): Promise<LiveActivityCounts> {
  const members = await circleMemberIds(admin, caller.circleId);
  const recipients = members.filter((id) => id !== caller.callerId);
  if (recipients.length === 0) return NO_LIVE_ACTIVITIES;

  const all = await liveActivityTokensFor(admin, recipients);
  // Only the activities that are ABOUT this window. A phone running an isha
  // activity has nothing to learn from a dhuhr post, and pushing it one would
  // overwrite the isha content state with dhuhr's counts.
  const matching = all.filter((row) =>
    row.kind === "update" && row.day_key === post.day_key &&
    row.prayer === post.prayer
  );
  if (matching.length === 0) return NO_LIVE_ACTIVITIES;

  const { current, stale } = partitionByRelevance(
    matching,
    ctx.relevance,
    ctx.now,
  );
  if (current.length === 0) {
    return { ...NO_LIVE_ACTIVITIES, tokens: 0, outOfZone: stale.length };
  }

  const window = await windowState(admin, caller.circleId, post, members.length);

  // An activity whose window has already closed is RETIRED rather than moved.
  // Reachable in ordinary use: a make-up logged after the window ends is still
  // a post for that (day, prayer), and it must not resurrect an activity the
  // app has not been awake to end itself.
  const nowSeconds = Math.floor(ctx.now / 1000);
  const ending: LiveActivityTokenRow[] = [];
  const moving: LiveActivityTokenRow[] = [];
  for (const row of current) {
    const endsAt = row.ends_at ? Date.parse(row.ends_at) : NaN;
    // NaN — an unknown end — keeps the activity. Unknown never means silence,
    // the same call `zones.ts` makes about an unknown offset.
    if (Number.isFinite(endsAt) && endsAt <= ctx.now) ending.push(row);
    else moving.push(row);
  }

  let delivered = 0;
  let facesDropped = 0;
  const send = async (
    rows: LiveActivityTokenRow[],
    event: "update" | "end",
  ): Promise<void> => {
    // Two groups at most: `youLogged` is the only field that differs per phone.
    for (const logged of [true, false]) {
      const group = rows.filter((row) => window.prayed.has(row.user_id) === logged);
      if (group.length === 0) continue;
      // The stale date is the window's own end, which every row in a group may
      // spell slightly differently (each device computed its own). The first
      // one is as good as any — they differ by seconds, and the value only
      // decides when iOS starts dimming the activity.
      const endsAt = group.find((row) => row.ends_at)?.ends_at;
      const staleSeconds = endsAt
        ? Math.floor(Date.parse(endsAt) / 1000)
        : undefined;
      const push = buildLiveActivityPush({
        event,
        contentState: buildLiveActivityContentState({
          prayedCount: window.prayed.size,
          memberCount: window.memberCount,
          youLogged: logged,
          faces: window.faces,
          updatedAtSeconds: nowSeconds,
        }),
        timestampSeconds: nowSeconds,
        staleSeconds: Number.isFinite(staleSeconds as number)
          ? staleSeconds
          : undefined,
        dismissalSeconds: event === "end"
          ? nowSeconds + LIVE_ACTIVITY_DISMISSAL_SECONDS
          : undefined,
      });
      facesDropped = Math.max(facesDropped, push.facesDropped);
      const summary = await deliverToDevices(
        group.map((row) => ({
          user_id: row.user_id,
          apns_token: row.token,
          environment: row.environment,
          utc_offset: row.utc_offset,
        })),
        push.payload,
        {
          pushType: APNS_LIVE_ACTIVITY_PUSH_TYPE,
          priority: APNS_LIVE_ACTIVITY_PRIORITY,
          // Keyed on the WINDOW: several people praying within a minute of each
          // other are asking for one redraw of the same activity, not five.
          collapseId:
            `activity-${caller.circleId}-${post.day_key}-${post.prayer}`,
          // An activity update is worth nothing once its window is over; Apple's
          // default is store-and-retry forever.
          expiration: expiresIn(RELOAD_TTL_SECONDS),
          // A dead ACTIVITY token, not a dead device: the phone is fine, the
          // activity it addressed is gone. Deleting the `devices` row here would
          // silence a working phone's alerts for the life of the install.
          onUnregistered: (token) => deleteLiveActivityToken(admin, token),
        },
      );
      delivered += summary.delivered;
    }
    // An activity we just retired has no address left worth keeping. The sweep
    // (`purge_expired_live_activity_tokens`) would collect these within twelve
    // hours anyway; doing it here means the next post in the window does not
    // pay for them.
    if (event === "end") {
      for (const row of rows) await deleteLiveActivityToken(admin, row.token);
    }
  };

  if (moving.length > 0) await send(moving, "update");
  if (ending.length > 0) await send(ending, "end");

  return {
    tokens: current.length,
    updated: moving.length,
    ended: ending.length,
    delivered,
    outOfZone: stale.length,
    facesDropped,
  };
}

/// The counts and faces every recipient's activity shares, read once.
///
/// `memberCount` is the circle's size INCLUDING the poster and the recipient —
/// "3 of 5 prayed" is the same sentence the widget writes, and it is the whole
/// circle. `prayed` is by USER, not by post, because a make-up and an in-window
/// post are one person either way.
async function windowState(
  admin: Client,
  circleId: string,
  post: { day_key: string; prayer: string },
  memberCount: number,
): Promise<{ prayed: Set<string>; memberCount: number; faces: LiveActivityFace[] }> {
  const rows = await postsInWindow(admin, circleId, post.day_key, post.prayer);
  const prayed = new Set<string>(rows.map((row) => row.user_id));
  const profiles = await profilesFor(admin, [...prayed]);
  const byId = new Map(profiles.map((row) => [row.id, row]));

  const faces: LiveActivityFace[] = [];
  const seen = new Set<string>();
  // `postsInWindow` is already newest-first; one face per person, the newest of
  // their posts, which is what `WidgetSnapshotBuilder.orderedPosts` does too.
  for (const row of rows) {
    if (seen.has(row.user_id)) continue;
    seen.add(row.user_id);
    const profile = byId.get(row.user_id);
    faces.push({
      // An empty name is the ordinary state for somebody who has not set one —
      // `CircleSnapshot` prints "Friend" for exactly this, and so does this.
      name: (profile?.name ?? "").trim() || "Friend",
      emoji: profile?.avatar_emoji ?? "🙂",
      tier: row.tier,
    });
  }
  return { prayed, memberCount, faces };
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
  /// v5 §5 (review): the quiet reload fan-out that went ALONGSIDE this alert.
  /// Echoed into the reply so "the banner reached 1 phone and the reload
  /// reached 5" is answerable from one call — the two counts differ by design
  /// (the alert is friend-activity gated, the reload is not) and a reply that
  /// showed only the first would read as a fan-out that had mostly failed.
  reload?: { devices: number; delivered: number; outOfZone: number };
  /// v5 §6: the Live Activity fan-out that went alongside. Same reasoning as
  /// `reload` — it reaches a different set of phones (those with a running
  /// activity for this window) and is usually a different number.
  liveActivity?: LiveActivityCounts;
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

/// What one fan-out actually reached. Counts rather than a `Response`, because
/// a FIRST post makes two fan-outs (v5 §5, `reloadForPost`) and can answer only
/// once — so the reply had to stop being the only thing a delivery produces.
export interface DeliveredCounts {
  devices: number;
  delivered: number;
  skipped: number;
  dropped: number;
  outOfZone: number;
}

/// Everyone in the circle except the caller — minus anyone the alert has
/// already gone stale for.
///
/// `alert: null` is v5 §5's reload-only push. Nullable rather than a separate
/// entry point so that the relevance filter, the friend-activity clause and the
/// per-device partition are literally the same code for both — the quiet push
/// respecting the same zone rule as the loud one is a property, not a habit.
export async function fanOutTo(
  admin: Client,
  caller: Caller,
  alert: Alert | null,
  opts: PushOptions,
): Promise<DeliveredCounts> {
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
  const counts = await deliver(admin, current, alert, opts);
  return { ...counts, outOfZone: stale.length };
}

/// `fanOutTo`, plus the reply — the shape every handler but `notifyPost` wants.
export async function fanOut(
  admin: Client,
  caller: Caller,
  alert: Alert | null,
  opts: PushOptions,
): Promise<Response> {
  return reply(await fanOutTo(admin, caller, alert, opts), opts);
}

export async function push(
  admin: Client,
  devices: DeviceRow[],
  alert: Alert | null,
  opts: PushOptions & { outOfZone?: number },
): Promise<Response> {
  const counts = await deliver(admin, devices, alert, opts);
  return reply({ ...counts, outOfZone: opts.outOfZone ?? 0 }, opts);
}

/// Build the payload, send it, count what happened. The one place the payload
/// SHAPE and the two headers that must match it are decided together.
async function deliver(
  admin: Client,
  devices: DeviceRow[],
  alert: Alert | null,
  opts: PushOptions,
): Promise<Omit<DeliveredCounts, "outOfZone">> {
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
  return {
    devices: summary.attempted,
    delivered: summary.delivered,
    skipped: summary.skipped,
    dropped: summary.unregistered.length,
  };
}

/// The 200 a handler answers with. `NotifyReply` on the Swift side decodes
/// unknown fields tolerantly, so this can gain a field without a client change.
function reply(counts: DeliveredCounts, opts: PushOptions): Response {
  const kind = opts.kind ?? String(opts.data?.kind ?? "post");
  if (opts.countsPrivate) {
    return json({ ok: true, kind, sent: counts.delivered > 0 });
  }
  return json({
    ok: true,
    kind,
    sent: counts.delivered > 0,
    ...(opts.reason ? { reason: opts.reason } : {}),
    devices: counts.devices,
    delivered: counts.delivered,
    skipped: counts.skipped,
    dropped: counts.dropped,
    // Devices whose local day had already moved past this post. Reported so a
    // "why did nobody get it" question has an answer that is not a guess.
    outOfZone: counts.outOfZone,
    ...(opts.reload ? { reload: opts.reload } : {}),
    ...(opts.liveActivity ? { liveActivity: opts.liveActivity } : {}),
  });
}
