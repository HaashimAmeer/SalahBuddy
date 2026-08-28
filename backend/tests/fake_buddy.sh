#!/usr/bin/env bash
# A real second member of a circle, driven from a terminal.
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
# WHOSE CIRCLE — READ THIS ONCE
# -----------------------------
# `new` is where you start, and it gives the buddy a circle of ITS OWN, then
# prints the invite code for your phone to join. Everything else — post, rest,
# status — works exactly the same in there, and nothing of yours is in it.
#
# The cost of `new` is not on this side of the wire, and you must know it before
# you run it: a person is in ONE circle at a time (join_circle raises SB410), so
# YOUR PHONE HAS TO LEAVE YOUR REAL CIRCLE before it can join the buddy's.
# WRITE YOUR OWN INVITE CODE DOWN FIRST. The moment you are out, `circles_select`
# stops matching that row, the app clears it from the mirror, and neither the app
# nor the server will ever show you that code again — and circles have no DELETE
# policy, so if you were its only member it just sits there, unreachable, with
# you outside it. Copy the code off the Circle tab, THEN leave.
#
# `join` is the other direction: it drops a throwaway account into YOUR real
# circle, next to real people, and it is the only command here that does. It
# costs your phone nothing — you stay where you are — and it is the shortest
# path to the Phase C check against a circle that already has your history in
# it. What it costs instead is that "Test Buddy" turns up on the roster next to
# real people, which is how we learned to write this paragraph. So: it asks
# first, it refuses to abandon a buddy that is still checked out (the state file
# is the ONLY copy of its password — overwrite that and the account is marooned
# in your circle for good), and `leave` walks it back out without destroying it.
#
# Neither one is the free one. `new` keeps your circle untouched and asks your
# phone to step out of it; `join` leaves your phone where it is and puts a
# stranger on your roster until you take them off. Pick by which of the two you
# can afford for the thing you are actually testing.
#
# USAGE
#   ./backend/tests/fake_buddy.sh new  [display-name]    # a circle of its own — start here
#        (to join it, your phone must leave YOUR circle — save your code first)
#   ./backend/tests/fake_buddy.sh join <INVITE_CODE> [display-name]   # YOUR circle; asks first
#   ./backend/tests/fake_buddy.sh post <prayer> <tier> [jamaat]
#   ./backend/tests/fake_buddy.sh rest
#   ./backend/tests/fake_buddy.sh status
#   ./backend/tests/fake_buddy.sh leave      # out of the circle, account kept
#   ./backend/tests/fake_buddy.sh cleanup    # purge its rows and forget the account
#   ./backend/tests/fake_buddy.sh forget     # drop the local file only (escape hatch)
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

# create_circle / join_circle return a `circles` composite, which PostgREST
# renders as an object here and as a one-element array elsewhere depending on
# the Accept header it settles on. Read both rather than betting on one.
row() { jqr "if type==\"array\" then .[0] else . end | .$1 // empty"; }

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

# Single-quote a value for the state file, escaping the one character that can
# turn data back into code: a display name like "Sam's phone" would otherwise
# close the quote and run the rest of the line when load_state sources it.
#
# The replacement — quote, backslash, quote, quote — lives in a variable rather
# than inline because bash 3.2 (the /bin/bash every Mac ships) processes
# backslashes in a literal replacement differently from bash 5 and quietly
# produces a file that will not parse. From a variable both agree.
q() {
  local esc="'\\''"
  printf "'%s'" "${1//\'/$esc}"
}

save_state() {
  umask 077   # the file holds a session token
  cat > "$STATE" <<EOF
BUDDY_EMAIL=$(q "${BUDDY_EMAIL:-}")
BUDDY_PASSWORD=$(q "${BUDDY_PASSWORD:-}")
BUDDY_ID=$(q "${BUDDY_ID:-}")
BUDDY_NAME=$(q "${BUDDY_NAME:-}")
CIRCLE_ID=$(q "${CIRCLE_ID:-}")
CIRCLE_CODE=$(q "${CIRCLE_CODE:-}")
CIRCLE_OWNED=$(q "${CIRCLE_OWNED:-}")
JWT=$(q "${JWT:-}")
EOF
}

# One message for every way the state file can be unusable, because from the
# operator's chair they are one situation: the account it described is now
# unreachable, and this file was the only copy of its password.
die_unusable_state() {
  die "the state file is unusable — it was written half-way, and the password it
     held is gone with it: $STATE
     '$0 forget' drops it and you start again with '$0 new'. If that buddy was
     in one of YOUR circles, remove them from the app first — nothing here can
     sign in as them any more."
}

load_state() {
  [ -f "$STATE" ] || die "no buddy yet — run: $0 new    (or, for YOUR circle: $0 join <INVITE_CODE>)"
  # Source it in a subshell FIRST, then for real. `save_state` truncates before
  # it writes, so an interrupt mid-write can cut the file in the middle of an
  # identifier — and a bare word is a COMMAND, not an assignment, so sourcing it
  # says "BUDDY_PASS: command not found" and exits 127 out of whatever the
  # operator actually typed. A cut inside a quote is worse: that is a SYNTAX
  # error, which on bash 3.2 kills the whole script however the source call is
  # wrapped. A subshell contains both, and re-running eight assignments to find
  # out costs nothing.
  # shellcheck disable=SC1090
  ( . "$STATE" ) >/dev/null 2>&1 || die_unusable_state
  # shellcheck disable=SC1090
  . "$STATE"
  # Tolerant of a file an older copy of this script wrote, for the same reason
  # the app's decoders are tolerant of an older save: a field that did not
  # exist yet takes a default instead of exploding under `set -u`. CIRCLE_OWNED
  # missing therefore reads as "joined", which is the cautious half.
  CIRCLE_ID="${CIRCLE_ID:-}"; CIRCLE_CODE="${CIRCLE_CODE:-}"; CIRCLE_OWNED="${CIRCLE_OWNED:-}"
  BUDDY_NAME="${BUDDY_NAME:-the buddy}"
  # Tolerant of an OLD file is not the same as tolerant of a BROKEN one, and a
  # truncation that happens to land on a line boundary — or a zero-byte file —
  # sources perfectly cleanly and then dies on the first reference instead:
  # `refresh_jwt: BUDDY_EMAIL: unbound variable`, a raw bash trace, out of every
  # command including `leave` and `cleanup`, the two that undo things. Catch it
  # here. (`forget` deliberately does not come through load_state, so it stays
  # runnable when this refuses.)
  [ -n "${BUDDY_EMAIL:-}" ] && [ -n "${BUDDY_PASSWORD:-}" ] && [ -n "${BUDDY_ID:-}" ] \
    || die_unusable_state
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

require_circle() {
  [ -n "$CIRCLE_ID" ] || die "'$BUDDY_NAME' is not in a circle right now.
     '$0 new' gives them one of their own; '$0 join <CODE>' puts them in yours."
}

# Signs up a fresh throwaway account, or reuses the one already on disk if it
# is between circles. Reuse matters: delete_account() cannot remove the
# auth.users row (§6, needs service_role), so every extra signup is a permanent
# resident of the staging project. Refuses outright while a buddy is still IN a
# circle — that is the case where overwriting the file strands a real member in
# a real circle with no password left to remove it.
ensure_buddy() { # display-name
  if [ -f "$STATE" ]; then
    load_state
    [ -z "$CIRCLE_ID" ] || die "'$BUDDY_NAME' is still in a circle ($CIRCLE_ID).
     Take them out of it first — '$0 leave' keeps the account, '$0 cleanup'
     purges their rows and forgets it. If the account is already gone,
     '$0 forget' drops the local file."
    refresh_jwt
    echo "note: reusing '$BUDDY_NAME', who left their last circle (their name stays as it is)"
    return 0
  fi

  BUDDY_EMAIL="salahbuddy-buddy-$(date +%s)@${EMAIL_DOMAIN}"
  BUDDY_PASSWORD="$(openssl rand -base64 21)"
  BUDDY_NAME="${1:-Test Buddy}"
  CIRCLE_ID=""; CIRCLE_CODE=""; CIRCLE_OWNED=""; JWT=""

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
}

cmd_new() {
  ensure_buddy "${1:-Test Buddy}"

  api POST "/rest/v1/rpc/create_circle" "$JWT" \
    "$(jq -nc --arg n "$BUDDY_NAME's test circle" '{p_name:$n,p_emoji:"🧪"}')"
  CIRCLE_ID="$(row id)"; CIRCLE_CODE="$(row code)"
  [ -n "$CIRCLE_ID" ] \
    || die "create_circle failed (HTTP $CODE): $(jqr '.message // .msg // "unknown"')"
  CIRCLE_OWNED=true
  save_state

  echo "✓ '$BUDDY_NAME' is sitting in a circle of their own"
  echo
  echo "    invite code:  $CIRCLE_CODE     ('$0 status' prints it again)"
  echo
  echo "STOP before you join it from your phone. A person is in ONE circle at a"
  echo "time, so your phone has to leave YOUR circle first — and once it is out,"
  echo "neither the app nor the server will show you your own code again (RLS"
  echo "hides the row from non-members, and circles cannot be deleted). In order:"
  echo
  echo "    1. Circle tab > invite > copy YOUR code and put it somewhere safe."
  echo "    2. Circle tab > gear > Leave this circle."
  echo "    3. Circle tab > join with a code > $CIRCLE_CODE"
  echo
  echo "That gives you two real members and two devices' worth of rows, with none"
  echo "of it anywhere near your own circle. When you are done, leave from the app"
  echo "and re-join your own with the code from step 1 — which is why you saved it."
  echo
  echo "If stepping your phone out of your circle is not a trade you want, this is"
  echo "the wrong command: '$0 join <YOUR CODE>' brings the buddy to you instead."
  echo
  echo "Then give them something to do:"
  echo "    $0 post fajr onTime"
}

# The one command that reaches into a circle with real people in it.
confirm_join() { # invite-code display-name
  local invite="$1" name="$2" typed=""
  if [ "${FAKE_BUDDY_ASSUME_YES:-}" = "1" ]; then
    echo "note: FAKE_BUDDY_ASSUME_YES=1 — joining $invite without asking"
    return 0
  fi
  # No terminal means nobody is reading the warning, and a `read` on a closed
  # stdin would sail straight through as an empty (i.e. non-matching) answer.
  [ -t 0 ] || die "join needs a terminal to confirm on — set FAKE_BUDDY_ASSUME_YES=1 if you really mean it"

  echo "This puts a REAL throwaway account, shown to everyone there as '$name',"
  echo "into the circle behind code $invite. That is your circle, not a sandbox:"
  echo "they will appear on the roster, on the leaderboard and in the week grid"
  echo "until you run '$0 leave' or '$0 cleanup'."
  echo
  echo "If you only need a second member to test against, '$0 new' makes them a"
  echo "circle of their own and touches nothing of yours."
  echo
  printf 'Type the code again to go ahead, anything else to stop: '
  read -r typed
  typed="$(printf '%s' "$typed" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')"
  [ "$typed" = "$invite" ] \
    || die "that did not match — no account was created and no circle was joined"
}

cmd_join() {
  local invite="${1:-}" name="${2:-Test Buddy}"
  [ -n "$invite" ] || die "usage: $0 join <INVITE_CODE> [display-name]
     No code means no circle to join. For a buddy in a circle of their own
     (the usual thing you want), run: $0 new"
  # join_circle() upper-cases before it looks anything up, so do the same here
  # rather than rejecting a lower-case code that would have worked.
  invite="$(printf '%s' "$invite" | tr '[:lower:]' '[:upper:]')"
  # The app shows the code in this alphabet; catching a typo here beats a
  # confusing SB404 from the server.
  printf '%s' "$invite" | grep -Eq '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$' \
    || die "'$invite' is not a 6-char invite code (no I, O, 0 or 1 in the alphabet)"

  # Order matters: shape, then the state check, then the confirmation, and only
  # then a signup. Every way of saying no must leave nothing behind.
  local prior="" prior_circle="" prior_code="" reentry=false
  if [ -f "$STATE" ]; then
    # Read it in a subshell: load_state refuses a half-written file, and this
    # command has to be able to answer for itself rather than inherit that exit
    # before it has said anything. Neither field can contain a space — a uuid
    # and six characters from a fixed alphabet — so one line carries both.
    prior="$( load_state >/dev/null 2>&1; printf '%s %s' "$CIRCLE_ID" "$CIRCLE_CODE" )" || prior=""
    # The printf always emits at least the separating space, so an empty result
    # here can only mean load_state refused the file. Say so NOW rather than
    # after walking someone through a confirmation that was never going to run.
    [ -n "$prior" ] || die_unusable_state
    prior_circle="${prior%% *}"; prior_code="${prior#* }"
    [ -z "$prior_circle" ] \
      || die "there is already a buddy in a circle. '$0 leave' takes them out,
     '$0 cleanup' purges them; then join again."
  fi

  # A code that outlives a `leave` can only be a circle of the buddy's OWN —
  # that is the single case cmd_leave keeps one for. Walking them back into it
  # is not the surprise the confirmation exists to prevent, so it does not ask,
  # and it does not claim afterwards that this circle is yours.
  if [ -n "$prior_code" ] && [ "$prior_code" = "$invite" ]; then
    reentry=true
    echo "note: $invite is the circle this buddy already had — going straight back in"
  else
    confirm_join "$invite" "$name"
  fi

  ensure_buddy "$name"

  api POST "/rest/v1/rpc/join_circle" "$JWT" "$(jq -nc --arg c "$invite" '{p_code:$c}')"
  CIRCLE_ID="$(row id)"
  if [ -z "$CIRCLE_ID" ]; then
    case "$(jqr '.code // empty')" in
      SB404) die "no circle has that code — check the code on your phone" ;;
      SB409) die "the circle is full (12 members total)" ;;
      SB410) die "this buddy is already in a circle — '$0 leave' first" ;;
      *) die "join_circle failed (HTTP $CODE): $(jqr '.message // .msg // "unknown"')" ;;
    esac
  fi
  CIRCLE_CODE="$invite"; CIRCLE_OWNED="$reentry"
  save_state

  if [ "$reentry" = true ]; then
    echo "✓ '$BUDDY_NAME' is back in their own circle ($CIRCLE_CODE)"
    echo
    echo "Nothing of yours is in it. Give them something to do:"
    echo "    $0 post fajr onTime"
    return 0
  fi

  echo "✓ '$BUDDY_NAME' joined YOUR circle"
  echo
  echo "Check your phone — the Circle tab should now show a second member."
  echo "Then give them something to do:"
  echo "    $0 post fajr onTime"
  echo
  echo "When you are done — before any demo — take them back out:"
  echo "    $0 leave      # off the roster, account kept for next time"
  echo "    $0 cleanup    # that, plus delete every row they wrote"
}

cmd_post() {
  local prayer="${1:-}" tier="${2:-}" jamaat="${3:-}"
  [ -n "$prayer" ] && [ -n "$tier" ] || die "usage: $0 post <prayer> <tier> [jamaat]"
  case "$prayer" in fajr|dhuhr|asr|maghrib|isha) ;; *) die "unknown prayer '$prayer'" ;; esac
  local xp; xp="$(tier_xp "$tier")"
  local jflag=false
  if [ "$jamaat" = "jamaat" ]; then jflag=true; [ "$xp" -lt 30 ] && xp=30; fi

  load_state; require_circle; refresh_jwt
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
  load_state; require_circle; refresh_jwt
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
  if [ -z "$CIRCLE_ID" ] && [ -n "$CIRCLE_CODE" ]; then
    # A code with no circle id means cmd_leave kept it, which it only does for
    # one of their own — so this is the copy of record for a circle no server
    # will hand back.
    echo "circle  : none — they left their own, which is still there:"
    echo "          '$0 join $CIRCLE_CODE' re-enters it, '$0 new' makes a fresh one."
  elif [ -z "$CIRCLE_ID" ]; then
    echo "circle  : none — they left. '$0 new' or '$0 join <CODE>' puts them back in one."
  elif [ "$CIRCLE_OWNED" = "true" ]; then
    echo "circle  : $CIRCLE_ID"
    echo "          their own (code $CIRCLE_CODE) — nothing of yours is in it"
  else
    echo "circle  : $CIRCLE_ID"
    echo "          ! YOURS, joined with a code. Run '$0 leave' before a demo."
  fi
  if [ -n "$CIRCLE_ID" ]; then
    api GET "/rest/v1/circle_members?select=user_id" "$JWT"
    echo "members : $(printf '%s' "$RESP" | jq 'length' 2>/dev/null || echo '?') (including you)"
  fi
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

# The undo for both `join` and `new`. Deliberately NOT delete_account: the
# account survives, so a buddy you pulled out of a circle mid-demo can walk
# straight back in afterwards without minting another permanent auth.users row.
cmd_leave() {
  load_state
  [ -n "$CIRCLE_ID" ] || die "'$BUDDY_NAME' is not in a circle — nothing to leave"
  refresh_jwt
  api POST "/rest/v1/rpc/leave_circle" "$JWT" '{}' "return=minimal"
  case "$CODE" in
    200|204) ;;
    *) die "leave_circle failed (HTTP $CODE): $(jqr '.message // .msg // "unknown"')" ;;
  esac
  local was_owned="$CIRCLE_OWNED"
  CIRCLE_ID=""; CIRCLE_OWNED=""
  # Keep the code for a circle of their OWN, and only for that one. The moment
  # they are out, `circles_select` stops matching the row for everybody and
  # there is no DELETE policy either — so that circle is now reachable by code
  # alone, and this file is the only place the code still exists. Remembering it
  # is what makes "you can join again later" true rather than a nice sentence
  # over a lost circle. YOUR code is not kept: your phone is still in your
  # circle and can still read it off the Circle tab.
  [ "$was_owned" = "true" ] || CIRCLE_CODE=""
  save_state

  echo "✓ $BUDDY_NAME left the circle — the account is kept"
  if [ "$was_owned" = "true" ]; then
    echo "  and so is the code, so they can walk back into the SAME circle:"
    echo "      $0 join $CIRCLE_CODE"
    echo "  Nothing else can give you that code back — once they are out, the row"
    echo "  is hidden from everyone, and circles cannot be deleted."
  else
    echo "  so '$0 join <CODE>' can put them back in later."
  fi
  echo
  echo "  Their roster row is gone. Their POSTS are not: leaving only starts the"
  echo "  purge clock, so anyone still in that circle — your phone included, if it"
  echo "  joined — keeps seeing that week until retention sweeps it (SPEC-V4 §2)."
  echo "  If you need the board clean NOW — a demo in ten minutes — '$0 cleanup'"
  echo "  deletes the rows outright."
}

cmd_cleanup() {
  load_state; refresh_jwt
  # "A circle of their own is out there" is true both while they are sitting in
  # it and after a `leave` that kept its code — delete_account leaves the row
  # standing either way, so the paragraph below applies to both.
  local own_code=""
  if [ "$CIRCLE_OWNED" = "true" ] || { [ -z "$CIRCLE_ID" ] && [ -n "$CIRCLE_CODE" ]; }; then
    own_code="$CIRCLE_CODE"
  fi
  api POST "/rest/v1/rpc/delete_account" "$JWT" '{}'
  if [ "$CODE" = "200" ] || [ "$CODE" = "204" ]; then
    rm -f "$STATE"
    echo "✓ purged $BUDDY_NAME's rows — posts, photos, membership — and forgot the account"
    echo "  (the auth.users row itself needs service_role — see V4-PUNCHLIST.md §6)"
    if [ -n "$own_code" ]; then
      echo "  Their own circle ($own_code) stays behind: there is no DELETE policy"
      echo "  on circles, by design, and delete_account() only removes THEIR rows."
      echo "  So if you took your phone in there the way '$0 new' describes, your"
      echo "  phone is STILL a member of it and still holds that code — leave from"
      echo "  the app (Circle tab > gear), then re-join your own circle with the"
      echo "  code you saved before you left it. If nothing else ever joined, the"
      echo "  row sits there empty and unreachable, which is the intended end."
    fi
  else
    die "delete_account failed (HTTP $CODE): $(jqr '.message // "unknown"')"
  fi
}

# For when the account is unreachable — the project was reset, the password was
# lost with an old state file — and `cleanup` therefore cannot run. It only
# forgets; anything still in a circle stays there, which is why it says so.
cmd_forget() {
  [ -f "$STATE" ] || die "there is no buddy to forget"
  # Deliberately NOT load_state. This is the one command whose whole job is a
  # file nothing else can read, so it must never be the command that refuses
  # because the file cannot be read. Source it in a subshell, where even a
  # syntax error only kills the subshell (bash 3.2 exits the whole script on
  # one, `|| true` or not), and use whatever survived.
  #
  # The id comes FIRST on the line and the name last, because command
  # substitution eats trailing newlines: a name-then-id order collapses to one
  # field when the buddy is between circles, and the name would then be read as
  # a circle id — this command would refuse to run over a display name. A uuid
  # holds no space, a display name may, so one space splits them unambiguously.
  local prior="" name="" circle="" readable=true
  # shellcheck disable=SC1090
  prior="$( . "$STATE" >/dev/null 2>&1; printf '%s %s' "${CIRCLE_ID:-}" "${BUDDY_NAME:-}" )" || prior=""
  circle="${prior%% *}"; name="${prior#* }"
  if [ -z "$name" ]; then
    # save_state always writes a name, so an empty one means nothing came back
    # at all and the membership check below is answering from no evidence.
    readable=false; name="that buddy"
    echo "! nothing could be read out of that file — it does not parse."
    echo "  Whether it still holds a member of one of your circles is therefore"
    echo "  unknowable from here. Check the roster on your phone afterwards; a"
    echo "  stray member can only leave by themselves, and the only copy of their"
    echo "  password is the file you are about to delete."
  fi
  BUDDY_NAME="$name"; CIRCLE_ID="$circle"
  local prompt=""
  if [ -n "$CIRCLE_ID" ]; then
    echo "! '$BUDDY_NAME' is still a member of circle $CIRCLE_ID."
    echo "  Forgetting them here does NOT remove them from it, and this file is the"
    echo "  only copy of their password. Prefer '$0 leave' or '$0 cleanup'."
    if [ -t 0 ]; then
      prompt="Type 'forget' to drop the file anyway: "
    else
      die "refusing to strand a member non-interactively — run this from a terminal"
    fi
  elif [ "$readable" = false ] && [ -t 0 ]; then
    # An unparseable file may or may not be stranding somebody, and nothing here
    # can tell. Ask while there is anybody to ask — but do not refuse outright
    # the way a KNOWN member does: this file is the one `forget` exists for, and
    # a hard no would leave `rm` as the only way out of it.
    prompt="Type 'forget' to drop it anyway: "
  fi
  if [ -n "$prompt" ]; then
    local typed=""
    printf '%s' "$prompt"
    read -r typed
    [ "$typed" = "forget" ] || die "stopped — nothing was changed"
  fi
  rm -f "$STATE"
  echo "✓ forgot $BUDDY_NAME (local file only)"
}

# The usage text is the header comment, read by marker rather than by line
# number so editing anything above cannot silently make this print the wrong
# paragraph.
usage() { awk 'p && !/^#/ {exit} /^# USAGE/ {p=1} p {sub(/^# ?/, ""); print}' "$0"; }

case "${1:-}" in
  new)     shift; cmd_new "$@" ;;
  join)    shift; cmd_join "$@" ;;
  post)    shift; cmd_post "$@" ;;
  rest)    shift; cmd_rest ;;
  status)  shift; cmd_status ;;
  leave)   shift; cmd_leave ;;
  cleanup) shift; cmd_cleanup ;;
  forget)  shift; cmd_forget ;;
  *)
    usage
    exit 1 ;;
esac
