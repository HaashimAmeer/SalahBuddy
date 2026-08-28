#!/usr/bin/env bash
# The human end of the reports mailbox.
#
# WHY THIS EXISTS
# ---------------
# `public.reports` has been a write-only void since Phase D. A member can file a
# complaint about a buddy's photo; the reporter cannot read it back, `anon` and
# `authenticated` hold no SELECT at all, and until now nothing in this repo
# could read it either. App Store guideline 1.2 does not ask for a table — it
# asks for a HUMAN who can look at flagged content and act on it before the app
# is public. That human is you, and this is the desk.
#
# It is deliberately a shell script and not a dashboard. The only credential
# that can read this table bypasses RLS entirely, so the fewer places it has to
# live, the better: one env var, one terminal, one session, gone when you close
# it. A web console would mean storing it somewhere.
#
# WHAT IT SHOWS, AND WHAT IT WILL NOT
# -----------------------------------
# It shows the SUBJECT of a report — who was reported, where their photo is,
# when it was flagged, and what the reporter wrote. It never asks the server for
# `reporter_id` and there is no flag that makes it. Triage is a decision about
# CONTENT, not about who complained, and a circle is twelve people who know each
# other: "three of your friends flagged this" is exactly the sentence the
# write-only grant exists to make unsayable. The reporter is "a member", here
# and in every future version of this file.
#
# WHAT `remove` ACTUALLY DOES
# ---------------------------
# Nothing new. It walks the SAME path retention walks, for one photo:
#
#   1. clear `posts.photo_path` — the `posts_tombstone_photo` trigger records
#      the path in `photo_tombstones`, and the storage read policy consults that
#      list (`photo_is_pending_deletion`), so the object stops being readable by
#      the circle the instant this statement commits. This is the step that
#      matters; everything after it is housekeeping.
#   2. delete the object from Storage.
#   3. `confirm_photo_deletions()` — and ONLY if step 2 succeeded. That is the
#      whole point of the tombstone table: a path we could not delete stays on
#      the list and the nightly sweep retries it, instead of being forgotten
#      while the JPEG sits in the bucket with nothing left that can name it.
#
# It does not delete the post row. `delete_account()` deletes rows because the
# account is going; a moderated photo is one picture, and the prayer it records
# is still a fact the member's circle scored. Retention's job 1 does exactly
# this — `update posts set photo_path = null` — and this is that, for one row,
# on a human's say-so instead of a clock's.
#
# THE CREDENTIAL
# --------------
# `SUPABASE_SERVICE_ROLE_KEY`, from the environment, and nowhere else. There is
# no flag for it, no config file, no prompt, and it is never printed — not in an
# error, not in a URL, not in a curl argument list (the headers go in through
# `curl -K -`, so the key never appears in `ps`). The script refuses to start
# without it. It is the most powerful key in the project: it reads every table,
# bypasses every policy, and can delete anything.
#
# USAGE
#   export SUPABASE_SERVICE_ROLE_KEY=...   # Project Settings > API Keys > service_role
#
#   ./backend/scripts/triage_reports.sh list              # everything still open
#   ./backend/scripts/triage_reports.sh photo   <id>      # a 5-minute link to look at it
#   ./backend/scripts/triage_reports.sh remove  <id>      # take the photo down, mark handled
#   ./backend/scripts/triage_reports.sh dismiss <id>      # mark handled, remove nothing
#   ./backend/scripts/triage_reports.sh counts            # open=N / oldest_open_hours=N
#
#   <id> is a report id or any unambiguous prefix of one — `list` prints both.
#
# STAGING by default, and it acts on REAL rows and REAL objects. `remove` is
# one-way: the bytes are gone. It asks first.
set -euo pipefail

# Public config, identical to Sources/Core/Sync/SupabaseConfig.swift and to
# fake_buddy.sh. Only the URL — the key below comes from the environment, and
# the publishable key is no use here (it grants nothing on `reports`, by design).
URL="${SUPABASE_URL:-https://rmyygmyxppmnzcnvprvb.supabase.co}"
URL="${URL%/}"

BUCKET="prayer-photos"
# A triage queue this long is not a queue, it is an incident. The cap exists so
# a runaway table cannot turn `list` into a wall of scrollback.
LIST_LIMIT=200
# How long a signed photo link lives. Long enough to open it, short enough that
# a link left in scrollback is dead before it is a leak.
SIGN_SECONDS=300

# Never `reporter_id`. See the header — this list is the whole privacy story of
# the tool, so it is written once, here, and every query uses it. `circle_id` is
# absent for a smaller reason: it names nothing a triage decision turns on, and
# a uuid nobody needs is still a uuid in somebody's scrollback.
REPORT_FIELDS="id,created_at,post_id,reported_user_id,photo_path,reason,handled_at,handled_action"

command -v jq   >/dev/null || { echo "need jq: brew install jq" >&2; exit 1; }
command -v curl >/dev/null || { echo "need curl" >&2; exit 1; }

die() { echo "✗ $*" >&2; exit 1; }

KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
require_key() {
  [ -n "$KEY" ] || die "SUPABASE_SERVICE_ROLE_KEY is not set.

     Nothing here can read \`reports\` without it — that is the design, not a
     missing feature. Get it from the Supabase dashboard:
         Project Settings > API Keys > service_role (\"secret\")
     then, in this shell only:
         export SUPABASE_SERVICE_ROLE_KEY='...'

     Do not put it in a file this repo can see. The repo is public."
  # The one wrong key that looks plausible: the app ships a publishable key in
  # SupabaseConfig.swift, and pasting that here comes back as a bare 401 from
  # PostgREST — which reads like a broken deploy rather than the wrong
  # credential. Matched on its prefix, so nothing is ever compared against, or
  # printed as, the value itself.
  case "$KEY" in
    sb_publishable_*)
      die "that is the PUBLISHABLE key — it holds no privilege on \`reports\` at
     all (the RLS migration revokes anon outright). Use the service_role /
     secret key from Project Settings > API Keys." ;;
  esac
}

CODE=""; RESP=""
# The credential goes in through curl's config stream, not its argument list.
# `ps` on a shared machine shows every argument of every running process, and
# this is the one key in the project that would be worth reading off it.
#
# `Prefer` is per-call. `return=representation` needs SELECT on every column it
# echoes — service_role has it here, but `return=minimal` is still the right
# default for a write nobody reads back, and it keeps report bodies out of the
# terminal unless something asked for them.
api() { # method path [body] [prefer]
  local method="$1" path="$2" body="${3:-}" prefer="${4:-return=minimal}" out
  local -a args=(-sS -K- -X "$method" "$URL$path"
                 -H "Content-Type: application/json"
                 -H "Accept: application/json"
                 -H "Prefer: $prefer")
  [ -n "$body" ] && args+=(--data "$body")
  out="$(printf 'header = "apikey: %s"\nheader = "Authorization: Bearer %s"\n' "$KEY" "$KEY" \
         | curl "${args[@]}" -w $'\n%{http_code}' 2>&1)" || out="$out"$'\n000'
  CODE="${out##*$'\n'}"
  RESP="${out%$'\n'*}"
}

# Storage speaks its own API. `remove` is a DELETE on the bucket with the keys
# in the body — the shape supabase-js sends, and therefore the shape the
# retention function already uses.
storage() { # method path [body]
  local method="$1" path="$2" body="${3:-}" out
  local -a args=(-sS -K- -X "$method" "$URL/storage/v1$path"
                 -H "Content-Type: application/json"
                 -H "Accept: application/json")
  [ -n "$body" ] && args+=(--data "$body")
  out="$(printf 'header = "apikey: %s"\nheader = "Authorization: Bearer %s"\n' "$KEY" "$KEY" \
         | curl "${args[@]}" -w $'\n%{http_code}' 2>&1)" || out="$out"$'\n000'
  CODE="${out##*$'\n'}"
  RESP="${out%$'\n'*}"
}

jqr() { printf '%s' "$RESP" | jq -r "$1" 2>/dev/null || printf ''; }

# One reading for every way the door can be shut, because from the operator's
# chair a 401 and a 404 are the same sentence: this key cannot see the table.
check() { # what-we-were-doing  expected-code...
  local what="$1"; shift
  local ok
  for ok in "$@"; do [ "$CODE" = "$ok" ] && return 0; done
  case "$CODE" in
    401|403) die "$what: the project refused this key (HTTP $CODE).
     \`reports\` is readable by service_role and nothing else — check that
     SUPABASE_SERVICE_ROLE_KEY is the service_role / secret key from
     Project Settings > API Keys, verbatim." ;;
    404) die "$what: not found (HTTP 404). If this is the first run against a
     project, the triage migration may not be deployed yet — push a
     \`backend/**\` change to staging and let deploy-staging run." ;;
    000) die "$what: the request never completed. A paused free-tier project
     does this; unpause it in the dashboard and try again." ;;
    *) die "$what failed (HTTP $CODE): $(jqr '.message // .msg // .error // "unknown"')" ;;
  esac
}

# --- resolving a report ------------------------------------------------------
# Ids are uuids and nobody types a uuid, so any unambiguous prefix works. The
# match happens HERE and not in a filter, because PostgREST cannot pattern-match
# a uuid column — and the alternative (casting it to text in a view) would be a
# new readable surface on the one table that has none.
R_JSON=""
R_ID=""; R_CREATED=""; R_HAT=""; R_HACT=""
R_POST=""; R_USER=""; R_PATH=""; R_REASON=""

# One field at a time out of the matched row, and NOT a single delimited line
# read into eight variables. That shape was written first and was wrong in a way
# that only showed up on a report with an empty column: `IFS=$'\t' read` treats
# tab as IFS WHITESPACE, so a run of tabs collapses to one separator and every
# field after the first null slides left — a handled_at that happened to be null
# silently turned photo_path into the reason. Eight `jq` calls over a string
# already in memory cost nothing and cannot mis-align.
rf() { printf '%s' "$R_JSON" | jq -r --arg k "$1" '.[$k] // ""'; }

resolve() { # id-or-prefix
  local want n
  want="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  [ -n "$want" ] || die "which report? \`$0 list\` prints the open ones with their ids"

  api GET "/rest/v1/reports?select=$REPORT_FIELDS&order=created_at.asc&limit=500" "" "return=representation"
  check "reading reports" 200

  n="$(printf '%s' "$RESP" | jq --arg w "$want" '[.[] | select(.id | startswith($w))] | length')"
  case "$n" in
    0) die "no report id starts with '$want'. \`$0 list\` shows what is open." ;;
    1) ;;
    *) die "'$want' matches $n reports — type a few more characters." ;;
  esac

  R_JSON="$(printf '%s' "$RESP" | jq -c --arg w "$want" '[.[] | select(.id | startswith($w))][0]')"
  R_ID="$(rf id)";        R_CREATED="$(rf created_at)"
  R_HAT="$(rf handled_at)"; R_HACT="$(rf handled_action)"
  R_POST="$(rf post_id)"; R_USER="$(rf reported_user_id)"
  R_PATH="$(rf photo_path)"
  # The path is about to be spliced into a URL and into a PostgREST `eq.` filter.
  # It cannot hold anything awkward — the app writes `<circle>/<user>/<uuid>.jpg`
  # and `reports_insert` pins it to `posts.photo_path` — but "cannot" there is a
  # claim about a policy in another file, and this is the line that would build
  # the query string. Check rather than inherit the assumption.
  if [ -n "$R_PATH" ] && printf '%s' "$R_PATH" | LC_ALL=C grep -q '[^A-Za-z0-9./_-]'; then
    die "report $(printf '%.8s' "$R_ID") carries a photo path that is not the
     <circle>/<user>/<uuid>.jpg shape the app writes. Nothing here will put it
     in a URL — look at that row by hand before acting on it."
  fi
  # 500 characters a member typed, about to be printed in a confirmation the
  # operator is meant to read carefully. Flatten the control characters so it
  # cannot draw its own extra lines — same reasoning as `list`'s `plain`.
  R_REASON="$(rf reason | tr '\001-\037\177' ' ')"
}

# The display name of whoever was reported. A separate call because the foreign
# key points at `auth.users` and `profiles` hangs off that — PostgREST cannot
# embed across it, and inventing a view to make it possible would be a new way
# to read this table.
name_of() { # user-uuid
  local id="${1:-}" n=""
  [ -n "$id" ] || { printf '(nobody — the report was anonymised)'; return; }
  api GET "/rest/v1/profiles?select=name&id=eq.$id" "" "return=representation"
  [ "$CODE" = "200" ] && n="$(jqr '.[0].name // empty')"
  printf '%s' "${n:-(no name on file)}"
}

# --- commands ----------------------------------------------------------------

cmd_list() {
  require_key
  api GET "/rest/v1/reports?select=$REPORT_FIELDS&handled_at=is.null&order=created_at.asc&limit=$LIST_LIMIT" \
      "" "return=representation"
  check "reading reports" 200
  local reports="$RESP"

  local n; n="$(printf '%s' "$reports" | jq 'length')"
  if [ "$n" = "0" ]; then
    echo "✓ nothing open. (\`$0 counts\` is the same answer in two numbers.)"
    return 0
  fi

  # Two lookups, batched: the names of everyone reported, and which reported
  # posts are still live. "Still live" is the difference between a photo the
  # circle can see right now and one the author already withdrew.
  local ids paths posts names
  ids="$(printf '%s' "$reports" | jq -r '[.[].reported_user_id | select(. != null)] | unique | join(",")')"
  names='{}'
  if [ -n "$ids" ]; then
    api GET "/rest/v1/profiles?select=id,name&id=in.($ids)" "" "return=representation"
    [ "$CODE" = "200" ] && names="$(printf '%s' "$RESP" | jq 'map({key: .id, value: .name}) | from_entries')"
  fi

  paths="$(printf '%s' "$reports" | jq -r '[.[].post_id | select(. != null)] | unique | join(",")')"
  posts='{}'
  if [ -n "$paths" ]; then
    api GET "/rest/v1/posts?select=id,photo_path&id=in.($paths)" "" "return=representation"
    [ "$CODE" = "200" ] && posts="$(printf '%s' "$RESP" | jq 'map({key: .id, value: (.photo_path // "")}) | from_entries')"
  fi

  echo "$n open report(s), oldest first:"
  echo
  printf '%s' "$reports" | jq -r --argjson names "$names" --argjson posts "$posts" '
    # Tolerant on purpose: PostgREST renders timestamptz in the project timezone
    # and jq only parses the Z form, so a project configured off UTC loses the
    # "how old" line rather than the whole listing.
    def secs: try (sub("\\.[0-9]+";"") | sub("[+-]00:?00$";"Z") | fromdateiso8601) catch null;

    # `reason` is 500 characters a signed-in member wrote, and a display name is
    # the same kind of text. Both land in a terminal here, so both get their
    # control characters flattened first: a newline would let a reporter draw a
    # convincing fake "post  still live" line inside somebody else'"'"'s entry, and an
    # ESC would let them repaint the screen. Non-ASCII is left alone — names in
    # this app are Arabic and emoji as often as not.
    def plain: (. // "") | gsub("[\u0000-\u001f\u007f]"; " ");
    def ago: . as $t | (secs) as $e
      | if $e == null then "" else ((now - $e) / 3600 | floor) as $h
        | if $h < 1 then "under an hour old"
          elif $h < 48 then "\($h)h old"
          else "\($h / 24 | floor)d old" end
        end;

    # How many OPEN reports name the same picture. Derived from the photo (which
    # survives undo) and never from who filed them — the count is the signal, the
    # names are none of triage'"'"'s business.
    (group_by(.photo_path // .post_id // .id)
      | map({key: (.[0].photo_path // .[0].post_id // .[0].id), value: length})
      | from_entries) as $tally

    | .[]
    | (.photo_path // .post_id // .id) as $k
    | (.reported_user_id // "") as $who
    | "  \(.id[0:8])  \(.created_at | ago)",
      "    id      \(.id)",
      "    about   \($names[$who] | plain | if . == "" then "(no name on file)" else . end) · \(if $who == "" then "anonymised — the account was deleted" else $who end)",
      (if .photo_path == null then
         "    photo   none left — it aged out of Storage on the 30-day clock"
       else
         "    photo   \(.photo_path)"
       end),
      (if .post_id == null then
         "    post    gone (undone or swept) — the photo may still be in the bucket"
       elif ($posts[.post_id] // "") == "" then
         "    post    still live, but its photo is already cleared"
       elif $posts[.post_id] != .photo_path then
         "    post    still live, and its photo has been REPLACED since the report"
       else
         "    post    still live, photo attached — the circle can see it now"
       end),
      "    filed   by a member" + (if $tally[$k] > 1 then " (\($tally[$k]) open reports name this photo)" else "" end),
      (if (.reason // "") == "" then "    reason  (none given)" else "    reason  \(.reason | plain)" end),
      ""'

  cat <<EOF
Act on one — any unambiguous prefix of an id will do:

    $0 photo   <id>    a $((SIGN_SECONDS / 60))-minute link, so you can look before deciding
    $0 remove  <id>    clear the photo, delete the object, mark handled
    $0 dismiss <id>    mark handled, remove nothing
EOF
  [ "$n" -lt "$LIST_LIMIT" ] || echo "
! Stopped at $LIST_LIMIT. There are more — work through these and run \`list\` again."
}

cmd_photo() {
  require_key
  resolve "${1:-}"
  [ -n "$R_PATH" ] || die "report $(printf '%.8s' "$R_ID") has no photo path — it aged out of
     Storage on the 30-day retention clock, which is the evidence window by
     design. Decide on the reason text, or \`$0 dismiss\` it."

  storage POST "/object/sign/$BUCKET/$R_PATH" "$(jq -nc --argjson s "$SIGN_SECONDS" '{expiresIn:$s}')"
  if [ "$CODE" != "200" ]; then
    case "$CODE" in
      400|404) die "Storage has no object at that path any more — the sweep has
     already removed it, or the member replaced the photo. The report still
     stands on its own: \`$0 list\` shows what it says." ;;
      *) check "signing a photo link" 200 ;;
    esac
  fi

  local signed; signed="$(jqr '.signedURL // .signedUrl // empty')"
  [ -n "$signed" ] || die "Storage signed nothing back (HTTP $CODE)"
  # Storage answers with a path that has changed shape between client versions —
  # sometimes leading-slash, sometimes not. Normalise rather than bet.
  signed="${signed#/}"

  echo "A private link to the reported photo. It expires in $((SIGN_SECONDS / 60)) minutes."
  echo
  echo "    $URL/storage/v1/$signed"
  echo
  echo "  This is somebody's private photo and the link carries its own token —"
  echo "  open it, decide, and do not paste it anywhere. Then:"
  echo "      $0 remove  $(printf '%.8s' "$R_ID")"
  echo "      $0 dismiss $(printf '%.8s' "$R_ID")"
}

# Both actions are a decision recorded against a real person's content, so both
# ask. `remove` asks the harder way — typing the id back is the one gesture that
# cannot happen by holding down Return.
confirm() { # word-to-type  prompt-line...
  local want="$1"; shift
  local typed=""
  printf '%s\n' "$@"
  echo
  if [ "${TRIAGE_ASSUME_YES:-}" = "1" ]; then
    echo "note: TRIAGE_ASSUME_YES=1 — going ahead without asking"
    return 0
  fi
  [ -t 0 ] || die "this needs a terminal to confirm on — set TRIAGE_ASSUME_YES=1 if you
     really mean it, and know that nothing will ask twice"
  printf 'Type %s to go ahead, anything else to stop: ' "$want"
  read -r typed || typed=""   # Ctrl-D refuses out loud instead of tripping `set -e`
  typed="$(printf '%s' "$typed" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  [ "$typed" = "$want" ] || die "that did not match — nothing was changed"
}

# Marking handled is the LAST step of both actions and the only one that writes
# to `reports`. One field: `handled_at` is derived by the trigger from the
# server's clock, so the pair can never fall out of step and no laptop's idea of
# the time ever lands in the record.
mark_handled() { # report-uuid action
  api PATCH "/rest/v1/reports?id=eq.$1" "$(jq -nc --arg a "$2" '{handled_action:$a}')"
  check "marking the report handled" 200 204
}

already_handled() {
  [ -z "$R_HAT" ] && return 1
  echo "! report $(printf '%.8s' "$R_ID") was already handled — $R_HACT, at $R_HAT."
  echo "  Going ahead re-dates it only if the decision itself changes."
  echo
  return 0
}

cmd_remove() {
  require_key
  resolve "${1:-}"
  [ -n "$R_PATH" ] || die "report $(printf '%.8s' "$R_ID") names no photo — there is nothing to
     take down. \`$0 dismiss\` closes it."

  already_handled || true
  local who; who="$(name_of "$R_USER")"

  confirm "$(printf '%.8s' "$R_ID")" \
    "This deletes a real photo belonging to $who." \
    "" \
    "    report  $R_ID" \
    "    filed   $R_CREATED  by a member" \
    "    photo   $R_PATH" \
    "" \
    "  The circle stops being able to see it the moment the first statement" \
    "  commits, and the bytes go straight after. Neither step can be undone;" \
    "  there is no copy anywhere else. Their prayer for that day is kept —" \
    "  only the picture goes, exactly as the 30-day sweep would have taken it." \
    "" \
    "  If you have not looked at it yet: $0 photo $(printf '%.8s' "$R_ID")"

  # 1. Hide it. Clearing posts.photo_path fires posts_tombstone_photo, the path
  #    lands in photo_tombstones, and prayer_photos_select consults that list —
  #    so this single statement is what actually takes the photo away from the
  #    circle. Everything after it is about the bytes.
  local hidden=false
  if [ -n "$R_POST" ]; then
    api GET "/rest/v1/posts?select=photo_path&id=eq.$R_POST" "" "return=representation"
    check "reading the reported post" 200
    local current; current="$(jqr '.[0].photo_path // empty')"
    if [ -z "$(jqr '.[0] // empty')" ]; then
      echo "note: the post is already gone — the path was tombstoned when it went."
    elif [ "$current" = "$R_PATH" ]; then
      # Match the path as well as the id: a member who replaced their photo
      # between the report and now would otherwise have the NEW one deleted.
      api PATCH "/rest/v1/posts?id=eq.$R_POST&photo_path=eq.$R_PATH" '{"photo_path":null}'
      check "clearing the reported photo" 200 204
      hidden=true
      echo "✓ the photo is no longer readable by the circle"
    else
      echo "note: the post's photo has changed since the report — the reported"
      echo "      path was tombstoned then, and only that one is removed here."
    fi
  else
    echo "note: the post is gone (undone or swept); the path was tombstoned then."
  fi

  # 2. The bytes.
  storage DELETE "/object/$BUCKET" "$(jq -nc --arg p "$R_PATH" '{prefixes:[$p]}')"
  if [ "$CODE" = "200" ]; then
    # 3. ...and only now may the path leave the tombstone list. This ordering IS
    #    the retention contract: a confirm we have not earned strands the object.
    api POST "/rest/v1/rpc/confirm_photo_deletions" "$(jq -nc --arg p "$R_PATH" '{p_paths:[$p]}')"
    check "confirming the deletion" 200 204
    echo "✓ the object is deleted and the tombstone is cleared"
  elif [ "$CODE" = "400" ] || [ "$CODE" = "404" ]; then
    echo "note: Storage had no object at that path — already swept. Nothing to delete."
  else
    # Deliberately NOT fatal, and deliberately NOT confirmed: the path stays on
    # the tombstone list, which is exactly the state the nightly sweep resumes
    # from. The photo is already hidden either way.
    echo "! Storage refused the delete (HTTP $CODE). The path stays queued and the"
    echo "  nightly maintenance run will retry it. It is already hidden from the circle."
  fi

  mark_handled "$R_ID" "photo_removed"
  echo "✓ report $(printf '%.8s' "$R_ID") marked handled (photo_removed)"
  [ "$hidden" = true ] || echo "  (nothing needed clearing on the post itself)"
  echo
  echo "SPEC-V4 §4 makes leaving the circle the block mechanism, and there is no"
  echo "server-side block. If this member is the problem rather than one photo,"
  echo "that conversation happens outside this script."
}

cmd_dismiss() {
  require_key
  resolve "${1:-}"
  already_handled || true
  local who; who="$(name_of "$R_USER")"

  confirm "dismiss" \
    "Dismissing closes this report and removes nothing." \
    "" \
    "    report  $R_ID" \
    "    filed   $R_CREATED  by a member" \
    "    about   $who" \
    "    photo   ${R_PATH:-(already aged out of Storage)}" \
    "    reason  ${R_REASON:-(none given)}" \
    "" \
    "  The photo stays exactly where it is and the circle keeps seeing it." \
    "  Re-open it later with a \`handled_action\` of null if you change your mind."

  mark_handled "$R_ID" "dismissed"
  echo "✓ report $(printf '%.8s' "$R_ID") marked handled (dismissed)"
}

# Two numbers, and nothing else can come out of here: `open_report_stats()`
# returns (open_count, oldest_open_hours) and has no column that could carry a
# reason, a path or a name. That is what makes it safe for the nightly workflow
# on a PUBLIC repo to print — see maintenance.yml, which parses these two lines.
cmd_counts() {
  require_key
  api POST "/rest/v1/rpc/open_report_stats" '{}' "return=representation"
  check "counting open reports" 200
  local open hours
  open="$(jqr 'if type=="array" then .[0] else . end | .open_count // 0')"
  hours="$(jqr 'if type=="array" then .[0] else . end | .oldest_open_hours // 0')"
  # Empty rather than 0 would mean the RPC answered in a shape we do not know,
  # and a nightly job reading "" as "nothing open" is the silence this exists to
  # prevent.
  [ -n "$open" ] && [ -n "$hours" ] || die "open_report_stats() answered in an unexpected shape"
  echo "open=$open"
  echo "oldest_open_hours=$hours"
}

# The usage text is the header comment, read by marker rather than by line
# number so editing anything above cannot silently make this print the wrong
# paragraph. Same trick as fake_buddy.sh.
usage() { awk 'p && !/^#/ {exit} /^# USAGE/ {p=1} p {sub(/^# ?/, ""); print}' "$0"; }

case "${1:-}" in
  list)    shift; cmd_list ;;
  photo)   shift; cmd_photo "$@" ;;
  remove)  shift; cmd_remove "$@" ;;
  dismiss) shift; cmd_dismiss "$@" ;;
  counts)  shift; cmd_counts ;;
  *)
    usage
    exit 1 ;;
esac
