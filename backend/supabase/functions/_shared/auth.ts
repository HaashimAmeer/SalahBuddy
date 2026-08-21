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

/// True when the bearer is the project's service-role credential rather than a
/// signed-in human. Covers both shapes: the legacy service-role JWT (role claim)
/// and the newer opaque secret key, which is compared against the injected env
/// value. Only ever consulted after the platform verified the token.
export function isServiceRoleToken(
  jwt: string,
  serviceRoleKey?: string,
): boolean {
  if (serviceRoleKey && jwt === serviceRoleKey) return true;
  const claims = decodeJwtPayload(jwt);
  return claims?.role === "service_role";
}

/// The `sub` claim, when it looks like a user id.
export function subjectFromJwt(jwt: string): string | null {
  const sub = decodeJwtPayload(jwt)?.sub;
  return typeof sub === "string" && sub !== "" ? sub : null;
}
