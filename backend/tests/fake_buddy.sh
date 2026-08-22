#!/usr/bin/env bash
# A real second member of your circle, driven from a terminal.
#
# WHY THIS EXISTS
# ---------------
# Four items on V4-PUNCHLIST.md need two people on two phones, and the most
# important one — "both leaderboards show the same numbers", SPEC-V4 §10's
# Phase C exit criterion — cannot be checked any other way. There is no
# server-side scoring: every device downloads raw posts and runs GameEngine
# itself. Two independent computations of the same rows is the ONLY way to
# catch the two drifting apart.
#
# This is NOT the demo circle. BuddySimulator invents friends on-device and
# never touches the network, so it proves nothing about sync. This signs up a
# genuine account against the real staging project and posts through the same
# PostgREST API the app uses. The server cannot tell the difference, and
# shouldn't be able to — that is what makes it a valid test.
#
# WHAT IT CANNOT DO
# -----------------
# It exercises the server contract and YOUR phone's half of the conversation.
# It says nothing about how a second real iPhone renders things. It shrinks the
# two-phone list; it does not delete it.
#
# USAGE
#   ./backend/tests/fake_buddy.sh join <INVITE_CODE> [display-name]
#   ./backend/tests/fake_buddy.sh post <prayer> <tier> [jamaat]
#   ./backend/tests/fake_buddy.sh rest
#   ./backend/tests/fake_buddy.sh status
#   ./backend/tests/fake_buddy.sh cleanup
#
#   prayer: fajr | dhuhr | asr | maghrib | isha
#   tier:   onTime | prayed | lastCall | closeCall | qada
#
# STAGING ONLY. It creates real rows under a real account. `cleanup` calls
# delete_account() to purge them.
set -euo pipefail

# Public config, identical to Sources/Core/Sync/SupabaseConfig.swift. The
# publishable key grants NOTHING on its own — RLS is the security boundary,
# which the smoke job asserts over HTTP on every deploy.
URL="${SUPABASE_URL:-https://rmyygmyxppmnzcnvprvb.supabase.co}"
KEY="${SUPABASE_PUBLISHABLE_KEY:-sb_publishable_CDUUDqJc8edrT92QIIq8FA_sYz1ut3Q}"
EMAIL_DOMAIN="${SUPABASE_CI_EMAIL_DOMAIN:-salahbuddy.app}"

STATE="$(dirname "$0")/.fake_buddy_state"

command -v jq >/dev/null || { echo "need jq: brew install jq" >&2; exit 1; }

CODE=""; RESP=""
# `prefer` is per-call and NOT always representation. Asking PostgREST to echo
# the row requires SELECT on every column it echoes, and excused_days /
# recovery_weeks grant SELECT column-scoped ON PURPOSE — created_at would pin
# the minute a break started, which §3 says is nobody's business. A blanket
# return=representation therefore turns a legal insert into
# "permission denied for table excused_days", which reads like a broken grant
# rather than an over-eager request header.
api() { # method path jwt [body] [prefer]
  local method="$1" path="$2" jwt="$3" body="${4:-}" prefer="${5:-return=representation}" auth
  auth="apikey: $KEY"
  local -a args=(-sS -X "$method" "$URL$path" -H "$auth" -H "Content-Type: application/json")
  [ "$jwt" != "-" ] && args+=(-H "Authorization: Bearer $jwt")
  args+=(-H "Prefer: $prefer")
  [ -n "$body" ] && args+=(-d "$body")
  local out
  out="$(curl "${args[@]}" -w $'\n%{http_code}' 2>&1)"
  CODE="${out##*$'\n'}"
  RESP="${out%$'\n'*}"
}
jqr() { printf '%s' "$RESP" | jq -r "$1" 2>/dev/null || printf ''; }

die() { echo "✗ $*" >&2; exit 1; }

# XP must mirror GameEngine.prayerXP EXACTLY — this is the number you compare
# against your phone, so a wrong constant here manufactures a false alarm.
# jamaat is a FLOOR, not a bonus: max(tier.xp, 30). (The comment on
# Models.swift:126 still says "+5 XP" and is stale.)
tier_xp() {
  case "$1" in
    onTime) echo 30 ;; prayed) echo 20 ;; lastCall) echo 15 ;;
    closeCall) echo 12 ;; qada) echo 5 ;;
    *) die "unknown tier '$1' (onTime|prayed|lastCall|closeCall|qada)" ;;
  esac
}

save_state() {
  umask 077   # the file holds a session token
  cat > "$STATE" <<EOF
BUDDY_EMAIL='$BUDDY_EMAIL'
BUDDY_PASSWORD='$BUDDY_PASSWORD'
BUDDY_ID='$BUDDY_ID'
BUDDY_NAME='$BUDDY_NAME'
CIRCLE_ID='$CIRCLE_ID'
JWT='$JWT'
EOF
}

load_state() {
  [ -f "$STATE" ] || die "no buddy yet — run: $0 join <INVITE_CODE>"
  # shellcheck disable=SC1090
  . "$STATE"
}

# Access tokens expire (1h by default), so every command re-signs in rather
# than trusting the stored one. A stale JWT fails as 401 PGRST301, which reads
# like an RLS refusal and would send you debugging the wrong thing entirely.
refresh_jwt() {
  api POST "/auth/v1/token?grant_type=password" "-" \
    "$(jq -nc --arg e "$BUDDY_EMAIL" --arg p "$BUDDY_PASSWORD" '{email:$e,password:$p}')"
  JWT="$(jqr '.access_token // empty')"
  [ -n "$JWT" ] || die "could not sign the buddy back in (HTTP $CODE): $(jqr '.error_code // .msg // "unknown"')"
  save_state
}

cmd_join() {
  local invite="${1:-}" name="${2:-Test Buddy}"
  [ -n "$invite" ] || die "usage: $0 join <INVITE_CODE> [display-name]"
  # The app shows the code in this alphabet; catching a typo here beats a
  # confusing SB404 from the server.
  printf '%s' "$invite" | grep -Eq '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$' \
    || die "'$invite' is not a 6-char invite code (no I, O, 0 or 1 in the alphabet)"

  [ -f "$STATE" ] && echo "note: replacing the previous buddy — run 'cleanup' first to purge it"

  BUDDY_EMAIL="salahbuddy-buddy-$(date +%s)@${EMAIL_DOMAIN}"
  BUDDY_PASSWORD="$(openssl rand -base64 21)"
  BUDDY_NAME="$name"

  # full_name rides along in the signup metadata because handle_new_user()
  # reads it when it auto-creates the profiles row — the same path a real
  # Apple/Google sign-in takes. Without it the row is created with name ''.
  api POST "/auth/v1/signup" "-" \
    "$(jq -nc --arg e "$BUDDY_EMAIL" --arg p "$BUDDY_PASSWORD" --arg n "$BUDDY_NAME" \
       '{email:$e,password:$p,data:{full_name:$n}}')"
  [ "$CODE" = "200" ] || [ "$CODE" = "201" ] \
    || die "signup failed (HTTP $CODE): $(jqr '.error_code // .msg // "unknown"')"
  if [ -z "$(jqr '.access_token // empty')" ] && [ -n "$(jqr '.confirmation_sent_at // empty')" ]; then
    die "the project wants email confirmation — turn 'Confirm email' OFF (Authentication > Sign In / Providers > User Signups)"
  fi
  BUDDY_ID="$(jqr '.user.id // .id // empty')"
  [ -n "$BUDDY_ID" ] || die "signup returned no user id"

  CIRCLE_ID=""; JWT=""
  refresh_jwt

  # A name, so your phone shows a person rather than a blank row.
  #
  # UPDATE first, INSERT only as a fallback — the mirror image of what
  # AuthService does, and for the same reason: handle_new_user() already
  # inserted this row at signup, so a plain INSERT is refused 409. (An upsert
  # is not an option either: the grant gives update(name, ...) WITHOUT id, and
  # PostgREST puts every payload column into the `on conflict do update set`
  # clause, which Postgres then refuses for want of the column privilege.)
  api PATCH "/rest/v1/profiles?id=eq.$BUDDY_ID" "$JWT" \
    "$(jq -nc --arg n "$BUDDY_NAME" '{name:$n,avatar_emoji:"🌙"}')"
  if [ "$(printf '%s' "$RESP" | jq 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)" = "0" ]; then
    api POST "/rest/v1/profiles" "$JWT" \
      "$(jq -nc --arg i "$BUDDY_ID" --arg n "$BUDDY_NAME" '{id:$i,name:$n,avatar_emoji:"🌙"}')"
    [ "$CODE" = "201" ] || [ "$CODE" = "200" ] \
      || echo "warning: could not set the buddy's name (HTTP $CODE) — they may show unnamed"
  fi

  api POST "/rest/v1/rpc/join_circle" "$JWT" "$(jq -nc --arg c "$invite" '{p_code:$c}')"
  CIRCLE_ID="$(jqr 'if type=="array" then .[0] else . end | .id // empty')"
  if [ -z "$CIRCLE_ID" ]; then
    case "$(jqr '.code // empty')" in
      SB404) die "no circle has that code — check the code on your phone" ;;
      SB409) die "the circle is full (8 members total)" ;;
      *) die "join_circle failed (HTTP $CODE): $(jqr '.message // .msg // "unknown"')" ;;
    esac
  fi
  save_state

  echo "✓ '$BUDDY_NAME' joined the circle"
  echo
  echo "Check your phone — the Circle tab should now show a second member."
  echo "Then give them something to do:"
  echo "    $0 post fajr onTime"
}

cmd_post() {
  local prayer="${1:-}" tier="${2:-}" jamaat="${3:-}"
  [ -n "$prayer" ] && [ -n "$tier" ] || die "usage: $0 post <prayer> <tier> [jamaat]"
  case "$prayer" in fajr|dhuhr|asr|maghrib|isha) ;; *) die "unknown prayer '$prayer'" ;; esac
  local xp; xp="$(tier_xp "$tier")"
  local jflag=false
  if [ "$jamaat" = "jamaat" ]; then jflag=true; [ "$xp" -lt 30 ] && xp=30; fi

  load_state; refresh_jwt
  # LOCAL date on purpose: dayKey is the local SCHEDULE day a window belongs
  # to (CLAUDE.md), so a UTC date would file the post under the wrong day for
  # anyone west of Greenwich — which is to say, here.
  local day post_id now
  day="$(date +%F)"; post_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"; now="$(date -u +%FT%TZ)"

  api POST "/rest/v1/posts" "$JWT" "$(jq -nc \
    --arg id "$post_id" --arg u "$BUDDY_ID" --arg c "$CIRCLE_ID" \
    --arg d "$day" --arg p "$prayer" --arg t "$tier" --arg l "$now" \
    --argjson j "$jflag" \
    '{id:$id,user_id:$u,circle_id:$c,day_key:$d,prayer:$p,tier:$t,logged_at:$l,jamaat:$j}')"

  if [ "$CODE" = "201" ] || [ "$CODE" = "200" ]; then
    echo "✓ $BUDDY_NAME logged $prayer ($tier$([ "$jflag" = true ] && echo ", jamaat")) — worth ${xp} XP"
    echo
    echo "On your phone: their square for $prayer should fill in WITHOUT a manual refresh"
    echo "(that is realtime working), and the weekly total should move by ${xp}."
  elif printf '%s' "$RESP" | grep -q '23505'; then
    die "$BUDDY_NAME already logged $prayer today — posts are unique per (user, circle, day, prayer)"
  else
    die "post failed (HTTP $CODE): $(jqr '.message // .msg // "unknown"')"
  fi
}

cmd_rest() {
  load_state; refresh_jwt
  api POST "/rest/v1/excused_days" "$JWT" "$(jq -nc \
    --arg u "$BUDDY_ID" --arg c "$CIRCLE_ID" --arg d "$(date +%F)" \
    '{user_id:$u,circle_id:$c,day_key:$d}')" "return=minimal"
  [ "$CODE" = "201" ] || [ "$CODE" = "200" ] \
    || die "excused_days insert failed (HTTP $CODE): $(jqr '.message // "unknown"')"
  echo "✓ $BUDDY_NAME marked today as a rest day"
  echo "  Your phone should show them resting — and NO reason, because there is"
  echo "  no column one could travel in (SPEC-V4 §3)."
}

cmd_status() {
  load_state; refresh_jwt
  echo "buddy   : $BUDDY_NAME  ($BUDDY_EMAIL)"
  echo "circle  : $CIRCLE_ID"
  api GET "/rest/v1/circle_members?select=user_id" "$JWT"
  echo "members : $(printf '%s' "$RESP" | jq 'length' 2>/dev/null || echo '?') (including you)"
  echo
  api GET "/rest/v1/posts?select=day_key,prayer,tier,jamaat&user_id=eq.$BUDDY_ID&order=day_key.desc" "$JWT"
  local total=0
  echo "posts by this buddy:"
  while IFS=$'\t' read -r d p t j; do
    [ -n "${d:-}" ] || continue
    local xp; xp="$(tier_xp "$t")"
    [ "$j" = "true" ] && [ "$xp" -lt 30 ] && xp=30
    total=$((total + xp))
    printf '  %s  %-8s %-10s %s%3d XP\n' "$d" "$p" "$t" "$([ "$j" = true ] && echo 'jamaat ' || echo '       ')" "$xp"
  done < <(printf '%s' "$RESP" | jq -r '.[] | [.day_key,.prayer,.tier,.jamaat] | @tsv' 2>/dev/null)
  echo
  echo "  EXPECTED TOTAL: ${total} XP"
  echo
  echo "This is the Phase C check: your phone's leaderboard must show ${total} for"
  echo "this buddy. It is computed here from the same tier table GameEngine uses,"
  echo "so a disagreement means the two devices are scoring identical rows"
  echo "differently — which is the failure the criterion exists to catch."
}

cmd_cleanup() {
  load_state; refresh_jwt
  api POST "/rest/v1/rpc/delete_account" "$JWT" '{}'
  if [ "$CODE" = "200" ] || [ "$CODE" = "204" ]; then
    rm -f "$STATE"
    echo "✓ purged $BUDDY_NAME's rows and forgot the account"
    echo "  (the auth.users row itself needs service_role — see V4-PUNCHLIST.md §6)"
  else
    die "delete_account failed (HTTP $CODE): $(jqr '.message // "unknown"')"
  fi
}

case "${1:-}" in
  join)    shift; cmd_join "$@" ;;
  post)    shift; cmd_post "$@" ;;
  rest)    shift; cmd_rest ;;
  status)  shift; cmd_status ;;
  cleanup) shift; cmd_cleanup ;;
  *)
    sed -n '27,35p' "$0" | sed 's/^# \{0,1\}//'
    exit 1 ;;
esac
