# shellcheck shell=bash
# shellcheck disable=SC2016 # jq programs in single quotes use $ for their own variables
# ccseat statusline: the status line Claude Code shows under its prompt.
#
#   ccseat statusline                        render it from the JSON Claude Code sends on stdin
#   ccseat statusline install [--seat S]     point settings.json at it (timestamped backup first)
#   ccseat statusline uninstall [--seat S]   put back the status line that was there before
#
# Two rows when idle, three while a workflow or agent runs:
#   alice     Opus 4.5 ultracode     ccseat (main*)     context 42%
#   5-hour  ●●○○○○○○○○   18%  resets 6:20 PM
#   weekly  ●●●●●●●●○○   79%  resets Saturday 6:00 AM
#   running  build  ●●○○○○○○○○  25%     phase 1 of 4     0 of 3 agents done
# A seat that is out says so on the row of the window at its limit, in red:
#   weekly  ●●●●●●●●●●  100%   LIMIT REACHED until Thursday 4:00 PM, next: work
# Limits come from the native rate_limits field and are copied into the seat's usage cache,
# so "ccseat list" stays fresh. Before the first reply of a session they come from that
# cache, refreshed in the background at most once a minute. It never waits on the network.

_CCSEAT_SL_GAP="   "
# Rows are fitted to this many columns. Claude Code does not tell the status line how wide
# the terminal is, so this comes from COLUMNS when set, else "ccseat config statusline_width"
# (default 80, the narrowest common terminal).
_CCSEAT_SL_WIDTH=80
_ccseat_sl_width() {
  local w="${COLUMNS:-}"
  case "$w" in ''|*[!0-9]*) w=$(ccseat_config_get statusline_width 2>/dev/null) ;; esac
  case "$w" in ''|*[!0-9]*) w=80 ;; esac
  [ "$w" -lt 40 ] && w=40
  _CCSEAT_SL_WIDTH=$w
}

# jq helpers: ep turns seconds, milliseconds or an ISO date (any offset) into epoch seconds
# (0 when unknown); pc rounds a percentage to the nearest integer (-1 when unknown); win reads
# one usage window, reset-aware; fmtreset writes a reset time exactly like ccseat_fmt_reset
# ("6:20 PM", "tomorrow 9:00 AM", "Saturday 6:00 AM", "Oct 3 6:00 AM", rounded to the minute)
# without starting date(1) twice per row, which keeps the status line fast.
_CCSEAT_SL_JQDEFS='def iso: (capture("^(?<b>[0-9-]+T[0-9:]+)(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$") // null)
    | if . == null then 0
      else ((.b + "Z") | fromdateiso8601)
        - (if (.z // "Z") == "Z" then 0
           else (if .z[0:1] == "-" then -1 else 1 end) * ((.z[1:3] | tonumber) * 3600 + (.z[-2:] | tonumber) * 60) end)
      end;
  def ep: if type == "number" then (if . > 1e12 then . / 1000 else . end | floor)
    elif type == "string" then (if test("^[0-9]+(\\.[0-9]+)?$") then (tonumber | if . > 1e12 then . / 1000 else . end | floor)
                                else (try iso catch 0) end)
    else 0 end;
  def pc: if type == "number" then (. + 0.5 | floor)
    elif type == "string" and test("^[0-9]+(\\.[0-9]+)?$") then (tonumber + 0.5 | floor)
    else -1 end;
  def win($now): (.utilization // null) as $u | (.resets_at | ep) as $r
    | if ($u | pc) < 0 then [-1, 0]
      elif ($r > 0 and $r < $now) then [0, 0]
      else [($u | pc), $r] end;
  def fmtreset($now):
    if . <= 0 then "" else
    (((. + 30) / 60 | floor) * 60) as $e
    | ($e | localtime) as $t | ($now | localtime) as $n
    | ($now - ($n[3] * 3600 + $n[4] * 60 + ($n[5] | floor))) as $midnight
    | (($midnight + 36 * 3600) | localtime) as $m
    | ($t[3] | floor) as $h | ($t[4] | floor) as $mi
    | "\(if $h % 12 == 0 then 12 else $h % 12 end):\(if $mi < 10 then "0" else "" end)\($mi) \(if $h < 12 then "AM" else "PM" end)" as $hm
    | if $t[0:3] == $n[0:3] then $hm
      elif $t[0:3] == $m[0:3] then "tomorrow \($hm)"
      elif $e > $now and ($e - $midnight) < 7 * 86400 then
        "\(["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"][$t[6]]) \($hm)"
      else "\(["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"][$t[1]]) \($t[2]) \($hm)" end
    end;
  def resetlabel($now): try fmtreset($now) catch "";'

# ---------- palette ----------

_ccseat_sl_color_enabled() {
  local f k v
  [ -n "${NO_COLOR:-}" ] && return 1
  f="$(_ccseat_sl_home)/config"
  [ -f "$f" ] || return 0
  while IFS='=' read -r k v || [ -n "$k" ]; do
    k=${k// /}; v=${v// /}
    [ "$k" = colors ] || continue
    case "$v" in never|off|no|false|0|none) return 1 ;; esac
  done < "$f"
  return 0
}

# Anthropic palette; color only where it means something. Claude Code reads the status line
# through a pipe, so the terminal test does not apply: only NO_COLOR and "colors never" turn
# color off. The core palette is used when loaded (same colors as the picker, main text in
# the terminal's own foreground so light themes stay readable, 256 colors for Terminal.app).
_ccseat_sl_palette() {
  local e=$'\033'
  if declare -F ccseat_colors_enable >/dev/null 2>&1; then
    ccseat_colors_enable
    _SL_ON=${CCSEAT__COLOR_ON:-0}
    _SL_R=${CCSEAT_C_RESET:-}; _SL_B=${CCSEAT_C_BOLD:-}; _SL_LABEL=${CCSEAT_C_MID:-}
    _SL_FAINT=${CCSEAT_C_FAINT:-}; _SL_TXT=${CCSEAT_C_TEXT:-}; _SL_SOFT=${CCSEAT_C_TEXT:-}
    _SL_MID=${CCSEAT_C_KRAFT:-}; _SL_HI=${CCSEAT_C_ORANGE:-}; _SL_RUN=${CCSEAT_C_BLUE:-}
    _SL_ULTRA=${CCSEAT_C_PURPLE:-}; _SL_RED=${CCSEAT_C_RED:-}
    return 0
  fi
  _SL_ON=1
  _ccseat_sl_color_enabled || _SL_ON=0
  if [ "$_SL_ON" -eq 0 ]; then
    _SL_R=""; _SL_B=""; _SL_LABEL=""; _SL_FAINT=""; _SL_TXT=""; _SL_SOFT=""
    _SL_MID=""; _SL_HI=""; _SL_RUN=""; _SL_ULTRA=""; _SL_RED=""
    return 0
  fi
  _SL_R="${e}[0m"; _SL_B="${e}[1m"
  _SL_LABEL="${e}[38;2;176;174;165m"   # Mid Gray: labels
  _SL_FAINT="${e}[38;2;110;108;102m"   # empty dots, reset times
  _SL_TXT="${e}[39m"                   # main text in the terminal's foreground
  _SL_SOFT="${e}[39m"                  # usage under 60%, effort
  _SL_MID="${e}[38;2;212;162;127m"     # Kraft: 60% and up, uncommitted changes
  _SL_HI="${e}[38;2;217;119;87m"       # Orange: 85% and up, alerts
  _SL_RUN="${e}[38;2;106;155;204m"     # Blue: progress
  _SL_ULTRA="${e}[38;2;167;139;250m"   # ultracode
  _SL_RED="${e}[38;2;229;83;75m"       # Red: a seat that is out, LIMIT REACHED
}

# Seat accent by position in the seat list: orange, blue, green, kraft, purple.
_ccseat_sl_seat_color() {
  local i=0 n d c e=$'\033'
  [ "$_SL_ON" -eq 1 ] || { _SL_OUT=""; return 0; }
  _SL_OUT="$_SL_B$_SL_TXT"
  [ -n "$1" ] || return 0
  if declare -F ccseat_seat_color >/dev/null 2>&1; then
    c=$(ccseat_seat_color "$1" 2>/dev/null)
    [ -n "$c" ] && _SL_OUT="$_SL_B$c"
    return 0
  fi
  while IFS=$'\t' read -r n d; do
    [ -n "$n" ] || continue
    if [ "$n" = "$1" ]; then
      case $(( i % 5 )) in
        0) _SL_OUT="$_SL_B${e}[38;2;217;119;87m" ;;
        1) _SL_OUT="$_SL_B${e}[38;2;106;155;204m" ;;
        2) _SL_OUT="$_SL_B${e}[38;2;120;140;93m" ;;
        3) _SL_OUT="$_SL_B${e}[38;2;212;162;127m" ;;
        4) _SL_OUT="$_SL_B${e}[38;2;167;139;250m" ;;
      esac
      return 0
    fi
    i=$(( i + 1 ))
  done <<EOF
$2
EOF
  : "$d"
  return 0
}

_ccseat_sl_pcolor() {
  if [ "$1" -ge 85 ]; then _SL_PC=$_SL_HI
  elif [ "$1" -ge 60 ]; then _SL_PC=$_SL_MID
  else _SL_PC=$_SL_SOFT; fi
}

# Ten dots, filled by the rounded share; any use above 0% fills at least one.
_ccseat_sl_dots() {
  local p=$1 i=0 f on="" off=""
  [ "$p" -lt 0 ] && p=0
  [ "$p" -gt 100 ] && p=100
  f=$(( (p * 10 + 50) / 100 ))
  [ "$p" -gt 0 ] && [ "$f" -eq 0 ] && f=1
  while [ "$i" -lt 10 ]; do
    if [ "$i" -lt "$f" ]; then on="${on}●"; else off="${off}○"; fi
    i=$(( i + 1 ))
  done
  _SL_OUT="$2$on$_SL_FAINT$off$_SL_R"
}

# "5-hour  ●●○○○○○○○○   18%  resets 6:20 PM". $4 = the reset time already written, if known;
# $5 = a color for the dots and percent that wins (red for a window at its limit).
_ccseat_sl_usage_row() {
  local name=$1 p=$2 at=$3 r=${4:-} c=${5:-} pp dots
  [ -n "$c" ] || { _ccseat_sl_pcolor "$p"; c=$_SL_PC; }
  _ccseat_sl_dots "$p" "$c"; dots=$_SL_OUT
  printf -v pp '%3s' "$p"
  _SL_OUT="$_SL_LABEL$name  $_SL_R$dots  $c$pp%$_SL_R"
  if [ "$at" -gt 0 ]; then
    [ -n "$r" ] || r=$(ccseat_fmt_reset "$at" 2>/dev/null)
    [ -n "$r" ] && [ "$r" != "-" ] && _SL_OUT="$_SL_OUT  ${_SL_FAINT}resets $r$_SL_R"
  fi
  return 0
}

# Visible width of a row: its characters without the color codes. Sets _SL_LEN.
_ccseat_sl_vislen() {
  local rest=$1 out="" esc=$'\033['
  while :; do
    case "$rest" in
      *"$esc"*)
        out="$out${rest%%"$esc"*}"
        rest=${rest#*"$esc"}
        rest=${rest#*m} ;;
      *) out="$out$rest"; break ;;
    esac
  done
  _SL_LEN=${#out}
}

# Cuts text to a number of characters with an ellipsis.
_ccseat_sl_trunc() {
  local t=$1 w=$2
  if [ "${#t}" -gt "$w" ]; then t="${t:0:$(( w - 1 ))}…"; fi
  printf '%s' "$t"
}

_ccseat_sl_plural() {
  if [ "$1" -eq 1 ]; then printf '%s %s' "$1" "$2"; else printf '%s %ss' "$1" "$2"; fi
}

# ---------- paths ----------

_ccseat_sl_home() { printf '%s\n' "${CCSEAT_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/ccseat}"; }

_ccseat_sl_strip() {
  local p=$1
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p=${p%/}; done
  printf '%s\n' "$p"
}

# Follows a chain of symlinks to the file that holds the data.
_ccseat_sl_realfile() {
  local p=$1 l n=0
  while [ -L "$p" ] && [ "$n" -lt 40 ]; do
    l=$(readlink "$p") || break
    case "$l" in /*) p=$l ;; *) p="${p%/*}/$l" ;; esac
    n=$(( n + 1 ))
  done
  printf '%s\n' "$p"
}

# Absolute, symlink-free path of a file, for comparisons.
_ccseat_sl_canon() {
  local f d
  f=$(_ccseat_sl_realfile "$1")
  d=$(cd -P "$(dirname "$f")" 2>/dev/null && pwd) || { printf '%s\n' "$f"; return 0; }
  printf '%s/%s\n' "$d" "${f##*/}"
}

# The ccseat program behind this library: $CCSEAT_SELF when the entrypoint exports it, else
# bin/ccseat next to lib/, else the one on PATH.
_ccseat_sl_self() {
  local d p
  if [ -n "${CCSEAT_SELF:-}" ] && [ -x "$CCSEAT_SELF" ]; then printf '%s\n' "$CCSEAT_SELF"; return 0; fi
  d=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)
  if [ -n "$d" ] && [ -x "$d/bin/ccseat" ]; then printf '%s\n' "$d/bin/ccseat"; return 0; fi
  p=$(command -v ccseat 2>/dev/null) || return 1
  case "$p" in /*) printf '%s\n' "$p"; return 0 ;; esac
  return 1
}

_ccseat_sl_tilde() {
  case "$1" in "$HOME"/*) printf '~%s\n' "${1#"$HOME"}" ;; *) printf '%s\n' "$1" ;; esac
}

# ---------- usage cache ----------

_ccseat_sl_age() {
  local m
  m=$(_ccseat_pg_mtime "$1")
  if [ "$m" -gt 0 ]; then printf '%s\n' $(( _SL_NOW - m )); else printf '%s\n' 999999; fi
}

# Writes the native limits into the seat's cache in the OAuth usage endpoint's shape, keeping
# a window the stdin JSON lacks. Private file, atomic replace.
_ccseat_sl_write_cache() {
  local c=$1 d tmp prog
  d=${c%/*}
  [ -d "$d" ] || (umask 077 && mkdir -p "$d") 2>/dev/null || return 0
  tmp=$(mktemp "$d/.usage-XXXXXX" 2>/dev/null) || return 0
  prog='def win($u; $r): if $u < 0 then null
          else {utilization: $u, resets_at: (if $r > 0 then ($r | todate) else null end)} end;
        (if type == "object" then . else {} end) as $old
        | ($old | with_entries(select(.key == "limits" or .key == "fetched_at" or (.key | test("^seven_day_")))))
          + {source: "statusline",
             five_hour: (win($fh; $fa) // $old.five_hour),
             seven_day: (win($wk; $wa) // $old.seven_day)}'
  if { [ -f "$c" ] && jq -c --argjson fh "$2" --argjson fa "$3" --argjson wk "$4" --argjson wa "$5" \
         "$prog" "$c" > "$tmp" 2>/dev/null; } \
     || jq -nc --argjson fh "$2" --argjson fa "$3" --argjson wk "$4" --argjson wa "$5" \
         "{} | $prog" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$c" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
  return 0
}

# Starts "ccseat usage <seat> --refresh" in the background, at most once a minute per seat.
# The lock directory doubles as the timestamp of the last attempt.
_ccseat_sl_refresh() {
  local seat=$1 lock="$2.lock" self
  if [ -d "$lock" ] && [ "$(_ccseat_sl_age "$lock")" -gt 60 ]; then rmdir "$lock" 2>/dev/null; fi
  [ -d "${lock%/*}" ] || (umask 077 && mkdir -p "${lock%/*}") 2>/dev/null || return 0
  mkdir -m 700 "$lock" 2>/dev/null || return 0
  if declare -F ccseat_usage_refresh_detached >/dev/null 2>&1; then
    ccseat_usage_refresh_detached 60 "$seat" </dev/null >/dev/null 2>&1
    return 0
  fi
  self=$(_ccseat_sl_self) || return 0
  ( "$self" usage "$seat" --refresh ) </dev/null >/dev/null 2>&1 &
  return 0
}

# Highest of the two windows of a cache file, reset-aware; -1 when it has no data.
_ccseat_sl_cache_use() {
  jq -r --argjson now "$_SL_NOW" "$_CCSEAT_SL_JQDEFS"'
    [((.five_hour // {}) | win($now) | .[0]), ((.seven_day // {}) | win($now) | .[0])] | max' "$1" 2>/dev/null
}

# ---------- git ----------

# Sets _SL_BRANCH and _SL_DIRTY for a folder with a single git call. The
# repository's own core.fsmonitor command is turned off for it.
_ccseat_sl_git() {
  local line oid="" head=""
  _SL_BRANCH=""; _SL_DIRTY=0
  command -v git >/dev/null 2>&1 || return 0
  while IFS= read -r line; do
    case "$line" in
      "# branch.oid "*) oid=${line#\# branch.oid } ;;
      "# branch.head "*) head=${line#\# branch.head } ;;
      "#"*) ;;
      ?*) _SL_DIRTY=1 ;;
    esac
  done <<EOF
$(GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor= -C "$1" status --porcelain=v2 --branch --ignore-submodules 2>/dev/null)
EOF
  if [ -n "$head" ] && [ "$head" != "(detached)" ]; then _SL_BRANCH=$head
  elif [ -n "$oid" ] && [ "$oid" != "(initial)" ]; then _SL_BRANCH=${oid:0:7}; fi
  return 0
}

# ---------- render ----------

# Row 1: seat, model and mode, folder (branch*), context. Sets _SL_OUT.
_ccseat_sl_row1() {
  local sc=$1 name=$2 model=$3 mode=$4 mc=$5 folder=$6 branch=$7 pct=$8 r
  r="$sc$name$_SL_R$_CCSEAT_SL_GAP$_SL_TXT$model$_SL_R"
  [ -n "$mode" ] && r="$r $mc$mode$_SL_R"
  r="$r$_CCSEAT_SL_GAP$_SL_TXT$folder$_SL_R"
  if [ -n "$branch" ]; then
    r="$r $_SL_LABEL($_SL_R$_SL_LABEL$branch$_SL_R"
    [ "$_SL_DIRTY" -eq 1 ] && r="$r$_SL_MID*$_SL_R"
    r="$r$_SL_LABEL)$_SL_R"
  fi
  if [ "$pct" -ge 85 ]; then r="$r$_CCSEAT_SL_GAP${_SL_LABEL}context $_SL_R$_SL_HI$_SL_B$pct%$_SL_R"
  else r="$r$_CCSEAT_SL_GAP${_SL_LABEL}context $_SL_R$_SL_TXT$pct%$_SL_R"; fi
  _SL_OUT=$r
}

# Adds "almost out, next: bob" or "LIMIT REACHED until 6:20 PM, next: bob" to the usage
# row in _SL_OUT, in color $3; the other seat is named only when it fits. $4 is a shorter
# state ("LIMIT REACHED") for when the whole one does not fit.
_ccseat_sl_hint() {
  local state=$1 best=$2 hc=${3:-$_SL_HI} short=${4:-} row=$_SL_OUT idx="" st
  if [ -n "$best" ]; then
    # A long seat name does not fit: point to it by its number in "ccseat list" instead.
    idx=$(ccseat_seat_list 2>/dev/null | awk -F '\t' -v n="$best" '$1 == n { print NR; exit }')
  fi
  for st in "$state" "$short"; do
    [ -n "$st" ] || continue
    if [ -n "$best" ]; then
      _ccseat_sl_vislen "$row$_CCSEAT_SL_GAP$st, next: $best"
      if [ "$_SL_LEN" -le "$_CCSEAT_SL_WIDTH" ]; then
        _SL_OUT="$row$_CCSEAT_SL_GAP$hc$st$_SL_R$_SL_LABEL, next: $_SL_R$_SL_TXT$best$_SL_R"
        return 0
      fi
      if [ -n "$idx" ]; then
        _ccseat_sl_vislen "$row$_CCSEAT_SL_GAP$st, next: seat $idx"
        if [ "$_SL_LEN" -le "$_CCSEAT_SL_WIDTH" ]; then
          _SL_OUT="$row$_CCSEAT_SL_GAP$hc$st$_SL_R$_SL_LABEL, next: $_SL_R${_SL_TXT}seat $idx$_SL_R"
          return 0
        fi
      fi
    fi
    _ccseat_sl_vislen "$row$_CCSEAT_SL_GAP$st"
    if [ "$_SL_LEN" -le "$_CCSEAT_SL_WIDTH" ] || [ -z "$short" ] || [ "$st" = "$short" ]; then
      _SL_OUT="$row$_CCSEAT_SL_GAP$hc$st$_SL_R"
      return 0
    fi
  done
  _SL_OUT="$row$_CCSEAT_SL_GAP$hc$state$_SL_R"
}

_ccseat_sl_render() {
  local input=$1 model pct cwd sid effort fh fh_at wk wk_at prog out fh_lab wk_lab
  local l5 l7 trig seg_phase seg_done seg_other seg_quiet
  local dir seat name seats cache="" age=999999 settings uc mode mode_color folder
  local row1 row2 row3="" seg best best_use n d oc use state us=$'\037'
  local rows tag a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 wp wok n_wf=0 pct_sum=0 t_ok=0 t_start=0
  local isout=0 short="" hc back_at ulab out5=0 out7=0 c5="" c7="" at
  local t_fail=0 one_name="" one_k=0 one_n=0 n_solo=0 n_quiet=0 max_quiet=0 solo_name="" overall
  _ccseat_sl_width

  _ccseat_sl_palette
  # One jq call reads the session, the clock and the ultracode flag of this seat's settings.
  settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; settings="${settings%/}/settings.json"
  [ -f "$settings" ] || settings="$HOME/.claude/settings.json"
  prog="$_CCSEAT_SL_JQDEFS"'[
      (.model.display_name // .model.id // "Claude"),
      ((.context_window // {}) as $c
        | if ($c | type) != "object" then 0
          elif ($c.used_percentage | type) == "number" or ($c.used_percentage | type) == "string" then $c.used_percentage
          elif ($c.current_usage | type) == "object" and (($c.context_window_size // 0) | type) == "number"
               and ($c.context_window_size // 0) > 0 then
            ([$c.current_usage.input_tokens, $c.current_usage.cache_creation_input_tokens,
              $c.current_usage.cache_read_input_tokens] | map(select(type == "number")) | add // 0)
            * 100 / $c.context_window_size
          else 0 end | pc | if . < 0 then 0 else . end),
      (.workspace.current_dir // .cwd // ""),
      (.session_id // ""),
      (.effort | if type == "object" then (.level // "") elif type == "string" then . else "" end),
      (.rate_limits.five_hour.used_percentage | pc),
      (.rate_limits.five_hour.resets_at | ep),
      (.rate_limits.seven_day.used_percentage | pc),
      (.rate_limits.seven_day.resets_at | ep),
      (now | floor),
      (($s[0] // {}) | if type == "object" then (.ultracode == true) else false end),
      (.rate_limits.five_hour.resets_at | ep | resetlabel(now)),
      (.rate_limits.seven_day.resets_at | ep | resetlabel(now))
    ] | map(tostring | gsub("[\n\r\t]"; " ") | gsub("[[:cntrl:]]"; "")) | join("\u001f")'
  out=""
  [ -f "$settings" ] && out=$(printf '%s' "$input" | jq -r --slurpfile s "$settings" "$prog" 2>/dev/null)
  [ -n "$out" ] || out=$(printf '%s' "$input" | jq -r --argjson s '[]' "$prog" 2>/dev/null)
  IFS=$us read -r model pct cwd sid effort fh fh_at wk wk_at _SL_NOW uc fh_lab wk_lab <<EOF
$out
EOF
  case "$_SL_NOW" in ''|*[!0-9]*) _SL_NOW=$(date +%s) ;; esac
  [ -n "$model" ] || model="Claude"
  case "$pct" in ''|*[!0-9]*) pct=0 ;; esac
  case "$fh" in ''|*[!0-9]*) fh=-1 ;; esac
  case "$wk" in ''|*[!0-9]*) wk=-1 ;; esac
  case "$fh_at" in ''|*[!0-9]*) fh_at=0 ;; esac
  case "$wk_at" in ''|*[!0-9]*) wk_at=0 ;; esac
  case "$sid" in *[!A-Za-z0-9_-]*) sid="" ;; esac

  # Seat: the registered name of this config dir, else the email name, else the folder name.
  dir=$(_ccseat_sl_strip "${CLAUDE_CONFIG_DIR:-}")
  [ "$dir" = "$HOME/.claude" ] && dir=""
  # Load the registry in this shell once, so core lookups made in subshells see it.
  declare -F ccseat_registry_load >/dev/null 2>&1 && ccseat_registry_load 2>/dev/null
  seats=$(ccseat_seat_list 2>/dev/null)
  seat=$(ccseat_seat_for_dir "$dir" 2>/dev/null); seat=${seat%%$'\n'*}
  name=$seat
  [ -n "$name" ] || { name=$(ccseat_email_name "${dir:-$HOME/.claude}" 2>/dev/null); name=${name%%$'\n'*}; }
  if [ -z "$name" ]; then
    if [ -n "$dir" ]; then name=${dir##*/}; name=${name#.claude-}; name=${name#.}; else name="claude"; fi
  fi

  # Usage: native limits win and refresh the cache; otherwise the cache, refreshed behind.
  if [ -n "$seat" ]; then
    cache=$(ccseat_usage_cache_path "$seat" 2>/dev/null); cache=${cache%%$'\n'*}
    [ -n "$cache" ] && [ -f "$cache" ] && age=$(_ccseat_sl_age "$cache")
  fi
  if [ "$fh" -ge 0 ] || [ "$wk" -ge 0 ]; then
    if [ -n "$cache" ] && [ "$age" -gt 20 ]; then
      _ccseat_sl_write_cache "$cache" "$fh" "$fh_at" "$wk" "$wk_at"
    fi
  elif [ -n "$cache" ]; then
    if declare -F ccseat_usage_load >/dev/null 2>&1; then
      # The same reader as "ccseat list": this cache or Claude Code's own cached numbers,
      # whichever is newer, reset-aware. Numbers older than a day are not shown.
      ccseat_usage_load "$seat" "${dir:-$HOME/.claude}" 2>/dev/null
      case "${CCSEAT_U_AGE:-}" in ''|*[!0-9]*) CCSEAT_U_AGE=999999 ;; esac
      if [ "${CCSEAT_U_SRC:-none}" != none ] && [ "$CCSEAT_U_AGE" -lt 86400 ]; then
        fh=${CCSEAT_U_P5:--}; fh_at=${CCSEAT_U_R5:-0}; wk=${CCSEAT_U_P7:--}; wk_at=${CCSEAT_U_R7:-0}
        fh_lab=""; wk_lab=""
      fi
    elif [ -f "$cache" ] && [ "$age" -lt 86400 ]; then
      IFS=$us read -r fh fh_at wk wk_at fh_lab wk_lab <<EOF
$(jq -r --argjson now "$_SL_NOW" "$_CCSEAT_SL_JQDEFS"'
    ((.five_hour // {}) | win($now)) as $a | ((.seven_day // {}) | win($now)) as $b
    | $a + $b + [($a[1] | resetlabel($now)), ($b[1] | resetlabel($now))]
    | map(tostring) | join("\u001f")' "$cache" 2>/dev/null)
EOF
    fi
    case "$fh" in ''|*[!0-9]*) fh=-1 ;; esac
    case "$wk" in ''|*[!0-9]*) wk=-1 ;; esac
    case "$fh_at" in ''|*[!0-9]*) fh_at=0 ;; esac
    case "$wk_at" in ''|*[!0-9]*) wk_at=0 ;; esac
    [ "$age" -ge 60 ] && _ccseat_sl_refresh "$seat" "$cache"
  fi

  # Row 1: seat, model and mode, folder (branch*), context.
  mode=""; mode_color=$_SL_SOFT
  case "$effort" in
    xhigh|"")
      if [ "$uc" = true ]; then mode="ultracode"; mode_color="$_SL_B$_SL_ULTRA"
      elif [ -n "$effort" ]; then mode="extra high effort"; fi ;;
    max) mode="max effort" ;;
    high) mode="high effort" ;;
    medium) mode="medium effort"; mode_color=$_SL_LABEL ;;
    low) mode="low effort"; mode_color=$_SL_LABEL ;;
  esac
  [ -n "$cwd" ] || cwd=$(pwd)
  if [ "$cwd" = "$HOME" ]; then folder="home"; else folder=${cwd%/}; folder=${folder##*/}; fi
  # A folder name can hold escape codes (git clones any file name); only
  # the colors of this line reach the terminal.
  folder=${folder//[[:cntrl:]]/}
  name=${name//[[:cntrl:]]/}
  [ -n "$folder" ] || folder="/"
  _ccseat_sl_git "$cwd"

  _ccseat_sl_seat_color "$seat" "$seats"
  seg=$_SL_OUT
  _ccseat_sl_row1 "$seg" "$name" "${model%% (*}" "$mode" "$mode_color" "$folder" "$_SL_BRANCH" "$pct"
  row1=$_SL_OUT
  _ccseat_sl_vislen "$row1"
  if [ "$_SL_LEN" -gt "$_CCSEAT_SL_WIDTH" ] && [ -n "$_SL_BRANCH" ]; then
    # A long branch name is cut first, then the folder.
    n=$(( ${#_SL_BRANCH} - (_SL_LEN - _CCSEAT_SL_WIDTH) ))
    [ "$n" -lt 8 ] && n=8
    _ccseat_sl_row1 "$seg" "$name" "${model%% (*}" "$mode" "$mode_color" "$folder" "$(_ccseat_sl_trunc "$_SL_BRANCH" "$n")" "$pct"
    row1=$_SL_OUT
    _ccseat_sl_vislen "$row1"
  fi
  if [ "$_SL_LEN" -gt "$_CCSEAT_SL_WIDTH" ]; then
    n=$(( ${#folder} - (_SL_LEN - _CCSEAT_SL_WIDTH) ))
    [ "$n" -lt 8 ] && n=8
    folder=$(_ccseat_sl_trunc "$folder" "$n")
    [ -n "$_SL_BRANCH" ] && _SL_BRANCH=$(_ccseat_sl_trunc "$_SL_BRANCH" 8)
    _ccseat_sl_row1 "$seg" "$name" "${model%% (*}" "$mode" "$mode_color" "$folder" "$_SL_BRANCH" "$pct"
    row1=$_SL_OUT
  fi

  # Rows 2 and 3: 5-hour, then weekly below it. The row that is at its
  # limit (the same limits as "ccseat list" and the claude command) or close
  # to it says so, with the freest other seat when one has room.
  l5=95 l7=100
  if declare -F ccseat_config_get >/dev/null 2>&1; then
    l5=$(ccseat_config_get limit_5h 2>/dev/null); l7=$(ccseat_config_get limit_weekly 2>/dev/null)
    case "$l5" in ''|*[!0-9]*) l5=95 ;; esac
    case "$l7" in ''|*[!0-9]*) l7=100 ;; esac
  fi
  trig="" state="" hc=$_SL_HI
  # A window at its limit is red, dots and percent.
  [ "$fh" -ge 0 ] && [ "$fh" -ge "$l5" ] && out5=1 c5=$_SL_RED
  [ "$wk" -ge 0 ] && [ "$wk" -ge "$l7" ] && out7=1 c7=$_SL_RED
  if [ "$out7" = 1 ]; then trig=weekly isout=1
  elif [ "$out5" = 1 ]; then trig=5-hour isout=1
  elif [ "$wk" -ge 85 ] && [ "$wk" -ge "$fh" ]; then trig=weekly state="almost out"
  elif [ "$fh" -ge 85 ]; then trig=5-hour state="almost out"
  fi
  # Out: the seat is back when the window at its limit resets (the later one when both
  # are). The hint says until when, so that row leaves out its own "resets".
  ulab=""
  if [ "$isout" = 1 ]; then
    if [ "$trig" = weekly ]; then back_at=$wk_at ulab=$wk_lab; else back_at=$fh_at ulab=$fh_lab; fi
    if [ "$trig" = weekly ] && [ "$out5" = 1 ] && [ "$fh_at" -gt "$back_at" ]; then back_at=$fh_at ulab=$fh_lab; fi
    if [ "$back_at" -gt 0 ]; then
      [ -n "$ulab" ] || ulab=$(ccseat_fmt_reset "$back_at" 2>/dev/null)
      [ "$ulab" = - ] && ulab=""
    else
      ulab=""
    fi
    state="LIMIT REACHED${ulab:+ until $ulab}" short="LIMIT REACHED" hc="$_SL_B$_SL_RED"
  fi
  best=""; best_use=101
  if [ -n "$trig" ]; then
    while IFS=$'\t' read -r n d; do
      { [ -n "$n" ] && [ "$n" != "$seat" ]; } || continue
      oc=$(ccseat_usage_cache_path "$n" 2>/dev/null); oc=${oc%%$'\n'*}
      { [ -n "$oc" ] && [ -f "$oc" ]; } || continue
      [ "$(_ccseat_sl_age "$oc")" -lt 86400 ] || continue
      use=$(_ccseat_sl_cache_use "$oc")
      case "$use" in ''|*[!0-9]*) continue ;; esac
      [ "$use" -lt "$best_use" ] && { best=$n; best_use=$use; }
    done <<EOF
$seats
EOF
    : "$d"
    [ "$best_use" -lt 70 ] || best=""
  fi
  row2=""
  if [ "$fh" -ge 0 ]; then
    at=$fh_at
    [ "$trig" = 5-hour ] && [ -n "$ulab" ] && at=0
    _ccseat_sl_usage_row "5-hour" "$fh" "$at" "$fh_lab" "$c5"
    [ "$trig" = 5-hour ] && _ccseat_sl_hint "$state" "$best" "$hc" "$short"
    row2=$_SL_OUT
  fi
  if [ "$wk" -ge 0 ]; then
    at=$wk_at
    [ "$trig" = weekly ] && [ -n "$ulab" ] && at=0
    _ccseat_sl_usage_row "weekly" "$wk" "$at" "$wk_lab" "$c7"
    [ "$trig" = weekly ] && _ccseat_sl_hint "$state" "$best" "$hc" "$short"
    row2="${row2:+$row2$'\n'}$_SL_OUT"
  fi
  [ -n "$row2" ] || row2="${_SL_LABEL}usage: no data yet$_SL_R"

  # Row 4: what runs in this session, summarized; only while something runs.
  if [ -n "$sid" ]; then
    _ccseat_pg_init "$_SL_NOW"
    rows=$(_ccseat_pg_collect "$sid" wa 1)
    while IFS=$'\t' read -r tag a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11; do
      case "$tag" in
        W)
          # a1 name, a2 phase index, a3 phases, a5 finished, a6 started, a7 running,
          # a8 failed, a10 started in phase, a11 finished in phase
          for seg in a2 a3 a5 a6 a7 a8 a10 a11; do
            case "${!seg}" in ''|*[!0-9]*) eval "$seg=0" ;; esac
          done
          if [ "$a3" -gt 0 ] && [ "$a2" -gt 0 ] && [ "$a10" -gt 0 ]; then
            wp=$(( ((a2 - 1) * 100 + a11 * 100 / a10) / a3 ))
          elif [ "$a6" -gt 0 ]; then wp=$(( a5 * 100 / a6 ))
          else wp=0; fi
          [ "$wp" -gt 99 ] && [ "$a7" -gt 0 ] && wp=99
          wok=$(( a5 - a8 )); [ "$wok" -lt 0 ] && wok=0
          n_wf=$(( n_wf + 1 )); pct_sum=$(( pct_sum + wp ))
          t_ok=$(( t_ok + wok )); t_start=$(( t_start + a6 )); t_fail=$(( t_fail + a8 ))
          one_name=$a1; one_k=$a2; one_n=$a3 ;;
        A)
          # a1 kind, a3 label, a7 idle seconds
          case "$a7" in ''|*[!0-9]*) a7=0 ;; esac
          if [ "$a7" -ge 300 ]; then
            n_quiet=$(( n_quiet + 1 )); [ "$a7" -gt "$max_quiet" ] && max_quiet=$a7
          fi
          if [ "$a1" = bg ] || [ "$a1" = fg ]; then n_solo=$(( n_solo + 1 )); solo_name=$a3; fi ;;
      esac
    done <<EOF
$rows
EOF
    : "$a4" "$a9"
    # Segments in order; when the row is too wide the least useful go first:
    # quiet agents, then other agents, then the phase. The name, the dots,
    # the percent and the agents done always stay.
    seg_phase="" seg_done="" seg_other="" seg_quiet=""
    if [ "$n_wf" -gt 0 ]; then
      overall=$(( pct_sum / n_wf ))
      _ccseat_sl_dots "$overall" "$_SL_RUN"
      if [ "$n_wf" -eq 1 ]; then
        row3="${_SL_LABEL}running  $_SL_R$_SL_TXT$(_ccseat_sl_trunc "$one_name" 30)$_SL_R  $_SL_OUT  $_SL_RUN$overall%$_SL_R"
        [ "$one_k" -gt 0 ] && [ "$one_n" -gt 1 ] && seg_phase="$_CCSEAT_SL_GAP${_SL_LABEL}phase $one_k of $one_n$_SL_R"
      else
        row3="${_SL_LABEL}running  $_SL_R$_SL_TXT$n_wf workflows$_SL_R  $_SL_OUT  $_SL_RUN$overall%$_SL_R"
      fi
      seg_done="$_CCSEAT_SL_GAP$_SL_LABEL$t_ok of $t_start agents done$_SL_R"
      [ "$t_fail" -gt 0 ] && seg_done="$seg_done$_SL_HI, $t_fail failed$_SL_R"
      if [ "$n_solo" -eq 1 ]; then seg_other="$_CCSEAT_SL_GAP${_SL_LABEL}1 other agent$_SL_R"
      elif [ "$n_solo" -gt 1 ]; then seg_other="$_CCSEAT_SL_GAP$_SL_LABEL$n_solo other agents$_SL_R"; fi
    elif [ "$n_solo" -gt 0 ]; then
      if [ "$n_solo" -eq 1 ]; then
        row3="${_SL_LABEL}running  $_SL_R$_SL_TXT$(_ccseat_sl_trunc "$solo_name" 39)$_SL_R"
      else
        row3="${_SL_LABEL}running  $_SL_R$_SL_TXT$(_ccseat_sl_plural "$n_solo" agent)$_SL_R"
      fi
    fi
    if [ -n "$row3" ] && [ "$n_quiet" -gt 0 ]; then
      seg_quiet="$_CCSEAT_SL_GAP$_SL_HI$(_ccseat_sl_plural "$n_quiet" agent) quiet $(( max_quiet / 60 )) min$_SL_R"
    fi
    if [ -n "$row3" ]; then
      for seg in "$seg_phase$seg_done$seg_other$seg_quiet" "$seg_phase$seg_done$seg_other" \
        "$seg_phase$seg_done" "$seg_done"; do
        _ccseat_sl_vislen "$row3$seg"
        [ "$_SL_LEN" -le "$_CCSEAT_SL_WIDTH" ] && break
      done
      row3="$row3$seg"
    fi
  fi

  printf '%s\n%s' "$row1" "$row2"
  [ -n "$row3" ] && printf '\n%s' "$row3"
  return 0
}

# ---------- install / uninstall ----------

# State of the statusLine key in a settings file: ccseat, other, none or invalid.
ccseat_statusline_state() {
  local f=${1:-$HOME/.claude/settings.json}
  [ -f "$f" ] || { printf 'none\n'; return 0; }
  jq -r 'if type != "object" then "invalid"
         elif (.statusLine | type) != "object" then "none"
         elif ((.statusLine.command // "") | tostring
               | test("ccseat[\"'"'"']?[[:space:]]+statusline([[:space:]]|$)")) then "ccseat"
         else "other" end' "$f" 2>/dev/null || printf 'invalid\n'
  return 0
}

# Seat by name, unique prefix or 1-based index; prints "name<TAB>dir".
_ccseat_sl_find_seat() {
  local want=$1 n d i=0 hit="" hits=0 tab=$'\t'
  while IFS=$'\t' read -r n d; do
    [ -n "$n" ] || continue
    i=$(( i + 1 ))
    if [ "$n" = "$want" ] || [ "$i" = "$want" ]; then printf '%s\t%s\n' "$n" "$d"; return 0; fi
    case "$n" in "$want"*) hit="$n$tab$d"; hits=$(( hits + 1 )) ;; esac
  done <<EOF
$(ccseat_seat_list 2>/dev/null)
EOF
  [ "$hits" -eq 1 ] && { printf '%s\n' "$hit"; return 0; }
  return 1
}

_ccseat_sl_err() { printf 'ccseat: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; return 0; }

_ccseat_sl_need_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  _ccseat_sl_err "jq is required to edit settings.json." \
    "Install it (macOS: brew install jq, Debian or Ubuntu: sudo apt install jq) and run this again."
  return 1
}

# Parses [--seat S] [-q]; sets _SL_TARGET (settings.json path), _SL_TARGET_SEAT, _SL_QUIET.
_ccseat_sl_target() {
  local want="" hit tab=$'\t'
  _SL_QUIET=0; _SL_TARGET_SEAT=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --seat) [ $# -ge 2 ] || { _ccseat_sl_err "--seat needs a seat name." "Example: ccseat statusline install --seat work"; return 2; }
              want=$2; shift ;;
      --seat=*) want=${1#--seat=} ;;
      -q|--quiet) _SL_QUIET=1 ;;
      -y|--yes) ;;
      *) _ccseat_sl_err "unknown option: $1" "Run \"ccseat statusline --help\" for the options."; return 2 ;;
    esac
    shift
  done
  if [ -z "$want" ]; then _SL_TARGET="$HOME/.claude/settings.json"; return 0; fi
  hit=$(_ccseat_sl_find_seat "$want") || {
    _ccseat_sl_err "no seat matches \"$want\"." "See your seats with: ccseat list"; return 1; }
  _SL_TARGET_SEAT=${hit%%"$tab"*}
  _SL_TARGET="$(_ccseat_sl_strip "${hit#*"$tab"}")/settings.json"
  # The primary seat, or a seat whose settings.json links to the primary one, shares it.
  if [ "$(_ccseat_sl_canon "$_SL_TARGET")" = "$(_ccseat_sl_canon "$HOME/.claude/settings.json")" ]; then
    _SL_TARGET="$HOME/.claude/settings.json"; _SL_TARGET_SEAT=""
  fi
  return 0
}

_ccseat_sl_say() { [ "${_SL_QUIET:-0}" -eq 1 ] || printf '%s\n' "$*"; return 0; }

# Copies a file into ccseat's own backups folder (never next to it, so
# ~/.claude gets no clutter), keeping the newest three copies of each file.
# Prints the backup path.
_ccseat_sl_backup() {
  local f=$1 dir parent prefix stamp b n=1
  dir="$(_ccseat_sl_home)/backups"
  [ -d "$dir" ] || (umask 077 && mkdir -p "$dir") 2>/dev/null || return 1
  parent=${f%/*}; parent=${parent##*/}; parent=${parent#.}
  prefix="$parent-${f##*/}"
  stamp=$(date +%Y%m%d-%H%M%S)
  b="$dir/$prefix.$stamp"
  while [ -e "$b" ]; do n=$(( n + 1 )); b="$dir/$prefix.$stamp-$n"; done
  cp -p "$f" "$b" 2>/dev/null || return 1
  set -- "$dir/$prefix".*
  while [ $# -gt 3 ]; do rm -f "$1"; shift; done
  printf '%s\n' "$b"
}

# Replaces a JSON file atomically with the output of a jq program, keeping its permissions.
# $1 file, $2 jq program, rest: extra jq arguments.
_ccseat_sl_jq_edit() {
  local f=$1 prog=$2 tmp mode
  shift 2
  tmp=$(mktemp "${f%/*}/.ccseat-edit-XXXXXX" 2>/dev/null) || return 1
  if jq "$@" "$prog" "$f" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    if [ "$_CCSEAT_PG_STAT" = gnu ]; then mode=$("$_CCSEAT_PG_STATCMD" -c %a "$f" 2>/dev/null)
    else mode=$("$_CCSEAT_PG_STATCMD" -f %Lp "$f" 2>/dev/null); fi
    [ -n "$mode" ] && chmod "$mode" "$tmp" 2>/dev/null
    mv -f "$tmp" "$f" && return 0
  fi
  rm -f "$tmp"
  return 1
}

_ccseat_sl_saved_file() { printf '%s/statusline-previous.json\n' "$(_ccseat_sl_home)"; }

_ccseat_sl_install() {
  local f real self cmd state prev saved home b="" n d other shown created=0
  _ccseat_sl_need_jq || return 1
  # The status line names the seat and caches its usage, so register the current Claude
  # Code login as the first seat if nothing is registered yet.
  declare -F ccseat_first_run >/dev/null 2>&1 && ccseat_first_run
  _ccseat_sl_target "$@" || return $?
  _ccseat_pg_init >/dev/null 2>&1
  self=$(_ccseat_sl_self) || { _ccseat_sl_err "cannot find the ccseat program to point Claude Code at." \
    "Install ccseat (see the README) so that \"command -v ccseat\" finds it, then run this again."; return 1; }
  # Prefer the stable path on PATH (a Homebrew or ~/.local/bin link survives upgrades) when it
  # is this same program.
  cmd=$(command -v ccseat 2>/dev/null)
  case "$cmd" in /*) [ "$(_ccseat_sl_canon "$cmd")" = "$(_ccseat_sl_canon "$self")" ] || cmd=$self ;; *) cmd=$self ;; esac
  case "$cmd" in
    *[!A-Za-z0-9_./+@-]*) cmd="'$(printf '%s' "$cmd" | sed "s/'/'\\\\''/g")'" ;;
  esac
  cmd="$cmd statusline"

  f=$_SL_TARGET
  real=$(_ccseat_sl_canon "$f")
  shown=$(_ccseat_sl_tilde "$f")
  if [ ! -e "$real" ]; then
    (umask 077 && mkdir -p "${real%/*}") 2>/dev/null
    (umask 077 && printf '{}\n' > "$real") 2>/dev/null || { _ccseat_sl_err "cannot create $shown."; return 1; }
    created=1
  fi
  state=$(ccseat_statusline_state "$real")
  if [ "$state" = invalid ]; then
    _ccseat_sl_err "$shown is not valid JSON, so it was left untouched." \
      "Fix it (jq . \"$real\" shows where) and run this again."
    return 1
  fi
  if [ "$state" = ccseat ] && jq -e --arg cmd "$cmd" \
       '.statusLine == {type: "command", command: $cmd, refreshInterval: 10}' "$real" >/dev/null 2>&1; then
    _ccseat_sl_say "The status line is already installed in $shown."
    return 0
  fi

  # Keep a status line that is not ours so uninstall can put it back.
  if [ "$state" = other ]; then
    prev=$(jq -c '.statusLine' "$real" 2>/dev/null)
    home=$(_ccseat_sl_home); saved=$(_ccseat_sl_saved_file)
    [ -d "$home" ] || (umask 077 && mkdir -p "$home") 2>/dev/null
    [ -f "$saved" ] && jq -e 'type == "object"' "$saved" >/dev/null 2>&1 || printf '{}\n' > "$saved"
    chmod 600 "$saved" 2>/dev/null
    _ccseat_sl_jq_edit "$saved" '.[$path] = $prev' --arg path "$real" --argjson prev "$prev" \
      || { _ccseat_sl_err "cannot save your current status line in $saved; nothing was changed."; return 1; }
  fi

  if [ "$created" -eq 0 ]; then
    b=$(_ccseat_sl_backup "$real") || { _ccseat_sl_err "cannot back up $shown; nothing was changed."; return 1; }
  fi
  _ccseat_sl_jq_edit "$real" '.statusLine = {type: "command", command: $cmd, refreshInterval: 10}' --arg cmd "$cmd" \
    || { _ccseat_sl_err "cannot update $shown; it was left as it was."; return 1; }

  if [ -n "$_SL_TARGET_SEAT" ]; then _ccseat_sl_say "Status line installed for $_SL_TARGET_SEAT in $shown."
  else _ccseat_sl_say "Status line installed in $shown, shared by every seat."; fi
  [ -n "$b" ] && _ccseat_sl_say "Backup: $(_ccseat_sl_tilde "$b")"
  [ "$state" = other ] && _ccseat_sl_say "Your previous status line is saved; ccseat statusline uninstall puts it back."
  _ccseat_sl_say "Claude Code shows it at its next refresh, within a few seconds."

  # Seats that keep their own settings.json do not see the primary one.
  if [ -z "$_SL_TARGET_SEAT" ]; then
    while IFS=$'\t' read -r n d; do
      [ -n "$n" ] || continue
      d=$(_ccseat_sl_strip "$d")
      [ "$d" = "$HOME/.claude" ] && continue
      [ -e "$d/settings.json" ] || continue
      other=$(_ccseat_sl_canon "$d/settings.json")
      [ "$other" = "$real" ] && continue
      [ "$(ccseat_statusline_state "$other")" = ccseat ] && continue
      _ccseat_sl_say "Seat $n has its own settings.json. To show it there too:"
      _ccseat_sl_say "  ccseat statusline install --seat $n"
    done <<EOF
$(ccseat_seat_list 2>/dev/null)
EOF
  fi
  return 0
}

_ccseat_sl_uninstall() {
  local f real state saved key prev="" b shown
  _ccseat_sl_target "$@" || return $?
  _ccseat_sl_need_jq || return 1
  _ccseat_pg_init >/dev/null 2>&1
  f=$_SL_TARGET
  real=$(_ccseat_sl_canon "$f")
  shown=$(_ccseat_sl_tilde "$f")
  state=$(ccseat_statusline_state "$real")
  case "$state" in
    none) _ccseat_sl_say "No status line is set in $shown; nothing to remove."; return 0 ;;
    other) _ccseat_sl_say "The status line in $shown is not ccseat's, so it was left as it is."; return 0 ;;
    invalid) _ccseat_sl_err "$shown is not valid JSON, so it was left untouched." \
               "Fix it (jq . \"$real\" shows where) and run this again."; return 1 ;;
  esac
  saved=$(_ccseat_sl_saved_file)
  key=$real
  if [ -f "$saved" ]; then
    prev=$(jq -c --arg path "$key" '.[$path] // empty | select(type == "object")' "$saved" 2>/dev/null)
  fi
  b=$(_ccseat_sl_backup "$real") || { _ccseat_sl_err "cannot back up $shown; nothing was changed."; return 1; }
  if [ -n "$prev" ]; then
    _ccseat_sl_jq_edit "$real" '.statusLine = $prev' --argjson prev "$prev" \
      || { _ccseat_sl_err "cannot update $shown; it was left as it was."; return 1; }
    _ccseat_sl_jq_edit "$saved" 'del(.[$path])' --arg path "$key"
    _ccseat_sl_say "Status line removed from $shown; your previous one is back."
  else
    _ccseat_sl_jq_edit "$real" 'del(.statusLine)' \
      || { _ccseat_sl_err "cannot update $shown; it was left as it was."; return 1; }
    _ccseat_sl_say "Status line removed from $shown."
  fi
  _ccseat_sl_say "Backup: $(_ccseat_sl_tilde "$b")"
  return 0
}

_ccseat_sl_usage() {
  cat <<'EOF'
Usage: ccseat statusline [install | uninstall] [--seat <seat>]

Shows the seat, model, folder, context and both usage limits under the Claude
Code prompt, plus what is running while a workflow or agent works.

  ccseat statusline               render it (Claude Code runs this and sends the
                                  session details on stdin; in a terminal it
                                  prints a preview)
  ccseat statusline install       set it in ~/.claude/settings.json, which every
                                  seat shares; saves a timestamped backup and
                                  keeps any status line you had
  ccseat statusline uninstall     remove it and put back the previous one

  --seat <seat>   use that seat's own settings.json instead (for a seat that
                  does not share settings)
  -q, --quiet     print nothing on success
EOF
}

ccseat_statusline_main() {
  local input="" sub=${1:-}
  # A status line must always print something and exit 0; no command failure may end it early.
  set +e
  case "$sub" in
    install) shift; _ccseat_sl_install "$@"; return $? ;;
    uninstall) shift; _ccseat_sl_uninstall "$@"; return $? ;;
    -h|--help|help) _ccseat_sl_usage; return 0 ;;
    ""|preview) ;;
    *) _ccseat_sl_err "unknown statusline command: $sub" "Run \"ccseat statusline --help\" for the options."
       return 2 ;;
  esac
  command -v jq >/dev/null 2>&1 || PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
  if ! command -v jq >/dev/null 2>&1; then
    printf 'ccseat: the status line needs jq (brew install jq, or apt install jq)'
    return 0
  fi
  # shellcheck source=/dev/null # progress.sh, next to this file
  declare -F _ccseat_pg_collect >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/progress.sh"
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ;;
    *) case "${OSTYPE:-}" in darwin*) LC_ALL=en_US.UTF-8 ;; *) LC_ALL=C.UTF-8 ;; esac ;;
  esac

  if [ "$sub" = preview ] || [ -t 0 ]; then
    # Run by hand in a terminal: show what Claude Code would show here.
    input=$(jq -nc --arg cwd "$(pwd)" '{model: {display_name: "Claude"}, workspace: {current_dir: $cwd},
      context_window: {used_percentage: 0}}')
    _ccseat_sl_render "$input"
    printf '\n\n'
    if [ "$(ccseat_statusline_state)" = ccseat ]; then
      printf 'This is a preview with sample session details.\n'
      printf 'It is installed: Claude Code shows it under the prompt.\n'
    else
      printf 'This is a preview with sample session details.\n'
      printf 'Turn it on with: ccseat statusline install\n'
    fi
    return 0
  fi
  IFS= read -r -d '' input || true
  if [ -z "$input" ]; then printf 'ccseat'; return 0; fi
  _ccseat_sl_render "$input"
  return 0
}
