// Tiny dependency-free helpers shared by every edge function.
//
// Everything in here is PURE (or, for readEnv, deliberately failure-tolerant)
// so the Deno tests can exercise it with no network and no permissions.

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/// Reads an env var without ever throwing.
///
/// `Deno.env.get` raises when the process was started without `--allow-env`
/// (which is exactly how the unit tests run). A missing variable and a missing
/// permission mean the same thing to us — "not configured" — so both collapse
/// to `undefined` and the caller log-and-skips.
export function readEnv(name: string): string | undefined {
  try {
    const value = Deno.env.get(name);
    return value === undefined || value === "" ? undefined : value;
  } catch {
    return undefined;
  }
}

/// Splits `items` into runs of at most `size` (APNs/Storage batch calls).
export function chunk<T>(items: readonly T[], size: number): T[][] {
  if (!Number.isFinite(size) || size < 1) {
    throw new Error(`chunk size must be >= 1, got ${size}`);
  }
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) {
    out.push(items.slice(i, i + size) as T[]);
  }
  return out;
}

/// Base64url, no padding — the JOSE flavour used by both APNs JWTs and
/// Supabase access tokens.
export function base64UrlEncode(input: Uint8Array | string): string {
  const bytes = typeof input === "string" ? encoder.encode(input) : input;
  let binary = "";
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(
    /=+$/,
    "",
  );
}

/// Inverse of `base64UrlEncode`. Returns null instead of throwing — callers are
/// decoding attacker-shaped input (a token from a request header).
export function base64UrlDecodeBytes(
  input: string,
): Uint8Array<ArrayBuffer> | null {
  const normalised = input.replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalised + "=".repeat((4 - (normalised.length % 4)) % 4);
  try {
    const binary = atob(padded);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  } catch {
    return null;
  }
}

export function base64UrlDecodeString(input: string): string | null {
  const bytes = base64UrlDecodeBytes(input);
  if (!bytes) return null;
  try {
    return decoder.decode(bytes);
  } catch {
    return null;
  }
}
