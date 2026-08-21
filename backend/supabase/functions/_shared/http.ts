// Request/response plumbing shared by the edge functions.
//
// House rule from the brief: the functions answer 200 with a JSON body that
// says what happened. 4xx is reserved for "we could not even understand or
// authenticate you" — a push that was skipped is a successful call with
// `sent: false`, not an error.

export const CORS_HEADERS: Record<string, string> = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers":
    "authorization, x-client-info, apikey, content-type",
  "access-control-allow-methods": "GET, POST, OPTIONS",
};

/// An error we are happy to surface to the caller: status + stable machine code.
/// Anything else that escapes a handler becomes an opaque 500 (never leak
/// internals — the repo is public and so are the logs of a shared project).
export class HttpError extends Error {
  readonly status: number;
  readonly code: string;

  constructor(status: number, code: string, message?: string) {
    super(message ?? code);
    this.name = "HttpError";
    this.status = status;
    this.code = code;
  }
}

export function json(
  body: unknown,
  status = 200,
  headers: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      ...CORS_HEADERS,
      ...headers,
    },
  });
}

/// Answers a CORS preflight; returns null when the request is not one.
export function handleOptions(req: Request): Response | null {
  if (req.method !== "OPTIONS") return null;
  return new Response(null, { status: 204, headers: CORS_HEADERS });
}

export function requireMethod(req: Request, allowed: readonly string[]): void {
  if (!allowed.includes(req.method)) {
    throw new HttpError(
      405,
      "method_not_allowed",
      `${req.method} not allowed; use ${allowed.join(" or ")}`,
    );
  }
}

/// Parses a JSON body, tolerating an empty one (`{}`).
/// The result is `unknown` on purpose — every field is validated downstream.
export async function readJsonBody(req: Request): Promise<unknown> {
  let raw: string;
  try {
    raw = await req.text();
  } catch {
    throw new HttpError(400, "unreadable_body");
  }
  if (raw.trim() === "") return {};
  try {
    return JSON.parse(raw);
  } catch {
    throw new HttpError(400, "invalid_json");
  }
}

export function errorResponse(err: unknown): Response {
  if (err instanceof HttpError) {
    // 4xx messages are the actionable ones — "dayKey must be yyyy-MM-dd" is
    // written for the caller and says nothing about the inside of the system.
    // 5xx messages are not: every DB helper builds one from a PostgREST/Postgres
    // error, so surfacing it hands any authenticated caller constraint names,
    // column names and function signatures. Log it, return the code.
    if (err.status >= 500) {
      console.error("server error", err.code, err.message);
      return json({ ok: false, error: err.code }, err.status);
    }
    return json(
      { ok: false, error: err.code, message: err.message },
      err.status,
    );
  }
  console.error("unhandled error", err);
  return json({ ok: false, error: "internal_error" }, 500);
}
