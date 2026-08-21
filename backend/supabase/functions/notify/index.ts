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
  type Client,
  deleteDevice,
  devicesFor,
  postById,
  profileFor,
  resolveCallerId,
  serviceClient,
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
  isPrayerKind,
  type NotifyRequest,
  parseNotifyRequest,
  type PrayerKind,
} from "../_shared/validate.ts";

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

  const alert = postAlert({
    name: caller.senderName,
    prayer: post.prayer,
    jamaat: post.jamaat,
    placeLabel: post.place_label,
  });
  return await fanOut(admin, caller, alert, {
    threadId: `circle-${caller.circleId}`,
    category: "CIRCLE_POST",
    // One notification per prayer per friend: a burst of posts for the same
    // window collapses instead of stacking.
    collapseId: `post-${post.user_id}-${post.day_key}-${post.prayer}`,
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
  const alert = joinAlert({ name: caller.senderName });
  return await fanOut(admin, caller, alert, {
    threadId: `circle-${caller.circleId}`,
    category: "CIRCLE_JOIN",
    collapseId: `join-${caller.callerId}`,
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
  if (error) throw new HttpError(500, "record_nudge_failed", error.message);
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
    data: {
      kind: "nudge",
      circleId: caller.circleId,
      fromUserId: caller.callerId,
      dayKey: request.dayKey,
      prayer: request.prayer,
    },
  });
}

interface PushOptions {
  kind?: string;
  threadId?: string;
  category?: string;
  collapseId?: string;
  data?: Record<string, unknown>;
}

/// Everyone in the circle except the caller.
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
  const devices = await devicesFor(admin, recipients);
  return await push(admin, devices, alert, {
    ...opts,
    kind: opts.kind ?? String(opts.data?.kind ?? "post"),
  });
}

async function push(
  admin: Client,
  devices: DeviceRow[],
  alert: Alert,
  opts: PushOptions,
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
    onUnregistered: (token) => deleteDevice(admin, token),
  });
  return json({
    ok: true,
    kind: opts.kind,
    sent: summary.delivered > 0,
    devices: summary.attempted,
    delivered: summary.delivered,
    skipped: summary.skipped,
    dropped: summary.unregistered.length,
  });
}
