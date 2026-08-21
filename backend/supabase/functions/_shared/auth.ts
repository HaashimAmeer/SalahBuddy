// Caller identification helpers.
//
// Both functions run with `verify_jwt = true`, so the platform has ALREADY
// verified the signature of the bearer token before our code is reached.
// Decoding here is therefore about reading claims, never about trusting them:
// the user id we act on is re-resolved against the auth server (`db.ts`
// `resolveCallerId`) and every claim in the request body is re-checked in SQL.

import { base64UrlDecodeString } from "./util.ts";

export function bearerToken(authorizationHeader: string | null): string | null {
  if (!authorizationHeader) return null;
  const match = /^bearer\s+(.+)$/i.exec(authorizationHeader.trim());
  if (!match) return null;
  const token = match[1].trim();
  return token === "" ? null : token;
}

/// Decodes the payload of a JWT WITHOUT verifying it. Returns null for
/// anything that is not a three-part token carrying a JSON object.
export function decodeJwtPayload(jwt: string): Record<string, unknown> | null {
  const parts = jwt.split(".");
  if (parts.length !== 3) return null;
  const text = base64UrlDecodeString(parts[1]);
  if (text === null) return null;
  try {
    const parsed = JSON.parse(text);
    if (
      parsed === null || typeof parsed !== "object" || Array.isArray(parsed)
    ) {
      return null;
    }
    return parsed as Record<string, unknown>;
  } catch {
    return null;
  }
}

/// True when the bearer IS the project's service-role credential.
///
/// Equality against the injected key, and nothing else. The obvious second
/// branch — decode the token and trust `role === "service_role"` — is the one
/// thing this module says it never does, and it would matter: the only caller
/// uses the answer to unlock retention's destructive `days` knob, so a decoded
/// (i.e. unverified) claim would let anyone who can reach the function POST
/// `{"days":1}` and wipe every photo in the project older than a day. Today the
/// platform's `verify_jwt = true` happens to make that unreachable — which is a
/// config flag one `--no-verify-jwt` away from gone, not a security boundary.
///
/// Both credential shapes still work: the legacy service-role JWT and the newer
/// opaque secret key are each compared verbatim against SUPABASE_SERVICE_ROLE_KEY,
/// and the scheduler presents exactly that value.
export function isServiceRoleToken(
  jwt: string,
  serviceRoleKey?: string,
): boolean {
  return serviceRoleKey !== undefined && serviceRoleKey !== "" &&
    jwt === serviceRoleKey;
}

/// The `sub` claim, when it looks like a user id.
export function subjectFromJwt(jwt: string): string | null {
  const sub = decodeJwtPayload(jwt)?.sub;
  return typeof sub === "string" && sub !== "" ? sub : null;
}
