# shellcheck shell=bash
# ccseat picker: choose a seat with the arrow keys and open Claude Code.
# Draws on the terminal's alternate screen (like vim or fzf), so the shell
# comes back untouched, and fits narrow windows and short terminals. The
# size is read again on every draw, and a resize redraws within a second.

ccseat__pick_restore() {
  printf '\033[?25h\033[?1049l'
  # read -s turns echo off; an interrupted read leaves it off on bash 3.2.
  [ -n "${CCSEAT__PICK_STTY:-}" ] && stty "$CCSEAT__PICK_STTY" 2>/dev/null
  return 0
}

ccseat__pick_abort() {
  trap - INT TERM HUP WINCH
  ccseat__pick_restore
  ccseat__pick_jobs_clean
  exit 130
}

# One usage row of a seat, fitted to the terminal width. $6=1 when this
# window is at its limit: its bar and percent are red, selected or not.
ccseat__pick_usage_line() {
  local label="$1" p="$2" r="$3" dim="$4" cols="$5" out="${6:-0}" pc bc="" when used
  if [ "$out" = 1 ]; then pc=$CCSEAT_C_RED bc=$CCSEAT_C_RED
  elif [ "$dim" = 1 ]; then pc=$CCSEAT_C_FAINT; else pc=$(ccseat_pct_color "$p"); fi
  when=$(ccseat_fmt_reset "$r")
  [ "$when" = - ] && when=""
  if [ "$cols" -ge 56 ]; then
    used=30
    [ -n "$when" ] && when="resets $when"
    printf '    %s%s%s  %s  %s%s%%%s  %s%s%s' "$CCSEAT_C_MID" "$label" "$CCSEAT_C_RESET" "$(ccseat_bar "$p" "$dim" "$bc")" \
      "$pc" "$(ccseat_rpad "$p" 3)" "$CCSEAT_C_RESET" "$CCSEAT_C_FAINT" "$(ccseat_trunc "$when" $((cols - used)))" "$CCSEAT_C_RESET"
  elif [ "$cols" -ge 48 ]; then
    used=30
    printf '    %s%s%s  %s  %s%s%%%s  %s%s%s' "$CCSEAT_C_MID" "$label" "$CCSEAT_C_RESET" "$(ccseat_bar "$p" "$dim" "$bc")" \
      "$pc" "$(ccseat_rpad "$p" 3)" "$CCSEAT_C_RESET" "$CCSEAT_C_FAINT" "$(ccseat_trunc "$when" $((cols - used)))" "$CCSEAT_C_RESET"
  elif [ "$cols" -ge 42 ]; then
    used=18
    [ -n "$when" ] && when="resets $when"
    [ "${#when}" -gt $((cols - used)) ] && when=${when#resets }
    printf '    %s%s%s  %s%s%%%s  %s%s%s' "$CCSEAT_C_MID" "$label" "$CCSEAT_C_RESET" \
      "$pc" "$(ccseat_rpad "$p" 3)" "$CCSEAT_C_RESET" "$CCSEAT_C_FAINT" "$(ccseat_trunc "$when" $((cols - used)))" "$CCSEAT_C_RESET"
  else
    used=15
    printf '  %s%s%s %s%s%%%s %s%s%s' "$CCSEAT_C_MID" "$label" "$CCSEAT_C_RESET" \
      "$pc" "$(ccseat_rpad "$p" 3)" "$CCSEAT_C_RESET" "$CCSEAT_C_FAINT" "$(ccseat_trunc "$when" $((cols - used)))" "$CCSEAT_C_RESET"
  fi
}

# True when a seat has no usage numbers to draw.
ccseat__pick_no_data() {
  [ "${CCSEAT_ROW_P5[$1]}" = - ] && [ "${CCSEAT_ROW_P7[$1]}" = - ]
}

# Lines a seat takes on screen (without the blank line between seats).
ccseat__pick_height() {
  if [ "$CCSEAT__PICK_COMPACT" = 1 ]; then printf 1
  elif [ "${CCSEAT_ROW_AUTH[$1]}" = none ] || ccseat__pick_no_data "$1"; then printf 2
  else printf 3; fi
}

# The highest weekly limit of a single model, as "name|percent", when it is
# at 60% or more.
ccseat__pick_scoped() {
  local best="" bp=59 n p r
  while IFS='|' read -r n p r; do
    case "$p" in ''|*[!0-9]*) continue ;; esac
    [ "$p" -gt "$bp" ] && { best="$n|$p"; bp=$p; }
  done <<EOF
$(printf '%s\n' "${CCSEAT_ROW_SCOPED[$1]:-}" | tr ';' '\n')
EOF
  : "$r"
  printf '%s' "$best"
}

# Short notes after a seat's name, as long as they fit in room characters.
# A seat that is out gets "LIMIT REACHED back Thursday 4:00 PM" (just
# "LIMIT REACHED" when the time does not fit).
ccseat__pick_tags() {
  local i="$1" cur="$2" room="$3" compact="$4" out="" len=0 t c s sc back
  s=${CCSEAT_ROW_STATUS[i]}
  # The full layout says "no usage data yet" on its own line.
  [ "$compact" = 0 ] && [ "$s" = "no data yet" ] && s=live
  if ccseat_row_out "$i"; then
    t="" c=""
    back=$(ccseat_row_back "$i")
    if [ -n "$back" ] && [ $((len + 2 + 13 + 6 + ${#back})) -le "$room" ]; then
      out="$out  $CCSEAT_C_BOLD${CCSEAT_C_RED}LIMIT REACHED$CCSEAT_C_RESET$CCSEAT_C_RED back $back$CCSEAT_C_RESET"
      len=$((len + 2 + 13 + 6 + ${#back}))
    elif [ $((len + 2 + 13)) -le "$room" ]; then
      out="$out  $CCSEAT_C_BOLD${CCSEAT_C_RED}LIMIT REACHED$CCSEAT_C_RESET"
      len=$((len + 2 + 13))
    fi
  elif [ "${CCSEAT_ROW_AUTH[i]}" = none ]; then
    t="not logged in" c=$CCSEAT_C_ORANGE
  elif [ "$s" = live ]; then
    t="" c=""
  else
    t=$s c=$CCSEAT_C_FAINT
    [ "$s" = offline ] || [ "$s" = "usage unavailable" ] && c=$CCSEAT_C_KRAFT
  fi
  if [ -n "$t" ] && [ $((len + 2 + ${#t})) -le "$room" ]; then
    out="$out  $c$t$CCSEAT_C_RESET"; len=$((len + 2 + ${#t}))
  fi
  if [ "$compact" = 0 ] && [ "${CCSEAT_ROW_AUTH[i]}" != none ]; then
    sc=$(ccseat__pick_scoped "$i")
    if [ -n "$sc" ]; then
      t="${sc%%|*} weekly ${sc##*|}%"
      c=$(ccseat_pct_color "${sc##*|}")
      if [ $((len + 2 + ${#t})) -le "$room" ]; then
        out="$out  $c$t$CCSEAT_C_RESET"; len=$((len + 2 + ${#t}))
      fi
    fi
  fi
  if [ "${CCSEAT_NAMES[i]}" = "$cur" ] && [ $((len + 9)) -le "$room" ]; then
    out="$out  ${CCSEAT_C_FAINT}current$CCSEAT_C_RESET"; len=$((len + 9))
  fi
  printf '%s' "$out"
}

# A percentage for the one-line layout: "96%" (four wide), in red with a
# "!" when the seat is at that window's limit.
ccseat__pick_pct() {
  local p="$1" dim="$2" limit="$3" c
  if [ "$p" = - ]; then printf '%s%s%s ' "$CCSEAT_C_FAINT" "$(ccseat_rpad - 4)" "$CCSEAT_C_RESET"; return; fi
  if [ "$p" -ge "$limit" ]; then
    printf '%s%s%s!%s' "$CCSEAT_C_BOLD" "$CCSEAT_C_RED" "$(ccseat_rpad "$p%" 4)" "$CCSEAT_C_RESET"
    return
  fi
  if [ "$dim" = 1 ]; then c=$CCSEAT_C_FAINT; else c=$(ccseat_pct_color "$p"); fi
  printf '%s%s%s ' "$c" "$(ccseat_rpad "$p%" 4)" "$CCSEAT_C_RESET"
}

ccseat__pick_seat_lines() {
  local i="$1" sel="$2" cols="$3" cur="$4" name nc dim room nw o5=0 o7=0 d5 d7
  nc=$(ccseat__seat_color_at "$i")
  if [ "$i" = "$sel" ]; then dim=0; else dim=1; fi
  # A seat that is out: the window at its limit is red, the rest dimmed.
  d5=$dim d7=$dim
  if ccseat_row_out "$i"; then
    ccseat_row_window_out "$i" 5 && o5=1
    ccseat_row_window_out "$i" 7 && o7=1
    [ "$o5" = 1 ] || d5=1
    [ "$o7" = 1 ] || d7=1
  fi

  if [ "$CCSEAT__PICK_COMPACT" = 1 ]; then
    # One line per seat: names padded so the numbers line up.
    nw=$CCSEAT__PICK_NAMEW
    name=$(ccseat_trunc "${CCSEAT_NAMES[i]}" "$nw")
    if [ "$i" = "$sel" ]; then
      printf '%s%s❯%s %s%s%s%s' "$CCSEAT_C_BOLD" "$nc" "$CCSEAT_C_RESET" "$CCSEAT_C_BOLD" "$nc" "$(ccseat_pad "$name" "$nw")" "$CCSEAT_C_RESET"
    else
      printf '  %s%s%s' "$nc" "$(ccseat_pad "$name" "$nw")" "$CCSEAT_C_RESET"
    fi
    if [ "${CCSEAT_ROW_AUTH[i]}" = none ]; then
      room=$((cols - 2 - nw))
      printf '%s\n' "$(ccseat__pick_tags "$i" "$cur" "$room" 1)"
      return
    fi
    if [ "$cols" -ge $((nw + 30)) ]; then
      printf '  %s5-hour%s %s  %sweekly%s %s' "$CCSEAT_C_MID" "$CCSEAT_C_RESET" \
        "$(ccseat__pick_pct "${CCSEAT_ROW_P5[i]}" "$d5" "$(ccseat_config_get limit_5h)")" "$CCSEAT_C_MID" "$CCSEAT_C_RESET" \
        "$(ccseat__pick_pct "${CCSEAT_ROW_P7[i]}" "$d7" "$(ccseat_config_get limit_weekly)")"
      room=$((cols - nw - 30))
    else
      printf '  %s %s' "$(ccseat__pick_pct "${CCSEAT_ROW_P5[i]}" "$d5" "$(ccseat_config_get limit_5h)")" \
        "$(ccseat__pick_pct "${CCSEAT_ROW_P7[i]}" "$d7" "$(ccseat_config_get limit_weekly)")"
      room=$((cols - nw - 15))
    fi
    printf '%s\n' "$(ccseat__pick_tags "$i" "$cur" "$room" 1)"
    return
  fi

  name=$(ccseat_trunc "${CCSEAT_NAMES[i]}" $((cols - 4)))
  if [ "$i" = "$sel" ]; then
    printf '%s%s❯%s %s%s%s%s' "$CCSEAT_C_BOLD" "$nc" "$CCSEAT_C_RESET" "$CCSEAT_C_BOLD" "$nc" "$name" "$CCSEAT_C_RESET"
  else
    printf '  %s%s%s' "$nc" "$name" "$CCSEAT_C_RESET"
  fi
  printf '%s\n' "$(ccseat__pick_tags "$i" "$cur" $((cols - 2 - ${#name})) 0)"
  if [ "${CCSEAT_ROW_AUTH[i]}" = none ]; then
    printf '    %s%s%s\n' "$CCSEAT_C_FAINT" "$(ccseat_trunc "opening it signs you in" $((cols - 4)))" "$CCSEAT_C_RESET"
    return
  fi
  if ccseat__pick_no_data "$i"; then
    if [ "${CCSEAT_ROW_AUTH[i]}" = expired ]; then
      printf '    %s%s%s\n' "$CCSEAT_C_FAINT" "$(ccseat_trunc "usage shows after it opens once" $((cols - 4)))" "$CCSEAT_C_RESET"
    else
      printf '    %s%s%s\n' "$CCSEAT_C_FAINT" "$(ccseat_trunc "no usage data yet" $((cols - 4)))" "$CCSEAT_C_RESET"
    fi
    return
  fi
  printf '%s\n' "$(ccseat__pick_usage_line "5-hour" "${CCSEAT_ROW_P5[i]}" "${CCSEAT_ROW_R5[i]}" "$d5" "$cols" "$o5")"
  printf '%s\n' "$(ccseat__pick_usage_line "weekly" "${CCSEAT_ROW_P7[i]}" "${CCSEAT_ROW_R7[i]}" "$d7" "$cols" "$o7")"
}

# Keeps the selected seat on screen; sets CCSEAT__PICK_OFF and
# CCSEAT__PICK_END (last visible index).
ccseat__pick_window() {
  local sel="$1" avail="$2" i used h
  [ "$CCSEAT__PICK_OFF" -gt "$sel" ] && CCSEAT__PICK_OFF=$sel
  while :; do
    used=0
    i=$CCSEAT__PICK_OFF
    CCSEAT__PICK_END=$((i - 1))
    while [ "$i" -lt "$CCSEAT_N" ]; do
      h=$(ccseat__pick_height "$i")
      [ "$i" -gt "$CCSEAT__PICK_OFF" ] && [ "$CCSEAT__PICK_COMPACT" = 0 ] && h=$((h + 1))
      [ $((used + h)) -le "$avail" ] || break
      used=$((used + h))
      CCSEAT__PICK_END=$i
      i=$((i + 1))
    done
    [ "$CCSEAT__PICK_END" -lt "$CCSEAT__PICK_OFF" ] && CCSEAT__PICK_END=$CCSEAT__PICK_OFF
    [ "$sel" -le "$CCSEAT__PICK_END" ] && break
    CCSEAT__PICK_OFF=$((CCSEAT__PICK_OFF + 1))
  done
}

# The question asked before an out seat opens, fitted to the width:
# "personal is out until Thursday 4:00 PM. Open it anyway? (y/N)".
ccseat__pick_question() {
  local i="$1" cols="$2" name back head q="Open it anyway? (y/N)"
  name=${CCSEAT_NAMES[i]}
  back=$(ccseat_row_back "$i")
  head="$name is out${back:+ until $back}."
  if [ $(( ${#head} + 1 + ${#q} )) -gt "$cols" ] && [ -n "$back" ]; then head="$name is out."; fi
  if [ $(( ${#head} + 1 + ${#q} )) -gt "$cols" ]; then
    q=$(ccseat_trunc "Open $name anyway? (y/N)" "$cols")
    printf '%s%s%s%s' "$CCSEAT_C_BOLD" "$CCSEAT_C_TEXT" "$q" "$CCSEAT_C_RESET"
    return
  fi
  printf '%s%s%s%s %s%s%s%s' "$CCSEAT_C_BOLD" "$CCSEAT_C_RED" "$head" "$CCSEAT_C_RESET" \
    "$CCSEAT_C_BOLD" "$CCSEAT_C_TEXT" "$q" "$CCSEAT_C_RESET"
}

ccseat__pick_draw() {
  local sel="$1" busy="$2" cur="$3" ask="${4:-}" cols lines avail total i out title hint n
  ccseat__term_size
  cols=$CCSEAT__TERM_COLS
  lines=$CCSEAT__TERM_ROWS
  # Full layout when it fits, else one line per seat.
  CCSEAT__PICK_COMPACT=0
  total=0
  i=0
  while [ "$i" -lt "$CCSEAT_N" ]; do
    total=$((total + $(ccseat__pick_height "$i") + 1))
    i=$((i + 1))
  done
  [ $((total + 3)) -gt "$lines" ] && CCSEAT__PICK_COMPACT=1
  if [ "$CCSEAT__PICK_COMPACT" = 1 ]; then
    CCSEAT__PICK_NAMEW=4
    i=0
    while [ "$i" -lt "$CCSEAT_N" ]; do
      n=${CCSEAT_NAMES[i]}
      [ "${#n}" -gt "$CCSEAT__PICK_NAMEW" ] && CCSEAT__PICK_NAMEW=${#n}
      i=$((i + 1))
    done
    # Room for the numbers; long names are cut to leave it.
    [ "$CCSEAT__PICK_NAMEW" -gt $((cols - 30)) ] && CCSEAT__PICK_NAMEW=$((cols - 30))
    [ "$CCSEAT__PICK_NAMEW" -lt 8 ] && CCSEAT__PICK_NAMEW=8
    [ "$CCSEAT__PICK_NAMEW" -gt $((cols - 15)) ] && CCSEAT__PICK_NAMEW=$((cols - 15))
    [ "$CCSEAT__PICK_NAMEW" -lt 1 ] && CCSEAT__PICK_NAMEW=1
  fi
  avail=$((lines - 3))
  [ "$avail" -lt 1 ] && avail=1
  ccseat__pick_window "$sel" "$avail"

  title=""
  if [ "$CCSEAT__PICK_OFF" -gt 0 ] || [ "$CCSEAT__PICK_END" -lt $((CCSEAT_N - 1)) ]; then
    title=" $CCSEAT_C_FAINT($((sel + 1)) of $CCSEAT_N)$CCSEAT_C_RESET"
  fi
  [ "$busy" = 1 ] && [ "$cols" -ge 36 ] && title="$title$CCSEAT_C_FAINT  updating…$CCSEAT_C_RESET"
  if [ "$cols" -ge 46 ]; then hint="↑ ↓ move   enter or 1-9 open   q cancel"
  else hint=$(ccseat_trunc "↑↓ move  enter open  q cancel" "$cols"); fi

  out=$(
    printf '%s%sChoose a seat%s%s\n' "$CCSEAT_C_BOLD" "$CCSEAT_C_TEXT" "$CCSEAT_C_RESET" "$title"
    if [ -n "$ask" ]; then
      printf '%s\n\n' "$(ccseat__pick_question "$ask" "$cols")"
    else
      printf '%s%s%s\n\n' "$CCSEAT_C_FAINT" "$hint" "$CCSEAT_C_RESET"
    fi
    i=$CCSEAT__PICK_OFF
    while [ "$i" -le "$CCSEAT__PICK_END" ]; do
      [ "$i" -gt "$CCSEAT__PICK_OFF" ] && [ "$CCSEAT__PICK_COMPACT" = 0 ] && printf '\n'
      ccseat__pick_seat_lines "$i" "$sel" "$cols" "$cur"
      i=$((i + 1))
    done
    if [ "$CCSEAT_N" -eq 1 ] && [ $((lines - 3 - 3)) -ge 2 ]; then
      printf '\n%s%s%s\n' "$CCSEAT_C_FAINT" "$(ccseat_trunc "Add another account with: ccseat add" "$cols")" "$CCSEAT_C_RESET"
    fi
  )
  printf '\033[H\033[J%s' "$out"
}

# Background refreshes run detached (so none is left as a child of Claude
# Code after exec) and each leaves a marker file when it is done.
ccseat__pick_jobs_done() {
  local n
  for n in $CCSEAT__PICK_FETCH; do
    [ -f "$CCSEAT_CACHE_DIR/.pick-$n-$$" ] || return 1
  done
  return 0
}

ccseat__pick_jobs_clean() {
  local n
  for n in ${CCSEAT__PICK_FETCH:-}; do rm -f "$CCSEAT_CACHE_DIR/.pick-$n-$$" 2>/dev/null; done
  return 0
}

# Opens a seat chosen in the picker (or just added from it).
ccseat__pick_open() {
  local idx="$1" name dir email
  name=${CCSEAT_NAMES[idx]}
  dir=${CCSEAT_DIRS[idx]}
  [ "$(ccseat_config_get remember)" = on ] && ccseat_current_set "$name"
  email=$(ccseat_email "$dir" 2>/dev/null)
  if [ -n "$email" ]; then
    printf '%sOpening%s %s%s%s%s %s(%s)%s\n' "$CCSEAT_C_MID" "$CCSEAT_C_RESET" "$CCSEAT_C_BOLD" \
      "$(ccseat__seat_color_at "$idx")" "$name" "$CCSEAT_C_RESET" "$CCSEAT_C_FAINT" "$email" "$CCSEAT_C_RESET"
  else
    printf '%sOpening%s %s%s%s%s\n' "$CCSEAT_C_MID" "$CCSEAT_C_RESET" "$CCSEAT_C_BOLD" \
      "$(ccseat__seat_color_at "$idx")" "$name" "$CCSEAT_C_RESET"
  fi
  ccseat__login_if_needed "$name" "$dir"
  ccseat_exec_seat "$name" "$dir"
}

ccseat_cmd_pick() {
  local sel prev cur key rest rc moved=0 busy=0 chosen="" n fetch="" i t0 eof=0 draw ask=""
  case "${1:-}" in
    -h|--help) ccseat_help pick; return 0 ;;
    "") ;;
    *) ccseat_die_usage "pick takes no arguments" pick ;;
  esac
  ccseat_need_jq
  ccseat__registry_ensure
  if [ "$CCSEAT_N" -eq 0 ]; then
    ccseat_no_seats_hint
    if [ -t 0 ] && [ -t 1 ]; then
      printf '\n'
      if ! ccseat_confirm "Add an account now?" y; then
        return 130
      fi
      # shellcheck disable=SC2034 # read by ccseat_cmd_add in seats.sh
      CCSEAT__ADD_OPENS=1
      ccseat_cmd_add || return $?
      ccseat_colors_init 1
      i=$(ccseat_seat_index "$CCSEAT_REG_NAME") || return 1
      ccseat__pick_open "$i"
    fi
    return 0
  fi
  if ! [ -t 0 ] || ! [ -t 1 ]; then
    ccseat_cmd_list
    return $?
  fi

  ccseat_colors_init 1
  cur=$(ccseat_current_get)
  ccseat_rows_load 0
  sel=$(ccseat_rows_freest) || sel=$(ccseat_seat_index "$cur") || sel=0

  # Draw from the cache right away and refresh stale seats behind it.
  i=0
  while [ "$i" -lt "$CCSEAT_N" ]; do
    if [ "${CCSEAT_ROW_AUTH[i]}" = ok ] \
      && [ "$(ccseat_file_age "$(ccseat_usage_cache_path "${CCSEAT_NAMES[i]}")")" -ge "$CCSEAT_USAGE_TTL" ]; then
      fetch="$fetch ${CCSEAT_NAMES[i]}"
    fi
    i=$((i + 1))
  done
  CCSEAT__PICK_FETCH=$fetch
  if [ -n "$fetch" ] && ccseat_mkdir_private "$CCSEAT_CACHE_DIR"; then
    for n in $fetch; do
      ( { ccseat_usage_fetch "$n" 5; : > "$CCSEAT_CACHE_DIR/.pick-$n-$$"; sleep 30
          rm -f "$CCSEAT_CACHE_DIR/.pick-$n-$$"; } </dev/null >/dev/null 2>&1 & )
    done
    busy=1
  fi

  CCSEAT__PICK_OFF=0
  CCSEAT__PICK_COMPACT=0
  CCSEAT__PICK_RESIZED=0
  CCSEAT__PICK_STTY=$(stty -g 2>/dev/null)
  trap ccseat__pick_abort INT TERM HUP
  trap 'CCSEAT__PICK_RESIZED=1' WINCH
  printf '\033[?1049h\033[?25l'
  ccseat__pick_draw "$sel" "$busy" "$cur"
  # A seat that is out (at its limit) opens only after a y: "ask" holds the
  # seat whose question is on screen, and any other key goes back.
  while :; do
    key=""
    t0=$SECONDS
    IFS= read -rsn1 -t 1 key
    rc=$?
    draw=0
    if [ "$CCSEAT__PICK_RESIZED" = 1 ]; then
      CCSEAT__PICK_RESIZED=0
      draw=1
    fi
    # bash 3.2 returns 1 both on a timeout and at end of input; only an
    # answer that came back at once means the input is gone.
    if [ "$rc" -ne 0 ] && [ "$rc" -le 128 ] && [ "$SECONDS" -eq "$t0" ] && [ "$draw" = 0 ]; then
      eof=$((eof + 1))
      [ "$eof" -ge 3 ] && { chosen=""; break; }
      continue
    fi
    eof=0
    if [ "$rc" -ne 0 ]; then
      if [ "$busy" = 1 ] && ccseat__pick_jobs_done; then
        busy=0
        ccseat_rows_load 0
        if [ "$moved" = 0 ]; then sel=$(ccseat_rows_freest) || sel=$(ccseat_seat_index "$cur") || sel=0; fi
        draw=1
      fi
      [ "$draw" = 1 ] && ccseat__pick_draw "$sel" "$busy" "$cur" "$ask"
      continue
    fi
    if [ -n "$ask" ]; then
      case "$key" in
        y|Y) chosen=$ask; break ;;
        $'\033') rest=""; IFS= read -rsn2 -t 1 rest ;;
      esac
      ask=""
      ccseat__pick_draw "$sel" "$busy" "$cur"
      continue
    fi
    prev=$sel
    case "$key" in
      ""|$'\r'|$'\n')
        if ccseat_row_out "$sel"; then
          ask=$sel moved=1
          ccseat__pick_draw "$sel" "$busy" "$cur" "$ask"
          continue
        fi
        chosen=$sel; break ;;
      $'\033')
        rest=""
        IFS= read -rsn2 -t 1 rest
        case "$rest" in
          '[A'|'OA') [ "$sel" -gt 0 ] && sel=$((sel - 1)); moved=1 ;;
          '[B'|'OB') [ "$sel" -lt $((CCSEAT_N - 1)) ] && sel=$((sel + 1)); moved=1 ;;
          '[H'|'OH') sel=0; moved=1 ;;
          '[F'|'OF') sel=$((CCSEAT_N - 1)); moved=1 ;;
          '') chosen=""; break ;;
          *) ;;
        esac ;;
      k|K|p) [ "$sel" -gt 0 ] && sel=$((sel - 1)); moved=1 ;;
      j|J|n) [ "$sel" -lt $((CCSEAT_N - 1)) ] && sel=$((sel + 1)); moved=1 ;;
      g) sel=0; moved=1 ;;
      G) sel=$((CCSEAT_N - 1)); moved=1 ;;
      [1-9])
        if [ "$key" -le "$CCSEAT_N" ]; then
          sel=$((key - 1))
          if ccseat_row_out "$sel"; then
            ask=$sel moved=1
            ccseat__pick_draw "$sel" "$busy" "$cur" "$ask"
            continue
          fi
          chosen=$sel
          break
        fi ;;
      q|Q|$'\004') chosen=""; break ;;
      *) ;;
    esac
    # Only a change is drawn, so keys that do nothing never flicker.
    if [ "$sel" != "$prev" ] || [ "$draw" = 1 ]; then
      ccseat__pick_draw "$sel" "$busy" "$cur"
    fi
  done
  trap - INT TERM HUP WINCH
  ccseat__pick_restore
  ccseat__pick_jobs_clean
  [ -n "$chosen" ] || return 130
  ccseat__pick_open "$chosen"
}
