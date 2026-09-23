# shellcheck shell=bash
# shellcheck disable=SC2016 # jq programs use $ for their own variables
# ccseat usage: 5-hour and weekly usage per seat from the OAuth usage
# endpoint, cached per seat, and the logic that picks the freest seat.
#
# Cache: $CCSEAT_CACHE_DIR/usage-<seat>.json holds the last API answer (the
# status line also writes it from Claude Code's own rate limits);
# usage-<seat>.err holds why the last fetch failed. Files are private (600).

CCSEAT_USAGE_URL="https://api.anthropic.com/api/oauth/usage"
CCSEAT_USAGE_TTL=60

CCSEAT_JQ_USAGE='
def iso: (capture("^(?<b>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$") // null)
  | if . == null then null
    else ((.b + "Z") | fromdateiso8601)
      - (if (.z // "Z") == "Z" then 0
         else (if .z[0:1] == "-" then -1 else 1 end)
              * ((.z[1:3] | tonumber) * 3600 + (.z[-2:] | tonumber) * 60) end)
    end;
def ep: if type == "number" then (if . > 1e12 then . / 1000 else . end | floor)
  elif type == "string" then
    (if test("^[0-9]+(\\.[0-9]+)?$") then (tonumber | if . > 1e12 then . / 1000 else . end | floor)
     else (try iso catch null) end)
  else null end;
def pc: if type == "number" then (. + 0.5 | floor)
  elif type == "string" and test("^[0-9]+(\\.[0-9]+)?$") then (tonumber + 0.5 | floor)
  else null end;
def win: if type != "object" then {p: null, r: null}
  else ((.utilization // .used_percentage) | pc) as $p | (.resets_at | ep) as $r
    | if $p == null then {p: null, r: null}
      elif $r != null and $r <= $now then {p: 0, r: null}
      else {p: ([$p, 0] | max), r: $r} end end;
def valid: type == "object" and ((.five_hour | type) == "object" or (.seven_day | type) == "object");
def clean: tostring | gsub("[;|\t\n\r]"; " ");
# Weekly limits for one model ("Fable weekly 91%"): the limits list of the
# current API, or the older seven_day_opus and seven_day_sonnet windows.
# Only from an API answer less than 6 hours old.
def scoped: if (((.fetched_at // 0) | ep) // 0) < $now - 21600 then []
  else
    ([(.limits // []) | if type == "array" then .[] else empty end
      | select(type == "object" and ((.kind // "") | tostring | test("scoped")))
      | {n: ((.scope.model.display_name // .scope.model.name // .scope.display_name
              // (.scope | if type == "string" then . else null end) // "model") | clean),
         p: ((.percent // .utilization // .used_percentage) | pc),
         r: ((.resets_at // .reset_at // .resets) | ep)}]) as $l
    | if ($l | length) > 0 then $l
      else [[["Opus", .seven_day_opus], ["Sonnet", .seven_day_sonnet]][]
        | select((.[1] | type) == "object") | {n: .[0], p: (.[1].utilization | pc), r: (.[1].resets_at | ep)}]
      end
    | map(select(.p != null) | if .r != null and .r <= $now then .p = 0 | .r = null else . end
          | "\(.n)|\(.p)|\(.r // "-")")
  end | join(";");
($c[0] // null) as $cache
| (($g[0] // {}) | if type == "object" then .cachedUsageUtilization else null end) as $cc
| (if ($cache | valid) then {u: $cache, age: $age} else null end) as $A
| (if ($cc | type) == "object" and ($cc.utilization | valid) and (($cc.fetchedAtMs // 0) > 0)
   then {u: $cc.utilization, age: ([$now - ($cc.fetchedAtMs / 1000 | floor), 0] | max)}
   else null end) as $B
| (if $A != null and ($B == null or $A.age <= $B.age) then $A elif $B != null then $B else null end) as $S
| if $S == null then ["-", "-", "-", "-", "none", "-", ""]
  else ($S.u.five_hour | win) as $f | ($S.u.seven_day | win) as $w
    | [($f.p // "-"), ($f.r // "-"), ($w.p // "-"), ($w.r // "-"),
       (if $S.age <= $ttl then "live" else "cache" end), $S.age,
       (if $A != null then ($A.u | try scoped catch "") else "" end)]
  end
| map(tostring) | join("\t")'

ccseat_usage_cache_path() {
  printf '%s/usage-%s.json' "$CCSEAT_CACHE_DIR" "${1:-}"
}

ccseat__usage_err_path() {
  printf '%s/usage-%s.err' "$CCSEAT_CACHE_DIR" "${1:-}"
}

# Why the last fetch failed: nologin, expired, auth, offline, ratelimited,
# http, bad; nothing when it worked.
ccseat_usage_err() {
  local f r=""
  f=$(ccseat__usage_err_path "${1:-}")
  [ -f "$f" ] && IFS= read -r r < "$f"
  printf '%s' "$r"
}

ccseat__usage_set_err() {
  printf '%s\n' "$2" | ccseat_write_file "$(ccseat__usage_err_path "$1")" 2>/dev/null
}

# Fetches a seat's usage into its cache. Returns 0 when fresh data arrived.
ccseat_usage_fetch() {
  local name="$1" max="${2:-5}" dir resp code body lock
  dir=$(ccseat_seat_dir "$name") || return 1
  ccseat_mkdir_private "$CCSEAT_CACHE_DIR" || return 1
  if ! ccseat_token_load "$dir"; then
    CCSEAT_TOKEN=""
    ccseat__usage_set_err "$name" nologin
    return 1
  fi
  ccseat__now_init
  if [ "$CCSEAT_TOKEN_EXP" -gt 0 ] && [ "$CCSEAT_TOKEN_EXP" -le $(( CCSEAT_NOW * 1000 )) ]; then
    CCSEAT_TOKEN=""
    ccseat__usage_set_err "$name" expired
    return 1
  fi
  # One fetch per seat at a time; a lock older than a minute is stale.
  lock="$CCSEAT_CACHE_DIR/.fetch-$name.lock"
  if [ -d "$lock" ] && [ "$(ccseat_file_age "$lock")" -gt 60 ]; then rmdir "$lock" 2>/dev/null; fi
  if ! mkdir "$lock" 2>/dev/null; then
    CCSEAT_TOKEN=""
    return 1
  fi
  # The header goes to curl on stdin, so the token never shows up in ps.
  resp=$(printf 'header = "Authorization: Bearer %s"\n' "$CCSEAT_TOKEN" \
    | curl -s -K - --max-time "$max" --connect-timeout 3 \
      -H "Accept: application/json" \
      -H "Content-Type: application/json" \
      -H "anthropic-beta: oauth-2025-04-20" \
      -H "User-Agent: claude-code/2.1.280" \
      -w '\n%{http_code}' \
      "$CCSEAT_USAGE_URL" 2>/dev/null)
  CCSEAT_TOKEN=""
  code=${resp##*"$CCSEAT_NL"}
  body=${resp%"$CCSEAT_NL"*}
  [ "$code" = "$resp" ] && body=""
  case "$code" in ''|*[!0-9]*) code=000 ;; esac
  case "$code" in
    200)
      # Only the usage windows and limits are kept, never spending details.
      body=$(printf '%s' "$body" | jq -c --argjson now "$CCSEAT_NOW" '
        select(type == "object" and ((.five_hour | type) == "object" or (.seven_day | type) == "object"))
        | {five_hour, seven_day}
          + (to_entries | map(select((.key == "limits" or (.key | test("^seven_day_"))) and .value != null))
             | from_entries)
          + {fetched_at: $now}' 2>/dev/null)
      if [ -n "$body" ]; then
        printf '%s\n' "$body" | ccseat_write_file "$(ccseat_usage_cache_path "$name")"
        rm -f "$(ccseat__usage_err_path "$name")" 2>/dev/null
        rmdir "$lock" 2>/dev/null
        return 0
      fi
      ccseat__usage_set_err "$name" bad ;;
    401|403) ccseat__usage_set_err "$name" auth ;;
    429) ccseat__usage_set_err "$name" ratelimited ;;
    000) ccseat__usage_set_err "$name" offline ;;
    *) ccseat__usage_set_err "$name" http ;;
  esac
  rmdir "$lock" 2>/dev/null
  return 1
}

# Fetches when the cache is older than ttl seconds.
ccseat_usage_refresh() {
  local name="$1" ttl="${2:-$CCSEAT_USAGE_TTL}" max="${3:-5}"
  [ "$(ccseat_file_age "$(ccseat_usage_cache_path "$name")")" -lt "$ttl" ] && return 0
  ccseat_usage_fetch "$name" "$max"
}

# Refreshes several seats in parallel and waits at most tenths/10 seconds.
# Fetches still running after that finish on their own.
ccseat_usage_refresh_wait() {
  local tenths="$1" ttl="$2" name pids="" pid alive waited=0
  shift 2
  for name in "$@"; do
    [ "$(ccseat_file_age "$(ccseat_usage_cache_path "$name")")" -lt "$ttl" ] && continue
    ccseat_usage_fetch "$name" 5 </dev/null >/dev/null 2>&1 &
    pids="$pids $!"
  done
  [ -n "$pids" ] || return 0
  while [ "$waited" -lt "$tenths" ]; do
    alive=0
    for pid in $pids; do
      if kill -0 "$pid" 2>/dev/null; then alive=1; break; fi
    done
    [ "$alive" -eq 0 ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  return 0
}

# Starts refreshes that outlive this process (for the claude wrapper, which
# replaces itself with Claude Code right after).
ccseat_usage_refresh_detached() {
  local ttl="$1" name
  shift
  for name in "$@"; do
    [ "$(ccseat_file_age "$(ccseat_usage_cache_path "$name")")" -lt "$ttl" ] && continue
    ( ccseat_usage_fetch "$name" 5 </dev/null >/dev/null 2>&1 & )
  done
}

# Fetches one seat, waiting at most tenths/10 seconds, without leaving a
# child behind: the fetch runs detached and signals through a marker file.
ccseat_usage_fetch_bounded() {
  local name="$1" tenths="$2" marker waited=0
  ccseat_mkdir_private "$CCSEAT_CACHE_DIR" || return 1
  marker="$CCSEAT_CACHE_DIR/.done-$name-$$"
  rm -f "$marker" 2>/dev/null
  ( { ccseat_usage_fetch "$name" 5; : > "$marker"; sleep 5; rm -f "$marker"; } </dev/null >/dev/null 2>&1 & )
  while [ "$waited" -lt "$tenths" ]; do
    [ -f "$marker" ] && return 0
    sleep 0.1
    waited=$((waited + 1))
  done
  return 1
}

# Reads a seat's cached usage into CCSEAT_U_P5, CCSEAT_U_R5, CCSEAT_U_P7,
# CCSEAT_U_R7 (percent and reset epoch, "-" when unknown), CCSEAT_U_SRC
# (live, cache or none), CCSEAT_U_AGE (seconds) and CCSEAT_U_SCOPED (weekly
# limits of single models: "name|percent|reset" joined by ";"). Never
# touches the network.
ccseat_usage_load() {
  local name="$1" dir="${2:-}" cache gc age out cfile gfile
  CCSEAT_U_P5=- CCSEAT_U_R5=- CCSEAT_U_P7=- CCSEAT_U_R7=- CCSEAT_U_SRC=none CCSEAT_U_AGE=- CCSEAT_U_SCOPED=""
  [ -n "$dir" ] || dir=$(ccseat_seat_dir "$name") || return 1
  cache=$(ccseat_usage_cache_path "$name")
  gc=$(ccseat_global_config "$dir")
  ccseat__now_init
  age=999999 cfile=/dev/null gfile=/dev/null
  if [ -f "$cache" ]; then age=$(ccseat_file_age "$cache"); cfile=$cache; fi
  [ -f "$gc" ] && gfile=$gc
  out=$(jq -rn --argjson now "$CCSEAT_NOW" --argjson age "$age" --argjson ttl "$CCSEAT_USAGE_TTL" \
    --slurpfile c "$cfile" --slurpfile g "$gfile" "$CCSEAT_JQ_USAGE" 2>/dev/null)
  if [ -z "$out" ] && [ "$cfile" != /dev/null ]; then
    # A damaged cache file: fall back to Claude Code's own numbers.
    out=$(jq -rn --argjson now "$CCSEAT_NOW" --argjson age 999999 --argjson ttl "$CCSEAT_USAGE_TTL" \
      --slurpfile c /dev/null --slurpfile g "$gfile" "$CCSEAT_JQ_USAGE" 2>/dev/null)
  fi
  [ -n "$out" ] || return 0
  IFS=$'\t' read -r CCSEAT_U_P5 CCSEAT_U_R5 CCSEAT_U_P7 CCSEAT_U_R7 CCSEAT_U_SRC CCSEAT_U_AGE CCSEAT_U_SCOPED <<< "$out"
  return 0
}

# Tab-separated: five_pct five_reset_epoch week_pct week_reset_epoch source
# age ("-" for unknown). Reads the cache only.
ccseat_usage_summary() {
  ccseat_usage_load "${1:-}" "${2:-}" || return 1
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$CCSEAT_U_P5" "$CCSEAT_U_R5" "$CCSEAT_U_P7" "$CCSEAT_U_R7" "$CCSEAT_U_SRC" "$CCSEAT_U_AGE"
}

# After ccseat_usage_load: is the seat at a configured limit? Sets
# CCSEAT_LIMIT_WHICH (5-hour or weekly) and CCSEAT_LIMIT_UNTIL (epoch or -).
ccseat_usage_at_limit() {
  local l5 l7 at5=0 at7=0
  CCSEAT_LIMIT_WHICH="" CCSEAT_LIMIT_UNTIL=-
  l5=$(ccseat_config_get limit_5h)
  l7=$(ccseat_config_get limit_weekly)
  case "$CCSEAT_U_P5" in ''|-|*[!0-9]*) ;; *) [ "$CCSEAT_U_P5" -ge "$l5" ] && at5=1 ;; esac
  case "$CCSEAT_U_P7" in ''|-|*[!0-9]*) ;; *) [ "$CCSEAT_U_P7" -ge "$l7" ] && at7=1 ;; esac
  if [ "$at7" -eq 1 ]; then
    CCSEAT_LIMIT_WHICH=weekly
    CCSEAT_LIMIT_UNTIL=$CCSEAT_U_R7
    if [ "$at5" -eq 1 ] && [ "$CCSEAT_U_R5" != - ] && { [ "$CCSEAT_LIMIT_UNTIL" = - ] || [ "$CCSEAT_U_R5" -gt "$CCSEAT_LIMIT_UNTIL" ]; }; then
      CCSEAT_LIMIT_UNTIL=$CCSEAT_U_R5
    fi
    return 0
  fi
  if [ "$at5" -eq 1 ]; then
    CCSEAT_LIMIT_WHICH=5-hour
    CCSEAT_LIMIT_UNTIL=$CCSEAT_U_R5
    return 0
  fi
  return 1
}

# ---------- rows for list, usage and the picker ----------

# Fills CCSEAT_ROW_* arrays, indexed like the registry: AUTH, PLAN, P5, R5,
# P7, R7, SRC, AGE, STATUS (words for people), SCORE (lower is freer; 99 for
# unknown usage, 1000+ at a limit, 5000 not logged in), LIMIT (5-hour,
# weekly or empty), UNTIL. With $1=1 also EMAIL.
ccseat_rows_load() {
  local with_email="${1:-0}" i=0 dir name s err
  CCSEAT_ROW_AUTH=() CCSEAT_ROW_PLAN=() CCSEAT_ROW_P5=() CCSEAT_ROW_R5=() CCSEAT_ROW_P7=()
  CCSEAT_ROW_R7=() CCSEAT_ROW_SRC=() CCSEAT_ROW_AGE=() CCSEAT_ROW_STATUS=() CCSEAT_ROW_SCORE=()
  CCSEAT_ROW_LIMIT=() CCSEAT_ROW_UNTIL=() CCSEAT_ROW_EMAIL=() CCSEAT_ROW_SCOPED=()
  ccseat__registry_ensure
  ccseat__now_init
  while [ "$i" -lt "$CCSEAT_N" ]; do
    name=${CCSEAT_NAMES[i]}
    dir=${CCSEAT_DIRS[i]}
    ccseat_auth_check "$dir"
    CCSEAT_ROW_AUTH[i]=$CCSEAT_AUTH
    CCSEAT_ROW_PLAN[i]=$CCSEAT_PLAN
    ccseat_usage_load "$name" "$dir"
    CCSEAT_ROW_P5[i]=$CCSEAT_U_P5
    CCSEAT_ROW_R5[i]=$CCSEAT_U_R5
    CCSEAT_ROW_P7[i]=$CCSEAT_U_P7
    CCSEAT_ROW_R7[i]=$CCSEAT_U_R7
    CCSEAT_ROW_SRC[i]=$CCSEAT_U_SRC
    CCSEAT_ROW_AGE[i]=$CCSEAT_U_AGE
    CCSEAT_ROW_SCOPED[i]=$CCSEAT_U_SCOPED
    CCSEAT_ROW_LIMIT[i]=""
    CCSEAT_ROW_UNTIL[i]=-
    if ccseat_usage_at_limit; then
      CCSEAT_ROW_LIMIT[i]=$CCSEAT_LIMIT_WHICH
      CCSEAT_ROW_UNTIL[i]=$CCSEAT_LIMIT_UNTIL
    fi
    if [ "$with_email" = 1 ]; then
      CCSEAT_ROW_EMAIL[i]=$(ccseat_email "$dir" 2>/dev/null)
    else
      CCSEAT_ROW_EMAIL[i]=""
    fi

    # "idle": the token ran out while the seat was unused, which is normal;
    # Claude Code renews it the next time the seat opens.
    err=$(ccseat_usage_err "$name")
    case "$CCSEAT_AUTH" in
      none) s="not logged in" ;;
      expired) s="idle" ;;
      *)
        case "$CCSEAT_U_SRC" in
          live) s="live" ;;
          cache) s=$(ccseat_fmt_age "$CCSEAT_U_AGE") ;;
          *)
            case "$err" in
              auth) s="usage unavailable" ;;
              offline) s="offline" ;;
              *) s="no data yet" ;;
            esac ;;
        esac ;;
    esac
    CCSEAT_ROW_STATUS[i]=$s

    if [ "$CCSEAT_AUTH" = none ]; then
      CCSEAT_ROW_SCORE[i]=5000
    elif [ -n "${CCSEAT_ROW_LIMIT[i]}" ]; then
      # At a limit: the sooner it frees up, the better.
      if [ "${CCSEAT_ROW_UNTIL[i]}" != - ] && [ "${CCSEAT_ROW_UNTIL[i]}" -gt "$CCSEAT_NOW" ]; then
        CCSEAT_ROW_SCORE[i]=$(( 1000 + (CCSEAT_ROW_UNTIL[i] - CCSEAT_NOW) / 60 ))
      else
        CCSEAT_ROW_SCORE[i]=4000
      fi
    elif [ "$CCSEAT_U_P5" = - ] && [ "$CCSEAT_U_P7" = - ]; then
      CCSEAT_ROW_SCORE[i]=99
    else
      s=0
      [ "$CCSEAT_U_P5" != - ] && [ "$CCSEAT_U_P5" -gt "$s" ] && s=$CCSEAT_U_P5
      [ "$CCSEAT_U_P7" != - ] && [ "$CCSEAT_U_P7" -gt "$s" ] && s=$CCSEAT_U_P7
      CCSEAT_ROW_SCORE[i]=$s
    fi
    i=$((i + 1))
  done
}

# Index of the freest seat after ccseat_rows_load, skipping one index.
# Ties go to the earlier seat. Prints nothing when no seat is logged in.
ccseat_rows_freest() {
  local skip="${1:--1}" i=0 best="" bs=100000
  while [ "$i" -lt "$CCSEAT_N" ]; do
    if [ "$i" != "$skip" ] && [ "${CCSEAT_ROW_SCORE[i]}" -lt 5000 ] && [ "${CCSEAT_ROW_SCORE[i]}" -lt "$bs" ]; then
      best=$i
      bs=${CCSEAT_ROW_SCORE[i]}
    fi
    i=$((i + 1))
  done
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# Names of seats worth fetching: logged in with a token that has not expired.
ccseat_fetchable_seats() {
  local i=0 out=""
  ccseat__registry_ensure
  while [ "$i" -lt "$CCSEAT_N" ]; do
    ccseat_auth_check "${CCSEAT_DIRS[i]}"
    [ "$CCSEAT_AUTH" = ok ] && out="$out ${CCSEAT_NAMES[i]}"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# ---------- ccseat usage ----------

ccseat__usage_line() {
  # label pct reset dim label-width
  local label="$1" p="$2" r="$3" dim="${4:-0}" lw="${5:-6}" pc when
  if [ "$p" = - ]; then
    printf '    %s%s%s  %sno data%s\n' "$CCSEAT_C_MID" "$(ccseat_pad "$label" "$lw")" "$CCSEAT_C_RESET" "$CCSEAT_C_FAINT" "$CCSEAT_C_RESET"
    return
  fi
  if [ "$dim" = 1 ]; then pc=$CCSEAT_C_FAINT; else pc=$(ccseat_pct_color "$p"); fi
  when=""
  [ "$r" != - ] && when="  ${CCSEAT_C_FAINT}resets $(ccseat_fmt_reset "$r")$CCSEAT_C_RESET"
  printf '    %s%s%s  %s  %s%s%%%s%s\n' "$CCSEAT_C_MID" "$(ccseat_pad "$label" "$lw")" "$CCSEAT_C_RESET" \
    "$(ccseat_bar "$p" "$dim")" "$pc" "$(ccseat_rpad "$p" 3)" "$CCSEAT_C_RESET" "$when"
}

# Prints one "name|percent|reset" entry per line from CCSEAT_ROW_SCOPED.
ccseat__scoped_entries() {
  printf '%s\n' "${1:-}" | tr ';' '\n' | grep '|' 
  return 0
}

ccseat_cmd_usage() {
  local ref="" json=0 refresh=0 all=0 i idx names="" first=1 plan email tag raw lw sn sp sr
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1 ;;
      --refresh|-r) refresh=1 ;;
      --all|-a) all=1 ;;
      -h|--help) ccseat_help usage; return 0 ;;
      -*) ccseat_die_usage "unknown option for usage: $1" usage ;;
      *)
        [ -z "$ref" ] || ccseat_die_usage "usage takes one seat" usage
        ref=$1 ;;
    esac
    shift
  done
  ccseat_need_jq
  ccseat__registry_ensure
  if [ "$CCSEAT_N" -eq 0 ]; then
    if [ "$json" = 1 ]; then printf '[]\n'; return 0; fi
    ccseat_no_seats_hint
    return 0
  fi
  if [ -n "$ref" ]; then
    ccseat_resolve_seat "$ref" || exit 1
    names=$CCSEAT_R_NAME
  elif [ "$all" = 1 ]; then
    names=$(ccseat__names_joined | tr -d ',')
  else
    names=$(ccseat_current_get)
  fi

  # --refresh without a seat refreshes every seat, so the list and the
  # picker show fresh numbers too.
  if [ "$refresh" = 1 ] && [ -z "$ref" ]; then
    # shellcheck disable=SC2046 # seat names never contain spaces
    ccseat_usage_refresh_wait 80 0 $(ccseat_fetchable_seats)
  elif [ "$refresh" = 1 ]; then
    ccseat_usage_refresh_wait 80 0 "$names"
  else
    # shellcheck disable=SC2086
    ccseat_usage_refresh_wait 60 "$CCSEAT_USAGE_TTL" $names
  fi

  ccseat_rows_load 1
  if [ "$json" = 1 ]; then
    if [ "$all" = 1 ]; then
      ccseat__rows_json "$names"
    else
      # One seat: an object, with the last raw answer of the usage API.
      raw=$(ccseat_usage_cache_path "$names")
      [ -f "$raw" ] || raw=/dev/null
      ccseat__rows_json "$names" | jq --slurpfile raw "$raw" '.[0] + {raw: ($raw[0] // null)}' 2>/dev/null \
        || ccseat__rows_json "$names" | jq '.[0]'
    fi
    return 0
  fi
  ccseat_colors_init 1
  for idx in $names; do
    i=$(ccseat_seat_index "$idx") || continue
    [ "$first" = 1 ] || printf '\n'
    first=0
    email=${CCSEAT_ROW_EMAIL[i]}
    plan=$(ccseat_plan_label "${CCSEAT_ROW_PLAN[i]}")
    tag=""
    [ -n "$email" ] && tag="$email"
    [ -n "$plan" ] && tag="$tag${tag:+, }$plan"
    printf '%s%s%s%s' "$CCSEAT_C_BOLD" "$(ccseat__seat_color_at "$i")" "$idx" "$CCSEAT_C_RESET"
    [ -n "$tag" ] && printf '  %s%s%s' "$CCSEAT_C_MID" "$tag" "$CCSEAT_C_RESET"
    printf '\n'
    if [ "${CCSEAT_ROW_AUTH[i]}" = none ]; then
      printf '    %snot logged in. Sign in with: ccseat run %s%s\n' "$CCSEAT_C_ORANGE" "$idx" "$CCSEAT_C_RESET"
      continue
    fi
    lw=6
    while IFS='|' read -r sn sp sr; do
      [ -n "$sn" ] || continue
      sn="$sn weekly"
      [ "${#sn}" -gt "$lw" ] && lw=${#sn}
    done <<EOF
$(ccseat__scoped_entries "${CCSEAT_ROW_SCOPED[i]}")
EOF
    ccseat__usage_line "5-hour" "${CCSEAT_ROW_P5[i]}" "${CCSEAT_ROW_R5[i]}" 0 "$lw"
    ccseat__usage_line "weekly" "${CCSEAT_ROW_P7[i]}" "${CCSEAT_ROW_R7[i]}" 0 "$lw"
    while IFS='|' read -r sn sp sr; do
      [ -n "$sn" ] || continue
      ccseat__usage_line "$sn weekly" "$sp" "$sr" 0 "$lw"
    done <<EOF
$(ccseat__scoped_entries "${CCSEAT_ROW_SCOPED[i]}")
EOF
    ccseat__usage_status_line "$i"
  done
}

ccseat__usage_status_line() {
  local i="$1" s c
  s=${CCSEAT_ROW_STATUS[i]}
  case "$s" in
    live) s="updated just now"; c=$CCSEAT_C_FAINT ;;
    idle) s="idle: Claude Code renews its login the next time it opens"; c=$CCSEAT_C_FAINT ;;
    offline) s="could not reach the usage API"; c=$CCSEAT_C_KRAFT ;;
    "usage unavailable")
      s="the usage API refused this login (open it once: ccseat run ${CCSEAT_NAMES[i]})"
      c=$CCSEAT_C_KRAFT ;;
    "no data yet") s="no usage data yet"; c=$CCSEAT_C_FAINT ;;
    *) s="updated $s"; c=$CCSEAT_C_FAINT ;;
  esac
  if [ -n "${CCSEAT_ROW_LIMIT[i]}" ]; then
    printf '    %sat its %s limit' "$CCSEAT_C_ORANGE" "${CCSEAT_ROW_LIMIT[i]}"
    [ "${CCSEAT_ROW_UNTIL[i]}" != - ] && printf ' until %s' "$(ccseat_fmt_reset "${CCSEAT_ROW_UNTIL[i]}")"
    printf '%s\n' "$CCSEAT_C_RESET"
  fi
  printf '    %s%s%s\n' "$c" "$s" "$CCSEAT_C_RESET"
}

# JSON for some seats (space-separated names) or, with no names, all seats.
# Needs ccseat_rows_load 1 first.
ccseat__rows_json() {
  local only="${1:-}" i=0 cur lines="" n
  cur=$(ccseat_current_get 2>/dev/null)
  while [ "$i" -lt "$CCSEAT_N" ]; do
    n=${CCSEAT_NAMES[i]}
    if [ -n "$only" ]; then
      case " $only " in *" $n "*) ;; *) i=$((i + 1)); continue ;; esac
    fi
    lines="$lines$(jq -nc \
      --argjson index $((i + 1)) --arg name "$n" --arg dir "${CCSEAT_DIRS[i]}" \
      --arg email "${CCSEAT_ROW_EMAIL[i]}" --arg auth "${CCSEAT_ROW_AUTH[i]}" \
      --arg plan "$(ccseat_plan_label "${CCSEAT_ROW_PLAN[i]}")" \
      --arg primary "$([ "${CCSEAT_DIRS[i]}" = "$CCSEAT_PRIMARY_DIR" ] && echo 1)" \
      --arg current "$([ "$n" = "$cur" ] && echo 1)" \
      --arg p5 "${CCSEAT_ROW_P5[i]}" --arg r5 "${CCSEAT_ROW_R5[i]}" \
      --arg p7 "${CCSEAT_ROW_P7[i]}" --arg r7 "${CCSEAT_ROW_R7[i]}" \
      --arg f5 "$(ccseat_fmt_reset "${CCSEAT_ROW_R5[i]}")" --arg f7 "$(ccseat_fmt_reset "${CCSEAT_ROW_R7[i]}")" \
      --arg src "${CCSEAT_ROW_SRC[i]}" --arg age "${CCSEAT_ROW_AGE[i]}" \
      --arg status "${CCSEAT_ROW_STATUS[i]}" --arg limit "${CCSEAT_ROW_LIMIT[i]}" \
      --arg until "${CCSEAT_ROW_UNTIL[i]}" --arg scoped "${CCSEAT_ROW_SCOPED[i]}" '
      def num: if . == "-" or . == "" then null else tonumber end;
      def iso: if . == null then null else todate end;
      {index: $index, name: $name, email: (if $email == "" then null else $email end),
       dir: $dir, primary: ($primary == "1"), current: ($current == "1"),
       logged_in: ($auth != "none"), token: $auth,
       plan: (if $plan == "" then null else $plan end),
       five_hour: {percent: ($p5 | num), resets_at: ($r5 | num | iso),
                   resets: (if $f5 == "-" then null else $f5 end)},
       weekly: {percent: ($p7 | num), resets_at: ($r7 | num | iso),
                resets: (if $f7 == "-" then null else $f7 end)},
       at_limit: (if $limit == "" then null else $limit end),
       limit_until: ($until | num | iso),
       weekly_by_model: [$scoped | split(";")[] | select(test("[|]")) | split("|")
         | {model: .[0], percent: (.[1] | num), resets_at: (.[2] | num | iso)}],
       status: $status, source: $src, age_seconds: ($age | num)}')$CCSEAT_NL"
    i=$((i + 1))
  done
  printf '%s' "$lines" | jq -s '.'
}
