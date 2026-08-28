// Supabase clients + the small set of reads the functions need.
//
// Two clients, two jobs:
//   * `serviceClient()` bypasses RLS and is the ONLY thing we believe. Every
//     claim in a request body is re-checked through it.
//   * `callerClient()` forwards the caller's own JWT so `auth.uid()` resolves
//     inside SECURITY DEFINER RPCs (record_nudge derives the sender from it —
//     the sender is never taken from the body).
//
// SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY are injected by
// the platform at runtime. Nothing here reads a repo-managed secret.

import {
  createClient,
  type SupabaseClient,
} from "npm:@supabase/supabase-js@2.58.0";
import { HttpError } from "./http.ts";
import { readEnv } from "./util.ts";
import type { DeviceRow } from "./apns.ts";

export const SUPABASE_URL_ENV = "SUPABASE_URL";
export const SUPABASE_ANON_KEY_ENV = "SUPABASE_ANON_KEY";
export const SUPABASE_SERVICE_ROLE_KEY_ENV = "SUPABASE_SERVICE_ROLE_KEY";

export type Client = SupabaseClient;

function requireEnv(name: string): string {
  const value = readEnv(name);
  if (!value) {
    // Misconfiguration, not a caller error — and we never echo the name/value
    // of a secret beyond the variable name itself.
    throw new HttpError(500, "missing_env", `${name} is not set`);
  }
  return value;
}

/// Service-role client: bypasses RLS. Never hand its results to a caller
/// without first checking the caller is entitled to them.
export function serviceClient(): Client {
  return createClient(
    requireEnv(SUPABASE_URL_ENV),
    requireEnv(SUPABASE_SERVICE_ROLE_KEY_ENV),
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
}

/// Client that acts AS the caller (RLS + auth.uid() apply).
export function callerClient(authorizationHeader: string): Client {
  const apiKey = readEnv(SUPABASE_ANON_KEY_ENV) ??
    requireEnv(SUPABASE_SERVICE_ROLE_KEY_ENV);
  return createClient(requireEnv(SUPABASE_URL_ENV), apiKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: authorizationHeader } },
  });
}

/// Resolves the bearer token to a real user id via the auth server.
/// `verify_jwt = true` already proved the signature; this proves the user still
/// exists and is not banned.
export async function resolveCallerId(
  admin: Client,
  jwt: string,
): Promise<string | null> {
  const { data, error } = await admin.auth.getUser(jwt);
  if (error || !data?.user?.id) return null;
  return data.user.id;
}

export interface ProfileRow {
  id: string;
  name: string | null;
}

export async function profileFor(
  admin: Client,
  userId: string,
): Promise<ProfileRow | null> {
  const { data, error } = await admin
    .from("profiles")
    .select("id,name")
    .eq("id", userId)
    .maybeSingle();
  if (error) throw new HttpError(500, "profile_lookup_failed", error.message);
  return (data as ProfileRow | null) ?? null;
}

/// The caller's circle — the one membership row `unique (user_id)` allows.
export async function circleIdFor(
  admin: Client,
  userId: string,
): Promise<string | null> {
  const { data, error } = await admin
    .from("circle_members")
    .select("circle_id")
    .eq("user_id", userId)
    .maybeSingle();
  if (error) throw new HttpError(500, "circle_lookup_failed", error.message);
  return (data as { circle_id: string } | null)?.circle_id ?? null;
}

export async function circleMemberIds(
  admin: Client,
  circleId: string,
  excludeUserId?: string,
): Promise<string[]> {
  let query = admin
    .from("circle_members")
    .select("user_id")
    .eq("circle_id", circleId);
  if (excludeUserId) query = query.neq("user_id", excludeUserId);
  const { data, error } = await query;
  if (error) throw new HttpError(500, "members_lookup_failed", error.message);
  return ((data ?? []) as { user_id: string }[]).map((row) => row.user_id);
}

/// Hard ceiling on how many device rows one fan-out will ever touch. The DB
/// trigger already caps each user at max_devices_per_user(), so 8 members × 10
/// devices is the real worst case; this is the belt to that suspenders, so a cap
/// that is ever raised in SQL cannot silently turn one post into a 5,000-push
/// invocation that outlives the function's wall clock.
export const MAX_FAN_OUT_DEVICES = 80;

export async function devicesFor(
  admin: Client,
  userIds: readonly string[],
  opts: { friendActivityOnly?: boolean } = {},
): Promise<DeviceRow[]> {
  if (userIds.length === 0) return [];
  let query = admin
    .from("devices")
    // `utc_offset` (20260822000500) is what lets `notify` decide whether a
    // post's day_key is still the recipient's current local day — see
    // `_shared/zones.ts`. Selected here for every caller because the filtering
    // decision belongs to the caller, not to the lookup.
    .select("user_id,apns_token,environment,utc_offset")
    .in("user_id", userIds as string[]);
  // §6's friend-activity push is opt-in and OFF by default. iOS cannot suppress
  // an alert it has already been handed, so the toggle has to be applied here.
  if (opts.friendActivityOnly) {
    query = query.eq("notify_friend_activity", true);
  }
  const { data, error } = await query
    .order("updated_at", { ascending: false })
    .limit(MAX_FAN_OUT_DEVICES);
  if (error) throw new HttpError(500, "devices_lookup_failed", error.message);
  return (data ?? []) as DeviceRow[];
}

/// Drops a token Apple told us is dead (410 / Unregistered, or rejected by both
/// hosts).
export async function deleteDevice(
  admin: Client,
  token: string,
): Promise<void> {
  const { error } = await admin.from("devices").delete().eq(
    "apns_token",
    token,
  );
  if (error) console.error("devices: delete failed", error.message);
}

/// Remembers which APNs host a token actually answers on, so the next push does
/// not have to discover it again.
export async function setDeviceEnvironment(
  admin: Client,
  token: string,
  environment: string,
): Promise<void> {
  const { error } = await admin
    .from("devices")
    .update({ environment })
    .eq("apns_token", token);
  if (error) console.error("devices: environment update failed", error.message);
}

/// Claims the one-and-only announcement for a post, atomically.
///
/// `notified_at is null` in the WHERE is the lease: two concurrent calls, or a
/// client re-POSTing the same postId in a loop, produce exactly one row here and
/// therefore exactly one fan-out. Nothing else in the function is stateful, so
/// without this a member could re-announce themselves to the circle forever.
export async function claimPostNotification(
  admin: Client,
  postId: string,
): Promise<boolean> {
  const { data, error } = await admin
    .from("posts")
    .update({ notified_at: new Date().toISOString() })
    .eq("id", postId)
    .is("notified_at", null)
    .select("id");
  if (error) throw new HttpError(500, "notify_claim_failed", error.message);
  return (data ?? []).length > 0;
}

/// True when no earlier post exists for this (circle, day, prayer).
///
/// §6 is specific: "X posted FIRST for Fajr". Announcing every post instead
/// means up to 7 alerts per prayer window per member — and they do not even
/// collapse, because the collapse id is keyed on the poster.
export async function isFirstPostInWindow(
  admin: Client,
  post: Pick<PostRow, "id" | "circle_id" | "day_key" | "prayer">,
): Promise<boolean> {
  const { data, error } = await admin
    .from("posts")
    .select("id")
    .eq("circle_id", post.circle_id)
    .eq("day_key", post.day_key)
    .eq("prayer", post.prayer)
    .neq("id", post.id)
    .limit(1);
  if (error) throw new HttpError(500, "first_post_lookup_failed", error.message);
  return (data ?? []).length === 0;
}

/// The same lease shape for "member joined", keyed on the membership row.
/// Without it any member can POST {kind:"join"} in a loop and fan a push out to
/// all seven circle-mates on every request, forever.
export async function claimJoinAnnouncement(
  admin: Client,
  userId: string,
  circleId: string,
): Promise<boolean> {
  const { data, error } = await admin
    .from("circle_members")
    .update({ announced_at: new Date().toISOString() })
    .eq("user_id", userId)
    .eq("circle_id", circleId)
    .is("announced_at", null)
    .select("user_id");
  if (error) throw new HttpError(500, "join_claim_failed", error.message);
  return (data ?? []).length > 0;
}

// ------------------------------------------------------- Live Activities (§6)

/// One row of `live_activity_tokens` (20260828000200).
///
/// Shaped so it can be handed to `deliverToDevices` by renaming one field —
/// `apns_token: row.token` — which is the whole reason the delivery module
/// takes a `DeviceRow` rather than reading a table itself. The zone filter then
/// applies unchanged: a liveactivity push is about ONE prayer window on ONE
/// schedule day, so a phone whose local day has moved past it has nothing left
/// to draw.
export interface LiveActivityTokenRow {
  token: string;
  user_id: string;
  kind: "start" | "update" | string;
  day_key: string | null;
  prayer: string | null;
  /// When the activity's window closes, in ISO 8601, as the device that started
  /// it computed. Null for a push-to-start token, and null for an activity
  /// registered by a build that did not send it — read as "unknown", never
  /// defaulted. See the column comment in the migration.
  ends_at: string | null;
  environment: string;
  utc_offset?: number | null;
}

/// Same ceiling and the same reasoning as `MAX_FAN_OUT_DEVICES`: the per-user
/// cap trigger already bounds the table, and this is the belt to that
/// suspenders so a cap raised in SQL cannot turn one post into an invocation
/// that outlives its wall clock. Higher than the device cap because a phone can
/// legitimately hold a push-to-start token AND a running activity at once.
export const MAX_FAN_OUT_LIVE_ACTIVITIES = 120;

export async function liveActivityTokensFor(
  admin: Client,
  userIds: readonly string[],
): Promise<LiveActivityTokenRow[]> {
  if (userIds.length === 0) return [];
  const { data, error } = await admin
    .from("live_activity_tokens")
    .select("token,user_id,kind,day_key,prayer,ends_at,environment,utc_offset")
    .in("user_id", userIds as string[])
    .order("updated_at", { ascending: false })
    .limit(MAX_FAN_OUT_LIVE_ACTIVITIES);
  if (error) {
    throw new HttpError(500, "live_activity_lookup_failed", error.message);
  }
  return (data ?? []) as LiveActivityTokenRow[];
}

/// Drops a token Apple told us is dead, or one whose activity has ended.
///
/// Never throws — for the same reason `deleteDevice` does not. A row that
/// outlives its activity costs one wasted round trip per post until the sweep
/// collects it (`purge_expired_live_activity_tokens`), which is not worth
/// failing a fan-out over.
export async function deleteLiveActivityToken(
  admin: Client,
  token: string,
): Promise<void> {
  const { error } = await admin
    .from("live_activity_tokens")
    .delete()
    .eq("token", token);
  if (error) {
    console.error("live_activity_tokens: delete failed", error.message);
  }
}

/// Who in this circle has prayed this window, and what it looked like.
///
/// One query, spent by every recipient: the counts are the same for everybody
/// (`prayedCount`/`memberCount`), and the only per-phone fact — "have YOU
/// prayed" — is a set membership test against the ids this returns.
///
/// Ordered newest first, like `WidgetSnapshotBuilder.orderedPosts` on the
/// device, so the faces a Live Activity shows are the same four the home screen
/// would.
export async function postsInWindow(
  admin: Client,
  circleId: string,
  dayKey: string,
  prayer: string,
): Promise<{ user_id: string; tier: string; logged_at: string }[]> {
  const { data, error } = await admin
    .from("posts")
    .select("user_id,tier,logged_at")
    .eq("circle_id", circleId)
    .eq("day_key", dayKey)
    .eq("prayer", prayer)
    .order("logged_at", { ascending: false })
    .limit(MAX_FAN_OUT_DEVICES);
  if (error) {
    throw new HttpError(500, "window_posts_lookup_failed", error.message);
  }
  return (data ?? []) as { user_id: string; tier: string; logged_at: string }[];
}

export interface NamedProfileRow {
  id: string;
  name: string | null;
  avatar_emoji: string | null;
}

/// Names and emoji for a set of circle-mates. The two fields a Live Activity is
/// allowed to draw about somebody else (§6), and nothing more — no avatar path,
/// which would be a photo reference in a payload that cannot carry photos.
export async function profilesFor(
  admin: Client,
  userIds: readonly string[],
): Promise<NamedProfileRow[]> {
  if (userIds.length === 0) return [];
  const { data, error } = await admin
    .from("profiles")
    .select("id,name,avatar_emoji")
    .in("id", userIds as string[]);
  if (error) throw new HttpError(500, "profile_lookup_failed", error.message);
  return (data ?? []) as NamedProfileRow[];
}

export interface PostRow {
  id: string;
  user_id: string;
  circle_id: string;
  day_key: string;
  prayer: string;
  tier: string;
  jamaat: boolean;
  place_label: string | null;
  /// The POSTER's zone at the moment they logged (20260822000200). `day_key`
  /// alone cannot say whether an alert is stale for a recipient: paired with
  /// this it can. Nullable — rows written before that migration have no answer,
  /// and `relevanceWindow` reads that as "do not filter".
  utc_offset: number | null;
  /// When the poster logged it, UTC. With `utc_offset` this gives the poster's
  /// own LOCAL clock reading, which is the half of the relevance filter that
  /// `day_key` cannot supply: a Seattle Fajr and a Mumbai evening share a
  /// calendar date, and only the clock readings tell them apart.
  logged_at: string;
}

export async function postById(
  admin: Client,
  postId: string,
): Promise<PostRow | null> {
  const { data, error } = await admin
    .from("posts")
    .select(
      "id,user_id,circle_id,day_key,prayer,tier,jamaat,place_label,utc_offset,logged_at",
    )
    .eq("id", postId)
    .maybeSingle();
  if (error) throw new HttpError(500, "post_lookup_failed", error.message);
  return (data as PostRow | null) ?? null;
}
