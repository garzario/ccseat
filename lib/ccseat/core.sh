# shellcheck shell=bash
# shellcheck disable=SC2034 # globals set here are read by the other library files
# ccseat core: paths, config, seat registry, palette, text layout, time
# formatting, messages, confirmations and the Trash helper.
#
# Public helpers other files rely on (keep their names and output stable):
#   ccseat_color <name>          escape code, or nothing when colors are off
#   ccseat_pad <text> <width>    left-aligns by characters, not bytes
#   ccseat_fmt_reset <epoch>     "6:20 PM", "tomorrow 9:00 AM", "Saturday 6:00 AM"
#   ccseat_seat_list             name<TAB>config_dir lines, in registry order
#   ccseat_seat_for_dir <dir>    registered name of a config dir (primary when empty)
#   ccseat_seat_color <name>     the seat's accent color escape

CCSEAT_VERSION="0.2.0"

CCSEAT_DEFAULT_SHARE="settings.json,CLAUDE.md,skills,agents,commands,rules,hooks,output-styles,plugins,projects,file-history,plans,todos,history.jsonl"
# Per-account state that is never linked between seats, whatever "share" says.
CCSEAT_NEVER_SHARE=".credentials.json credentials .claude.json .config.json sessions session-env statsig telemetry state cache shell-snapshots ide daemon tasks teams backups"
CCSEAT_CONFIG_KEYS="auto_switch limit_5h limit_weekly remember share colors statusline_width shortcut"
# Names the shortcut never takes: shell keywords and builtins of bash, zsh
# and fish that a function would hide, and ccseat's own two commands.
CCSEAT__SHORTCUT_TAKEN=" claude ccseat alias and autoload begin bg bind bindkey builtin case cd chdir command compdef complete contains count declare disown do done echo elif else emulate end esac eval exec exit export false fg fi fish_config for function functions hash history if in jobs kill let local noglob not or print printf pushd popd pwd read readonly return select set setopt shift source status string switch test then time trap true type typeset ulimit umask unalias unset unsetopt until wait whence where which while "
CCSEAT_TAB=$'\t'
CCSEAT_NL=$'\n'

# ---------- locale ----------

# Widths are counted by the shell, so it needs a UTF-8 character type.
ccseat__utf8_init() {
  local probe="●" loc
  [ "${#probe}" -eq 1 ] && return 0
  for loc in C.UTF-8 en_US.UTF-8 C.utf8 en_US.utf8; do
    if [ -n "${LC_ALL:-}" ]; then LC_ALL="$loc"; else LC_CTYPE="$loc"; fi
    [ "${#probe}" -eq 1 ] && return 0
  done
  return 1
}

# ---------- paths ----------

ccseat_strip_slash() {
  local p="${1:-}"
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  printf '%s' "$p"
}

# An XDG base dir only counts when it is absolute (XDG spec).
ccseat__xdg() {
  case "${1:-}" in
    /*) ccseat_strip_slash "$1" ;;
    *) printf '%s' "$2" ;;
  esac
}

ccseat_init_paths() {
  local home
  home=$(ccseat_strip_slash "${HOME:-}")
  if [ -z "$home" ]; then
    printf 'ccseat: HOME is not set\n' >&2
    exit 1
  fi
  CCSEAT_USER_HOME="$home"
  case "${CCSEAT_HOME:-}" in
    /*) CCSEAT_HOME=$(ccseat_strip_slash "$CCSEAT_HOME") ;;
    "") CCSEAT_HOME="$(ccseat__xdg "${XDG_CONFIG_HOME:-}" "$home/.config")/ccseat" ;;
    *) CCSEAT_HOME="$PWD/$(ccseat_strip_slash "$CCSEAT_HOME")" ;;
  esac
  CCSEAT_DATA_DIR="$(ccseat__xdg "${XDG_DATA_HOME:-}" "$home/.local/share")/ccseat"
  CCSEAT_SEATS_DIR="$CCSEAT_DATA_DIR/seats"
  CCSEAT_CACHE_DIR="$(ccseat__xdg "${XDG_CACHE_HOME:-}" "$home/.cache")/ccseat"
  CCSEAT_PRIMARY_DIR="$home/.claude"
  CCSEAT_REGISTRY="$CCSEAT_HOME/seats"
  CCSEAT_CURRENT_FILE="$CCSEAT_HOME/current"
  CCSEAT_CONFIG_FILE="$CCSEAT_HOME/config"
}

# Absolute, tidy path that keeps symlinks as typed: Claude Code keys the login
# of a config dir on the exact path string, so the logical path is what counts.
ccseat_abspath() {
  local p="${1:-}" parent base
  [ -n "$p" ] || return 1
  case "$p" in
    "~") p="$CCSEAT_USER_HOME" ;;
    \~/*) p="$CCSEAT_USER_HOME/${p#\~/}" ;;
  esac
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  if [ -d "$p" ]; then
    p=$(cd "$p" 2>/dev/null && pwd -L) || return 1
  else
    parent=$(dirname "$p")
    base=$(basename "$p")
    if [ -d "$parent" ]; then
      parent=$(cd "$parent" 2>/dev/null && pwd -L) || return 1
    fi
    p="$parent/$base"
  fi
  while :; do
    case "$p" in *//*) p="${p//\/\//\/}" ;; *) break ;; esac
  done
  ccseat_strip_slash "$p"
}

# "~/x" for paths under HOME, for friendlier messages.
ccseat_tilde() {
  case "${1:-}" in
    "$CCSEAT_USER_HOME") printf '~' ;;
    "$CCSEAT_USER_HOME"/*) printf '~%s' "${1#"$CCSEAT_USER_HOME"}" ;;
    *) printf '%s' "${1:-}" ;;
  esac
}

# mkdir -p that leaves new folders private.
ccseat_mkdir_private() {
  [ -d "$1" ] && return 0
  (umask 077 && mkdir -p "$1") 2>/dev/null
}

# Writes stdin to a file atomically (temp file in the same folder, then mv).
# Keeps the file private.
ccseat_write_file() {
  local f="$1" d tmp
  d=$(dirname "$f")
  ccseat_mkdir_private "$d" || return 1
  tmp=$(mktemp "$d/.ccseat.XXXXXX" 2>/dev/null) || return 1
  if cat > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$f"; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# Runs a command with "bash -x" tracing paused. A trace prints every command
# with its values, so the functions that hold a login in variables run
# through this and a trace pasted into a bug report never shows a token.
ccseat__untraced() {
  local rc
  case $- in
    *x*)
      set +x
      "$@"
      rc=$?
      set -x
      return "$rc" ;;
  esac
  "$@"
}

# ---------- platform ----------

ccseat_is_macos() {
  [ -z "${CCSEAT__OS:-}" ] && CCSEAT__OS=$(uname -s 2>/dev/null)
  [ "$CCSEAT__OS" = Darwin ]
}

ccseat__stat_init() {
  [ -n "${CCSEAT__STAT:-}" ] && return 0
  if stat -c %Y / >/dev/null 2>&1; then CCSEAT__STAT=gnu; else CCSEAT__STAT=bsd; fi
}

# Modification time of a file in epoch seconds, or nothing.
ccseat_mtime() {
  ccseat__stat_init
  if [ "$CCSEAT__STAT" = gnu ]; then stat -c %Y "$1" 2>/dev/null; else stat -f %m "$1" 2>/dev/null; fi
}

# Seconds since a file changed; 999999 when it does not exist.
ccseat_file_age() {
  local m
  m=$(ccseat_mtime "$1")
  case "$m" in ''|*[!0-9]*) printf '999999'; return ;; esac
  ccseat__now_init
  printf '%s' $(( CCSEAT_NOW - m ))
}

# ---------- config ----------

# Checks and normalizes a config value. Sets CCSEAT__NORM on success and
# CCSEAT__NORM_ERR on failure.
ccseat__config_norm() {
  local key="$1" val="$2" item out="" rest
  CCSEAT__NORM="" CCSEAT__NORM_ERR=""
  case "$key" in
    auto_switch|remember)
      case "$val" in
        on|yes|true|1|enable|enabled|On|ON) CCSEAT__NORM=on ;;
        off|no|false|0|disable|disabled|Off|OFF) CCSEAT__NORM=off ;;
        *) CCSEAT__NORM_ERR="$key takes on or off"; return 1 ;;
      esac ;;
    limit_5h|limit_weekly)
      val="${val%\%}"
      case "$val" in
        ''|*[!0-9]*) CCSEAT__NORM_ERR="$key takes a percentage from 1 to 100"; return 1 ;;
      esac
      val=$((10#$val))
      if [ "$val" -lt 1 ] || [ "$val" -gt 100 ]; then
        CCSEAT__NORM_ERR="$key takes a percentage from 1 to 100"
        return 1
      fi
      CCSEAT__NORM=$val ;;
    statusline_width)
      case "$val" in
        ''|*[!0-9]*) CCSEAT__NORM_ERR="$key takes a number of columns from 40 to 400"; return 1 ;;
      esac
      val=$((10#$val))
      if [ "$val" -lt 40 ] || [ "$val" -gt 400 ]; then
        CCSEAT__NORM_ERR="$key takes a number of columns from 40 to 400"
        return 1
      fi
      CCSEAT__NORM=$val ;;
    shortcut)
      case "$val" in
        off|Off|OFF|none|None|NONE) CCSEAT__NORM=off; return 0 ;;
      esac
      # The name goes into shell code, so the letters are spelled out:
      # ranges can match other characters in some locales.
      case "$val" in
        ''|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-]*|[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_]*)
          CCSEAT__NORM_ERR="shortcut takes a command name of letters, digits, dashes and underscores, or off"
          return 1 ;;
      esac
      if [ "${#val}" -gt 32 ]; then
        CCSEAT__NORM_ERR="shortcut takes a name of at most 32 characters"
        return 1
      fi
      case "$CCSEAT__SHORTCUT_TAKEN" in
        *" $val "*) CCSEAT__NORM_ERR="shortcut cannot be $val: that name belongs to the shell or to ccseat"; return 1 ;;
      esac
      case "$(type -t -- "$val" 2>/dev/null)" in
        keyword|builtin) CCSEAT__NORM_ERR="shortcut cannot be $val: that name belongs to the shell or to ccseat"; return 1 ;;
      esac
      CCSEAT__NORM=$val ;;
    colors)
      case "$val" in
        auto) CCSEAT__NORM=auto ;;
        always|on|yes) CCSEAT__NORM=always ;;
        never|off|no|none) CCSEAT__NORM=never ;;
        *) CCSEAT__NORM_ERR="colors takes auto, always or never"; return 1 ;;
      esac ;;
    share)
      [ "$val" = default ] && { CCSEAT__NORM=$CCSEAT_DEFAULT_SHARE; return 0; }
      rest=$(printf '%s' "$val" | tr ',' ' ')
      # No globbing: a "*" must be refused, not matched against this folder.
      set -f
      # shellcheck disable=SC2086 # one word per item
      set -- $rest
      set +f
      for item in "$@"; do
        case "$item" in
          .|..|*[!A-Za-z0-9._-]*|'')
            CCSEAT__NORM_ERR="share items are names inside the config folder, like skills or CLAUDE.md (not $item)"
            return 1 ;;
        esac
        if ccseat_never_shared "$item"; then
          CCSEAT__NORM_ERR="$item is private to each seat and cannot be shared"
          return 1
        fi
        case ",$out," in *",$item,"*) ;; *) out="$out${out:+,}$item" ;; esac
      done
      CCSEAT__NORM=$out ;;
    *) CCSEAT__NORM_ERR="unknown setting: $key"; return 1 ;;
  esac
  return 0
}

ccseat_never_shared() {
  case " $CCSEAT_NEVER_SHARE " in *" $1 "*) return 0 ;; esac
  return 1
}

ccseat_config_is_key() {
  case " $CCSEAT_CONFIG_KEYS " in *" ${1:-} "*) return 0 ;; esac
  return 1
}

ccseat_config_default() {
  case "${1:-}" in
    auto_switch|remember) printf 'on' ;;
    limit_5h) printf '95' ;;
    limit_weekly) printf '100' ;;
    share) printf '%s' "$CCSEAT_DEFAULT_SHARE" ;;
    colors) printf 'auto' ;;
    statusline_width) printf '80' ;;
    shortcut) printf 'cc' ;;
    *) return 1 ;;
  esac
}

# Reads the config file once into CCSEAT_CFG_<key>. Invalid lines are ignored,
# so a hand-edited typo never breaks the claude command.
ccseat_config_load() {
  local line k v
  # shellcheck disable=SC2034 # read indirectly through ccseat_config_get
  {
    CCSEAT_CFG_auto_switch=on CCSEAT_CFG_limit_5h=95 CCSEAT_CFG_limit_weekly=100
    CCSEAT_CFG_remember=on CCSEAT_CFG_share=$CCSEAT_DEFAULT_SHARE CCSEAT_CFG_colors=auto
    CCSEAT_CFG_statusline_width=80 CCSEAT_CFG_shortcut=cc
  }
  CCSEAT__CFG_SET=" "
  [ -f "$CCSEAT_CONFIG_FILE" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; *=*) ;; *) continue ;; esac
    k=${line%%=*}
    v=${line#*=}
    k="${k#"${k%%[![:space:]]*}"}"; k="${k%"${k##*[![:space:]]}"}"
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    ccseat_config_is_key "$k" || continue
    ccseat__config_norm "$k" "$v" || continue
    printf -v "CCSEAT_CFG_$k" '%s' "$CCSEAT__NORM"
    CCSEAT__CFG_SET="$CCSEAT__CFG_SET$k "
  done < "$CCSEAT_CONFIG_FILE"
}

ccseat_config_get() {
  local n="CCSEAT_CFG_${1:-}"
  ccseat_config_is_key "${1:-}" || return 1
  printf '%s' "${!n}"
}

# Stores a key (value "default" removes it). The value must be normalized.
ccseat_config_store() {
  local key="$1" val="$2" line k out="" found=0
  if [ -f "$CCSEAT_CONFIG_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      k=${line%%=*}
      k="${k#"${k%%[![:space:]]*}"}"; k="${k%"${k##*[![:space:]]}"}"
      if [ "$k" = "$key" ]; then
        [ "$found" -eq 0 ] && [ "$val" != default ] && out="$out$key=$val$CCSEAT_NL"
        found=1
        continue
      fi
      out="$out$line$CCSEAT_NL"
    done < "$CCSEAT_CONFIG_FILE"
  fi
  [ "$found" -eq 0 ] && [ "$val" != default ] && out="$out$key=$val$CCSEAT_NL"
  printf '%s' "$out" | ccseat_write_file "$CCSEAT_CONFIG_FILE"
}

# The share list as space-separated names, plus status line scripts that the
# primary settings.json runs from inside the primary folder.
ccseat_share_items() {
  local items extra
  items=$(printf '%s' "$(ccseat_config_get share)" | tr ',' ' ')
  extra=$(ccseat__statusline_files)
  printf '%s %s' "$items" "$extra"
}

ccseat__statusline_files() {
  local settings="$CCSEAT_PRIMARY_DIR/settings.json" cmd word item out=""
  [ -f "$settings" ] || return 0
  cmd=$(jq -r '.statusLine.command // empty' "$settings" 2>/dev/null) || return 0
  [ -n "$cmd" ] || return 0
  set -f
  # shellcheck disable=SC2086 # split into words, never globbed
  set -- $cmd
  set +f
  for word in "$@"; do
    word=${word//\"/}
    word=${word//\'/}
    case "$word" in
      */.claude/*) item=${word##*/.claude/} ;;
      *) continue ;;
    esac
    item=${item%%/*}
    case "$item" in ''|.|..|*[!A-Za-z0-9._-]*) continue ;; esac
    ccseat_never_shared "$item" && continue
    [ -e "$CCSEAT_PRIMARY_DIR/$item" ] || continue
    case " $out " in *" $item "*) ;; *) out="$out $item" ;; esac
  done
  printf '%s' "$out"
}

# ---------- colors ----------

# Decides whether output on a file descriptor gets colors: never with
# NO_COLOR (unless colors=always), only on a terminal in auto mode.
ccseat_colors_init() {
  local fd="${1:-1}" mode
  mode=$(ccseat_config_get colors)
  CCSEAT__COLOR_ON=0
  case "$mode" in
    never) ;;
    always) CCSEAT__COLOR_ON=1 ;;
    *)
      if [ -z "${NO_COLOR:-}" ] && [ -t "$fd" ] && [ "${TERM:-}" != dumb ]; then
        CCSEAT__COLOR_ON=1
      fi ;;
  esac
  ccseat__palette
}

# Colors for output that is not a terminal but is rendered as one (the status
# line). NO_COLOR and colors=never still win.
ccseat_colors_enable() {
  CCSEAT__COLOR_ON=1
  [ -n "${NO_COLOR:-}" ] && [ "$(ccseat_config_get colors)" != always ] && CCSEAT__COLOR_ON=0
  [ "$(ccseat_config_get colors)" = never ] && CCSEAT__COLOR_ON=0
  ccseat__palette
}

ccseat_colors_disable() {
  CCSEAT__COLOR_ON=0
  ccseat__palette
}

# 24-bit color everywhere except Terminal.app before truecolor support, which
# gets the nearest 256-color codes.
ccseat__rgb() {
  if [ "${CCSEAT__TRUECOLOR:-1}" = 1 ]; then
    printf '\033[38;2;%s;%s;%sm' "$1" "$2" "$3"
  else
    printf '\033[38;5;%sm' "$4"
  fi
}

ccseat__palette() {
  CCSEAT__TRUECOLOR=1
  case "${COLORTERM:-}" in
    truecolor|24bit) ;;
    *) [ "${TERM_PROGRAM:-}" = Apple_Terminal ] && CCSEAT__TRUECOLOR=0 ;;
  esac
  if [ "${CCSEAT__COLOR_ON:-0}" = 1 ]; then
    CCSEAT_C_RESET=$'\033[0m'
    CCSEAT_C_BOLD=$'\033[1m'
    # Main text uses the terminal's own foreground so it reads on light themes.
    CCSEAT_C_TEXT=$'\033[39m'
    CCSEAT_C_WHITE=$(ccseat__rgb 250 249 245 231)
    CCSEAT_C_MID=$(ccseat__rgb 176 174 165 145)
    CCSEAT_C_FAINT=$(ccseat__rgb 110 108 102 242)
    CCSEAT_C_ORANGE=$(ccseat__rgb 217 119 87 173)
    CCSEAT_C_KRAFT=$(ccseat__rgb 212 162 127 180)
    CCSEAT_C_BLUE=$(ccseat__rgb 106 155 204 68)
    CCSEAT_C_GREEN=$(ccseat__rgb 120 140 93 101)
    CCSEAT_C_PURPLE=$(ccseat__rgb 167 139 250 141)
    # Red is kept for a seat that is out (at its limit): LIMIT REACHED.
    CCSEAT_C_RED=$(ccseat__rgb 229 83 75 167)
  else
    CCSEAT_C_RESET="" CCSEAT_C_BOLD="" CCSEAT_C_TEXT="" CCSEAT_C_WHITE="" CCSEAT_C_MID=""
    CCSEAT_C_FAINT="" CCSEAT_C_ORANGE="" CCSEAT_C_KRAFT="" CCSEAT_C_BLUE="" CCSEAT_C_GREEN=""
    CCSEAT_C_PURPLE="" CCSEAT_C_RED=""
  fi
}

ccseat_color() {
  [ "${CCSEAT__COLOR_ON:-0}" = 1 ] || return 0
  [ -n "${CCSEAT_C_RESET:-}" ] || ccseat__palette
  case "${1:-}" in
    reset) printf '%s' "$CCSEAT_C_RESET" ;;
    bold) printf '%s' "$CCSEAT_C_BOLD" ;;
    light|text) printf '%s' "$CCSEAT_C_TEXT" ;;
    white) printf '%s' "$CCSEAT_C_WHITE" ;;
    mid|gray|grey|label) printf '%s' "$CCSEAT_C_MID" ;;
    faint|dim) printf '%s' "$CCSEAT_C_FAINT" ;;
    orange|accent|alert) printf '%s' "$CCSEAT_C_ORANGE" ;;
    kraft|warn|warning) printf '%s' "$CCSEAT_C_KRAFT" ;;
    blue|progress) printf '%s' "$CCSEAT_C_BLUE" ;;
    green|ok) printf '%s' "$CCSEAT_C_GREEN" ;;
    purple|ultracode) printf '%s' "$CCSEAT_C_PURPLE" ;;
    red|out) printf '%s' "$CCSEAT_C_RED" ;;
  esac
  return 0
}

# Accent of the seat at a 0-based registry position: orange, blue, green,
# kraft, purple, then around again.
ccseat__seat_color_at() {
  case $(( ${1:-0} % 5 )) in
    0) printf '%s' "$CCSEAT_C_ORANGE" ;;
    1) printf '%s' "$CCSEAT_C_BLUE" ;;
    2) printf '%s' "$CCSEAT_C_GREEN" ;;
    3) printf '%s' "$CCSEAT_C_KRAFT" ;;
    4) printf '%s' "$CCSEAT_C_PURPLE" ;;
  esac
}

ccseat_seat_color() {
  local i
  [ "${CCSEAT__COLOR_ON:-0}" = 1 ] || return 0
  [ -n "${CCSEAT_C_RESET:-}" ] || ccseat__palette
  i=$(ccseat_seat_index "${1:-}") || i=0
  ccseat__seat_color_at "$i"
}

# Color for a usage percentage: plain below 60, kraft from 60, orange from 85
# or at the seat's limit.
ccseat_pct_color() {
  local p="${1:-}" limit="${2:-85}"
  case "$p" in ''|-|*[!0-9]*) printf '%s' "$CCSEAT_C_FAINT"; return ;; esac
  [ "$limit" -gt 85 ] && limit=85
  if [ "$p" -ge "$limit" ]; then printf '%s' "$CCSEAT_C_ORANGE"
  elif [ "$p" -ge 60 ]; then printf '%s' "$CCSEAT_C_KRAFT"
  else printf '%s' "$CCSEAT_C_TEXT"; fi
}

# Ten dots, filled by percentage. $2=1 draws the whole bar faint; $3 is a
# color for the filled dots that wins over both (red for a window at its
# limit).
ccseat_bar() {
  local p="${1:-}" dim="${2:-0}" f=0 k on="" off="" c="${3:-}"
  case "$p" in ''|-|*[!0-9]*) p=0 ;; esac
  [ "$p" -gt 100 ] && p=100
  f=$(( (p * 10 + 50) / 100 ))
  [ "$p" -gt 0 ] && [ "$f" -eq 0 ] && f=1
  k=0
  while [ "$k" -lt 10 ]; do
    if [ "$k" -lt "$f" ]; then on="${on}●"; else off="${off}○"; fi
    k=$((k + 1))
  done
  if [ -n "$c" ]; then :
  elif [ "$dim" = 1 ]; then c=$CCSEAT_C_FAINT; else c=$(ccseat_pct_color "$p"); fi
  printf '%s%s%s%s%s' "$c" "$on" "$CCSEAT_C_FAINT" "$off" "$CCSEAT_C_RESET"
}

# ---------- text layout ----------

# Left-aligns text to a width in characters (printf pads by bytes).
ccseat_pad() {
  local s="${1:-}" w="${2:-0}" n
  n=${#s}
  printf '%s' "$s"
  [ "$n" -lt "$w" ] && printf '%*s' $(( w - n )) ''
  return 0
}

# Right-aligns text to a width in characters.
ccseat_rpad() {
  local s="${1:-}" w="${2:-0}" n
  n=${#s}
  [ "$n" -lt "$w" ] && printf '%*s' $(( w - n )) ''
  printf '%s' "$s"
}

# Cuts text to a width in characters, ending in "…" when cut.
ccseat_trunc() {
  local s="${1:-}" w="${2:-0}"
  if [ "${#s}" -le "$w" ]; then printf '%s' "$s"; return; fi
  [ "$w" -le 1 ] && { printf '%s' "${s:0:$w}"; return; }
  printf '%s…' "${s:0:$((w - 1))}"
}

# Sets CCSEAT__TERM_COLS and CCSEAT__TERM_ROWS. COLUMNS and LINES win when
# they are set (a forced width, or the tests); otherwise the size comes from
# the controlling terminal. Shells do not export COLUMNS or LINES, and tput
# inside $(...) with stderr elsewhere cannot see the terminal, so stty reads
# /dev/tty directly. 80x24 when nothing answers.
ccseat__term_size() {
  local c="${COLUMNS:-}" r="${LINES:-}" s="" tc="" tr=""
  case "$c" in ''|*[!0-9]*|0) c="" ;; esac
  case "$r" in ''|*[!0-9]*|0) r="" ;; esac
  if [ -z "$c" ] || [ -z "$r" ]; then
    s=$( { stty size </dev/tty; } 2>/dev/null )
    case "$s" in
      *[0-9]' '[0-9]*) tr=${s%% *}; tc=${s##* } ;;
    esac
    case "$tc" in ''|*[!0-9]*|0) tc=$( { tput cols 2>/dev/tty; } 2>/dev/null ) ;; esac
    case "$tr" in ''|*[!0-9]*|0) tr=$( { tput lines 2>/dev/tty; } 2>/dev/null ) ;; esac
    [ -n "$c" ] || c=$tc
    [ -n "$r" ] || r=$tr
  fi
  case "$c" in ''|*[!0-9]*|0) c=80 ;; esac
  case "$r" in ''|*[!0-9]*|0) r=24 ;; esac
  CCSEAT__TERM_COLS=$c CCSEAT__TERM_ROWS=$r
}

ccseat_term_cols() {
  ccseat__term_size
  printf '%s' "$CCSEAT__TERM_COLS"
}

ccseat_term_lines() {
  ccseat__term_size
  printf '%s' "$CCSEAT__TERM_ROWS"
}

# ---------- time ----------

ccseat__date_init() {
  [ -n "${CCSEAT__DATE:-}" ] && return 0
  if date -d @0 +%s >/dev/null 2>&1; then CCSEAT__DATE=gnu; else CCSEAT__DATE=bsd; fi
}

# date(1) output for an epoch in the local zone, always in English.
ccseat_date_at() {
  ccseat__date_init
  if [ "$CCSEAT__DATE" = gnu ]; then
    LC_ALL=C date -d "@$1" "+$2" 2>/dev/null
  else
    LC_ALL=C date -r "$1" "+$2" 2>/dev/null
  fi
}

# Sets CCSEAT_NOW, today's and tomorrow's dates and the epoch of today's local
# midnight, once per run.
ccseat__now_init() {
  local out h m s
  [ -n "${CCSEAT__TODAY:-}" ] && return 0
  out=$(LC_ALL=C date '+%s %Y%m%d %H %M %S')
  read -r CCSEAT_NOW CCSEAT__TODAY h m s <<< "$out"
  CCSEAT__DAY_START=$(( CCSEAT_NOW - 10#$h * 3600 - 10#$m * 60 - 10#$s ))
  CCSEAT__TOMORROW=$(ccseat_date_at $(( CCSEAT__DAY_START + 36 * 3600 )) '%Y%m%d')
}

ccseat_now() {
  ccseat__now_init
  printf '%s' "$CCSEAT_NOW"
}

# "6:20 PM" today, "tomorrow 9:00 AM", "Saturday 6:00 AM" within a week,
# else "Oct 3 6:00 AM". Rounded to the nearest minute, because the API
# reports 21:59:59.99 for a 10:00 PM reset.
ccseat_fmt_reset() {
  local e="${1:-}" out ymd wd hm md rest
  case "$e" in ''|-|*[!0-9]*) printf -- '-'; return 0 ;; esac
  ccseat__now_init
  e=$(( (e + 30) / 60 * 60 ))
  out=$(ccseat_date_at "$e" '%Y%m%d|%A|%l:%M %p|%b %e')
  [ -n "$out" ] || { printf -- '-'; return 0; }
  ymd=${out%%|*}; rest=${out#*|}
  wd=${rest%%|*}; rest=${rest#*|}
  hm=${rest%%|*}; md=${rest#*|}
  hm="${hm#"${hm%%[! ]*}"}"
  md="${md//  / }"
  if [ "$ymd" = "$CCSEAT__TODAY" ]; then
    printf '%s' "$hm"
  elif [ "$ymd" = "$CCSEAT__TOMORROW" ]; then
    printf 'tomorrow %s' "$hm"
  elif [ "$e" -gt "$CCSEAT_NOW" ] && [ $(( e - CCSEAT__DAY_START )) -lt $(( 7 * 86400 )) ]; then
    printf '%s %s' "$wd" "$hm"
  else
    printf '%s %s' "$md" "$hm"
  fi
}

# "just now", "3 min ago", "2 hours ago", "4 days ago".
ccseat_fmt_age() {
  local s="${1:-0}" n
  case "$s" in ''|*[!0-9]*) s=0 ;; esac
  if [ "$s" -lt 60 ]; then printf 'just now'
  elif [ "$s" -lt 3600 ]; then printf '%s min ago' $(( s / 60 ))
  elif [ "$s" -lt 86400 ]; then
    n=$(( s / 3600 ))
    if [ "$n" -eq 1 ]; then printf '1 hour ago'; else printf '%s hours ago' "$n"; fi
  else
    n=$(( s / 86400 ))
    if [ "$n" -eq 1 ]; then printf '1 day ago'; else printf '%s days ago' "$n"; fi
  fi
}

# ---------- messages ----------

ccseat__err_colors() {
  if [ -z "${CCSEAT__E_SET:-}" ]; then
    CCSEAT__E_SET=1
    CCSEAT__E_ACC="" CCSEAT__E_R="" CCSEAT__E_DIM=""
    if [ -t 2 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ] \
      && [ "$(ccseat_config_get colors 2>/dev/null)" != never ]; then
      CCSEAT__E_ACC=$'\033[38;2;217;119;87m' CCSEAT__E_R=$'\033[0m' CCSEAT__E_DIM=$'\033[38;2;176;174;165m'
    fi
  fi
}

# "ccseat: message" on stderr, then indented hint lines.
ccseat_err() {
  local l
  ccseat__err_colors
  printf '%sccseat:%s %s\n' "$CCSEAT__E_ACC" "$CCSEAT__E_R" "${1:-}" >&2
  shift
  for l in "$@"; do printf '  %s%s%s\n' "$CCSEAT__E_DIM" "$l" "$CCSEAT__E_R" >&2; done
  return 0
}

ccseat_die() {
  ccseat_err "$@"
  exit 1
}

# Usage errors exit 2 and point at the command's help.
ccseat_die_usage() {
  local msg="$1" cmd="${2:-}"
  if [ -n "$cmd" ]; then
    ccseat_err "$msg" "Run: ccseat help $cmd"
  else
    ccseat_err "$msg" "Run: ccseat help"
  fi
  exit 2
}

# Like ccseat_err, for information: the "ccseat:" prefix is gray, since
# orange is kept for alerts.
ccseat_note() {
  local l
  ccseat__err_colors
  printf '%sccseat:%s %s\n' "$CCSEAT__E_DIM" "$CCSEAT__E_R" "${1:-}" >&2
  shift
  for l in "$@"; do printf '  %s%s%s\n' "$CCSEAT__E_DIM" "$l" "$CCSEAT__E_R" >&2; done
  return 0
}

# ---------- confirmations ----------

# Asks a yes/no question on the terminal. Returns 0 for yes, 1 for no and 2
# when there is no terminal to ask on. CCSEAT_YES=1 answers yes.
ccseat_confirm() {
  local q="$1" def="${2:-n}" ans prompt
  case "${CCSEAT_YES:-}" in 1|yes|true) return 0 ;; esac
  if ! [ -t 0 ] || ! [ -t 2 ]; then return 2; fi
  if [ "$def" = y ]; then prompt="[Y/n]"; else prompt="[y/N]"; fi
  printf '%s %s ' "$q" "$prompt" >&2
  IFS= read -r ans || { printf '\n' >&2; return 1; }
  case "$ans" in
    y|Y|yes|Yes|YES) return 0 ;;
    '') [ "$def" = y ] && return 0; return 1 ;;
    *) return 1 ;;
  esac
}

# ---------- Trash ----------

# Real home folder of the user, even when HOME points elsewhere.
ccseat__real_home() {
  local u h
  u=$(id -un 2>/dev/null) || return 1
  case "$u" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  h=$(eval "printf '%s' ~$u" 2>/dev/null)
  case "$h" in /*) ccseat_strip_slash "$h" ;; *) return 1 ;; esac
}

ccseat__unique_dest() {
  local dir="$1" base="$2" dest n=2 stamp
  dest="$dir/$base"
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    stamp=$(LC_ALL=C date +%Y%m%d-%H%M%S)
    dest="$dir/$base $stamp"
    while [ -e "$dest" ] || [ -L "$dest" ]; do
      dest="$dir/$base $stamp-$n"
      n=$((n + 1))
    done
  fi
  printf '%s' "$dest"
}

# Moves a path to the Trash (never deletes). Sets CCSEAT_TRASHED_TO to a
# description of where it went.
ccseat_trash() {
  local p t base dest dir info real_home
  p=$(ccseat_strip_slash "${1:-}")
  CCSEAT_TRASHED_TO=""
  [ -e "$p" ] || [ -L "$p" ] || return 0
  case "$p" in
    /*) ;;
    *) ccseat_err "refusing to move a relative path to the Trash: $p"; return 1 ;;
  esac
  case "$p" in
    /|"$CCSEAT_USER_HOME"|"$CCSEAT_PRIMARY_DIR")
      ccseat_err "refusing to move $p to the Trash"
      return 1 ;;
  esac
  case "$CCSEAT_USER_HOME/" in
    "$p/"*) ccseat_err "refusing to move $p to the Trash: it holds your home folder"; return 1 ;;
  esac
  base=$(basename "$p")
  # A hidden folder would be invisible in the Trash.
  case "$base" in .?*) base=${base#.} ;; esac

  # A Trash folder ccseat has to create is private: the names of seat
  # folders are the start of account emails.
  if [ -n "${CCSEAT_TRASH_DIR:-}" ]; then
    dir=$(ccseat_strip_slash "$CCSEAT_TRASH_DIR")
    ccseat_mkdir_private "$dir" || return 1
    dest=$(ccseat__unique_dest "$dir" "$base")
    mv "$p" "$dest" || return 1
    CCSEAT_TRASHED_TO=$(ccseat_tilde "$dir")
    return 0
  fi

  if ccseat_is_macos; then
    t=$(type -P trash 2>/dev/null)
    real_home=$(ccseat__real_home 2>/dev/null)
    # The system trash command always uses the real Trash, so it is only
    # used when HOME is the real home folder (never in a sandbox HOME).
    if [ -n "$t" ] && { [ "$t" != /usr/bin/trash ] || [ "$real_home" = "$CCSEAT_USER_HOME" ]; }; then
      if "$t" "$p" >/dev/null 2>&1 && ! [ -e "$p" ] && ! [ -L "$p" ]; then
        CCSEAT_TRASHED_TO="the Trash"
        return 0
      fi
    fi
    dir="$CCSEAT_USER_HOME/.Trash"
    ccseat_mkdir_private "$dir" || return 1
    dest=$(ccseat__unique_dest "$dir" "$base")
    mv "$p" "$dest" || return 1
    CCSEAT_TRASHED_TO="the Trash"
    return 0
  fi

  # freedesktop.org Trash, so file managers can restore it.
  dir="$(ccseat__xdg "${XDG_DATA_HOME:-}" "$CCSEAT_USER_HOME/.local/share")/Trash"
  { ccseat_mkdir_private "$dir/files" && ccseat_mkdir_private "$dir/info"; } || return 1
  dest=$(ccseat__unique_dest "$dir/files" "$base")
  info="$dir/info/$(basename "$dest").trashinfo"
  printf '[Trash Info]\nPath=%s\nDeletionDate=%s\n' "$p" "$(date +%Y-%m-%dT%H:%M:%S)" > "$info" 2>/dev/null
  if ! mv "$p" "$dest"; then
    rm -f "$info" 2>/dev/null
    return 1
  fi
  CCSEAT_TRASHED_TO="the Trash"
  return 0
}

# ---------- seat registry ----------

# Loads the registry into CCSEAT_NAMES and CCSEAT_DIRS (CCSEAT_N entries).
ccseat_registry_load() {
  local line n d
  CCSEAT_N=0
  CCSEAT_NAMES=()
  CCSEAT_DIRS=()
  CCSEAT__REG_LOADED=1
  [ -f "$CCSEAT_REGISTRY" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; *"$CCSEAT_TAB"*) ;; *) continue ;; esac
    n=${line%%"$CCSEAT_TAB"*}
    d=${line#*"$CCSEAT_TAB"}
    d=${d%%"$CCSEAT_TAB"*}
    { [ -n "$n" ] && [ -n "$d" ]; } || continue
    # A hand-edited line is used only when ccseat could have written it:
    # names end up in file names and in tab completion, which the shell
    # expands, and folders must not depend on the current folder.
    ccseat__registry_name_ok "$n" || continue
    case "$d" in /*) ;; *) continue ;; esac
    case "$d" in *[[:cntrl:]]*) continue ;; esac
    ccseat__index_of_name "$n" >/dev/null && continue
    CCSEAT_NAMES[CCSEAT_N]=$n
    CCSEAT_DIRS[CCSEAT_N]=$(ccseat_strip_slash "$d")
    CCSEAT_N=$((CCSEAT_N + 1))
  done < "$CCSEAT_REGISTRY"
}

ccseat__registry_ensure() {
  [ "${CCSEAT__REG_LOADED:-0}" = 1 ] || ccseat_registry_load
}

# Seat names in the seats file: letters, digits, dots, dashes and
# underscores, starting with a letter or a digit (ccseat itself writes them
# lowercase). No quotes, spaces, "$(" or "/". Spelled out instead of ranges,
# which some locales stretch to other characters.
ccseat__registry_name_ok() {
  case "${1:-}" in
    ''|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-]*) return 1 ;;
    [!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789]*) return 1 ;;
  esac
  return 0
}

ccseat_registry_save() {
  local i=0 out=""
  while [ "$i" -lt "$CCSEAT_N" ]; do
    out="$out${CCSEAT_NAMES[i]}$CCSEAT_TAB${CCSEAT_DIRS[i]}$CCSEAT_NL"
    i=$((i + 1))
  done
  ccseat_mkdir_private "$CCSEAT_HOME" || { ccseat_err "cannot create $CCSEAT_HOME"; return 1; }
  printf '%s' "$out" | ccseat_write_file "$CCSEAT_REGISTRY"
}

# Changes to the seat list happen under a short lock, on a fresh read of the
# file, so two ccseat commands (two "ccseat add" logins, say) never save over
# each other. The lock is only held while saving; one older than 5 seconds
# was left by a killed process.
ccseat__registry_lock() {
  local lock="$CCSEAT_HOME/.seats.lock" n=0 m now
  ccseat_mkdir_private "$CCSEAT_HOME" || return 1
  while ! mkdir "$lock" 2>/dev/null; do
    n=$((n + 1))
    if [ $((n % 20)) -eq 0 ]; then
      m=$(ccseat_mtime "$lock")
      now=$(date +%s)
      case "$m" in ''|*[!0-9]*) m=0 ;; esac
      if [ $((now - m)) -gt 5 ] || [ "$n" -ge 200 ]; then
        rmdir "$lock" 2>/dev/null
        continue
      fi
    fi
    sleep 0.05
  done
  return 0
}

ccseat__registry_unlock() {
  rmdir "$CCSEAT_HOME/.seats.lock" 2>/dev/null
  return 0
}

# Registers a seat. When the folder is already registered (by a command that
# ran at the same time) nothing is added; a name taken meanwhile gets a
# suffix. Sets CCSEAT_REG_NAME to the name the seat ends up with.
ccseat_registry_add() {
  local name="$1" dir="$2" i rc
  CCSEAT_REG_NAME=$name
  ccseat__registry_lock || return 1
  ccseat_registry_load
  if i=$(ccseat__index_of_dir "$dir"); then
    CCSEAT_REG_NAME=${CCSEAT_NAMES[i]}
    ccseat__registry_unlock
    return 0
  fi
  ccseat__index_of_name "$name" >/dev/null && name=$(ccseat_unique_name "$name")
  CCSEAT_REG_NAME=$name
  CCSEAT_NAMES[CCSEAT_N]=$name
  CCSEAT_DIRS[CCSEAT_N]=$dir
  CCSEAT_N=$((CCSEAT_N + 1))
  ccseat_registry_save
  rc=$?
  ccseat__registry_unlock
  return "$rc"
}

ccseat_registry_remove() {
  local i=0 j=0 names=() dirs=() rc
  ccseat__registry_lock || return 1
  ccseat_registry_load
  while [ "$i" -lt "$CCSEAT_N" ]; do
    if [ "${CCSEAT_NAMES[i]}" != "$1" ]; then
      names[j]=${CCSEAT_NAMES[i]}
      dirs[j]=${CCSEAT_DIRS[i]}
      j=$((j + 1))
    fi
    i=$((i + 1))
  done
  CCSEAT_N=$j
  CCSEAT_NAMES=()
  CCSEAT_DIRS=()
  i=0
  while [ "$i" -lt "$j" ]; do
    CCSEAT_NAMES[i]=${names[i]}
    CCSEAT_DIRS[i]=${dirs[i]}
    i=$((i + 1))
  done
  ccseat_registry_save
  rc=$?
  ccseat__registry_unlock
  return "$rc"
}

# Returns 1 when the seat is gone and 2 when the new name was taken meanwhile.
ccseat_registry_rename() {
  local i rc
  ccseat__registry_lock || return 1
  ccseat_registry_load
  if ! i=$(ccseat__index_of_name "$1"); then
    ccseat__registry_unlock
    return 1
  fi
  if ccseat__index_of_name "$2" >/dev/null; then
    ccseat__registry_unlock
    return 2
  fi
  CCSEAT_NAMES[i]=$2
  ccseat_registry_save
  rc=$?
  ccseat__registry_unlock
  return "$rc"
}

ccseat__index_of_name() {
  local i=0
  while [ "$i" -lt "${CCSEAT_N:-0}" ]; do
    if [ "${CCSEAT_NAMES[i]}" = "$1" ]; then printf '%s' "$i"; return 0; fi
    i=$((i + 1))
  done
  return 1
}

ccseat__index_of_dir() {
  local i=0
  while [ "$i" -lt "${CCSEAT_N:-0}" ]; do
    if [ "${CCSEAT_DIRS[i]}" = "$1" ]; then printf '%s' "$i"; return 0; fi
    i=$((i + 1))
  done
  return 1
}

# 0-based registry position of a seat name.
ccseat_seat_index() {
  ccseat__registry_ensure
  ccseat__index_of_name "${1:-}"
}

ccseat_seat_list() {
  local i=0
  ccseat__registry_ensure
  while [ "$i" -lt "$CCSEAT_N" ]; do
    printf '%s\t%s\n' "${CCSEAT_NAMES[i]}" "${CCSEAT_DIRS[i]}"
    i=$((i + 1))
  done
}

ccseat_seat_dir() {
  local i
  ccseat__registry_ensure
  i=$(ccseat__index_of_name "${1:-}") || return 1
  printf '%s' "${CCSEAT_DIRS[i]}"
}

ccseat_is_primary_dir() {
  [ "$(ccseat_strip_slash "${1:-}")" = "$CCSEAT_PRIMARY_DIR" ]
}

ccseat_is_primary() {
  local d
  d=$(ccseat_seat_dir "${1:-}") || return 1
  [ "$d" = "$CCSEAT_PRIMARY_DIR" ]
}

# The folder with every symlink resolved (for a missing path: its resolved
# parent plus the last name). Only for comparing places, never for launching:
# Claude Code keys a login on the path exactly as given.
ccseat_physical() {
  local p d
  p=$(ccseat_strip_slash "${1:-}")
  [ -n "$p" ] || return 1
  if [ -d "$p" ] && d=$(cd -P "$p" 2>/dev/null && pwd -P); then
    printf '%s' "$d"
    return 0
  fi
  d=$(dirname "$p")
  if [ -d "$d" ] && d=$(cd -P "$d" 2>/dev/null && pwd -P); then
    printf '%s/%s' "${d%/}" "$(basename "$p")"
    return 0
  fi
  printf '%s' "$p"
}

# True when a folder is ~/.claude itself, also through a symlink.
ccseat_is_primary_place() {
  local d
  d=$(ccseat_strip_slash "${1:-}")
  [ "$d" = "$CCSEAT_PRIMARY_DIR" ] && return 0
  [ -d "$d" ] && [ -d "$CCSEAT_PRIMARY_DIR" ] && [ "$d" -ef "$CCSEAT_PRIMARY_DIR" ]
}

# True when $1 is the folder $2 or inside it, following symlinks.
ccseat_path_within() {
  local inner outer
  inner=$(ccseat_physical "$1") || return 1
  outer=$(ccseat_physical "$2") || return 1
  case "$inner/" in "${outer%/}/"*) return 0 ;; esac
  return 1
}

# Name of the primary seat, if it is registered.
ccseat_primary_name() {
  local i
  ccseat__registry_ensure
  i=$(ccseat__index_of_dir "$CCSEAT_PRIMARY_DIR") || return 1
  printf '%s' "${CCSEAT_NAMES[i]}"
}

# Registered name of a config dir; an empty dir means the primary (Claude
# Code without CLAUDE_CONFIG_DIR). Prints nothing for unknown dirs.
ccseat_seat_for_dir() {
  local d="${1:-}" i
  ccseat__registry_ensure
  if [ -z "$d" ]; then
    d=$CCSEAT_PRIMARY_DIR
  else
    d=$(ccseat_strip_slash "$d")
    case "$d" in /*) ;; *) d=$(ccseat_abspath "$d") || return 1 ;; esac
  fi
  if i=$(ccseat__index_of_dir "$d"); then
    printf '%s' "${CCSEAT_NAMES[i]}"
    return 0
  fi
  return 1
}

# ---------- names ----------

# A seat name: lowercase letters, digits, dot, dash and underscore, starting
# with a letter or digit, not only digits (numbers pick seats by position).
ccseat_valid_name() {
  local n="${1:-}"
  [ -n "$n" ] || return 1
  [ "${#n}" -le 40 ] || return 1
  case "$n" in
    *[!a-z0-9._-]*) return 1 ;;
    [!a-z0-9]*) return 1 ;;
    *[!0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

ccseat_name_problem() {
  local n="${1:-}"
  if [ -z "$n" ]; then printf 'a seat name cannot be empty'
  elif [ "${#n}" -gt 40 ]; then printf 'seat names are at most 40 characters'
  else
    case "$n" in
      *[!a-z0-9._-]*) printf 'seat names use lowercase letters, digits, dots, dashes and underscores (%s has other characters)' "$n" ;;
      [!a-z0-9]*) printf 'seat names start with a letter or a digit' ;;
      *[!0-9]*) printf 'invalid name' ;;
      *) printf 'a seat name cannot be only digits, because numbers pick seats by position' ;;
    esac
  fi
}

# Turns an email or any label into a valid seat name: the part before "@",
# lowercased, other characters as dashes.
ccseat_name_from_email() {
  local e="${1:-}" n
  n=${e%%@*}
  n=$(printf '%s' "$n" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-' | tr -s '-')
  while :; do
    case "$n" in
      [-._]*) n=${n#?} ;;
      *[-._]) n=${n%?} ;;
      *) break ;;
    esac
  done
  n=${n:0:40}
  n=${n%-}
  [ -n "$n" ] || n=seat
  case "$n" in *[!0-9]*) ;; *) n="seat-$n" ;; esac
  printf '%s' "$n"
}

# base, base-2, base-3... whichever is free.
ccseat_unique_name() {
  local base="$1" n=2 cand
  ccseat__registry_ensure
  cand=$base
  while ccseat__index_of_name "$cand" >/dev/null; do
    cand="$base-$n"
    n=$((n + 1))
  done
  printf '%s' "$cand"
}

# ---------- current seat ----------

# The current seat: the stored one when it still exists, else the primary,
# else the first seat. Prints nothing (status 1) without seats.
ccseat_current_get() {
  local c=""
  ccseat__registry_ensure
  [ "$CCSEAT_N" -gt 0 ] || return 1
  if [ -f "$CCSEAT_CURRENT_FILE" ]; then
    IFS= read -r c < "$CCSEAT_CURRENT_FILE" || true
  fi
  if [ -n "$c" ] && ccseat__index_of_name "$c" >/dev/null; then
    printf '%s' "$c"
    return 0
  fi
  if c=$(ccseat_primary_name); then printf '%s' "$c"; return 0; fi
  printf '%s' "${CCSEAT_NAMES[0]}"
}

ccseat_current_set() {
  ccseat_mkdir_private "$CCSEAT_HOME" || return 1
  printf '%s\n' "$1" | ccseat_write_file "$CCSEAT_CURRENT_FILE"
}

# ---------- seat references ----------

# Resolves what the user typed: a name, a 1-based number from "ccseat list",
# an email, a config folder or a unique prefix. Sets CCSEAT_R_NAME,
# CCSEAT_R_DIR and CCSEAT_R_INDEX (0-based), or prints why not and returns 1.
ccseat_resolve_seat() {
  local ref="${1:-}" low i hits="" nhits=0 d e
  ccseat__registry_ensure
  CCSEAT_R_NAME="" CCSEAT_R_DIR="" CCSEAT_R_INDEX=""
  if [ "$CCSEAT_N" -eq 0 ]; then
    ccseat_err "there are no seats yet" "Add one with: ccseat add"
    return 1
  fi
  if [ -z "$ref" ]; then
    ccseat_err "which seat? Seats: $(ccseat__names_joined)"
    return 1
  fi
  if i=$(ccseat__index_of_name "$ref"); then
    ccseat__resolved "$i"
    return 0
  fi
  low=$(printf '%s' "$ref" | tr '[:upper:]' '[:lower:]')
  if i=$(ccseat__index_of_name "$low"); then
    ccseat__resolved "$i"
    return 0
  fi
  case "$ref" in
    *[!0-9]*) ;;
    *)
      i=$((10#$ref))
      if [ "$i" -ge 1 ] && [ "$i" -le "$CCSEAT_N" ]; then
        ccseat__resolved $((i - 1))
        return 0
      fi
      ccseat_err "there is no seat number $ref (there are $CCSEAT_N)" "See them with: ccseat list"
      return 1 ;;
  esac
  case "$ref" in
    *@*)
      i=0
      while [ "$i" -lt "$CCSEAT_N" ]; do
        e=$(ccseat_email "${CCSEAT_DIRS[i]}" 2>/dev/null)
        if [ -n "$e" ] && [ "$(printf '%s' "$e" | tr '[:upper:]' '[:lower:]')" = "$low" ]; then
          ccseat__resolved "$i"
          return 0
        fi
        i=$((i + 1))
      done ;;
    /*|"~"*|./*|../*)
      if d=$(ccseat_abspath "$ref") && i=$(ccseat__index_of_dir "$d"); then
        ccseat__resolved "$i"
        return 0
      fi ;;
  esac
  i=0
  while [ "$i" -lt "$CCSEAT_N" ]; do
    case "${CCSEAT_NAMES[i]}" in
      "$low"*)
        hits="$hits${hits:+, }${CCSEAT_NAMES[i]}"
        nhits=$((nhits + 1))
        [ "$nhits" -eq 1 ] && d=$i ;;
    esac
    i=$((i + 1))
  done
  if [ "$nhits" -eq 1 ]; then
    ccseat__resolved "$d"
    return 0
  fi
  if [ "$nhits" -gt 1 ]; then
    ccseat_err "\"$ref\" matches more than one seat: $hits" "Type more of the name, or use its number from ccseat list."
    return 1
  fi
  ccseat_err "no seat called \"$ref\". Seats: $(ccseat__names_joined)" "See them with: ccseat list"
  return 1
}

ccseat__resolved() {
  CCSEAT_R_INDEX=$1
  CCSEAT_R_NAME=${CCSEAT_NAMES[$1]}
  CCSEAT_R_DIR=${CCSEAT_DIRS[$1]}
}

ccseat__names_joined() {
  local i=0 out=""
  while [ "$i" -lt "$CCSEAT_N" ]; do
    out="$out${out:+, }${CCSEAT_NAMES[i]}"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# ---------- dependencies ----------

ccseat_need_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  if ccseat_is_macos; then
    ccseat_die "jq is required" "Install it with: brew install jq"
  fi
  ccseat_die "jq is required" "Install it with your package manager, for example: sudo apt install jq"
}

# ---------- ccseat config ----------

# What a setting does, for the settings table. $2 is its value: the default
# cc shortcut says that cc with arguments is still the C compiler.
ccseat__config_desc() {
  case "$1" in
    auto_switch) printf 'switch to the freest seat at a limit' ;;
    limit_5h) printf '5-hour percent counted as the limit' ;;
    limit_weekly) printf 'weekly percent counted as the limit' ;;
    remember) printf 'picker choice becomes the current seat' ;;
    share) printf 'shared with ~/.claude: ccseat config share' ;;
    colors) printf 'auto, always or never (NO_COLOR wins)' ;;
    statusline_width) printf 'columns the status line fits into' ;;
    shortcut)
      if [ "${2:-}" = cc ]; then printf 'opens the picker; cc file.c still compiles'
      else printf 'shell shortcut for the picker, or off'; fi ;;
  esac
}

# A value as the settings table shows it: the share list as a count.
ccseat__config_shown() {
  local v="$1" n
  case "$2" in
    share)
      n=$(printf '%s\n' "$v" | tr ',' '\n' | grep -c .)
      if [ "$n" = 1 ]; then printf '1 item'; else printf '%s items' "$n"; fi ;;
    *) printf '%s' "$v" ;;
  esac
}

ccseat_cmd_config() {
  local key="${1:-}" val k v def w=0 kw=0 shown note
  case "$key" in
    -h|--help) ccseat_help config; return 0 ;;
  esac
  if [ -z "$key" ]; then
    ccseat_colors_init 1
    if ! [ -t 1 ]; then
      for k in $CCSEAT_CONFIG_KEYS; do printf '%s=%s\n' "$k" "$(ccseat_config_get "$k")"; done
      return 0
    fi
    # Columns as wide as the longest setting and the longest value.
    for k in $CCSEAT_CONFIG_KEYS; do
      [ "${#k}" -gt "$kw" ] && kw=${#k}
      shown=$(ccseat__config_shown "$(ccseat_config_get "$k")" "$k")
      [ "${#shown}" -gt "$w" ] && w=${#shown}
    done
    for k in $CCSEAT_CONFIG_KEYS; do
      v=$(ccseat_config_get "$k")
      def=$(ccseat_config_default "$k")
      note=$(ccseat__config_desc "$k" "$v")
      if [ "$v" != "$def" ]; then
        if [ "$k" = share ]; then note="$note (changed)"; else note="$note (default $def)"; fi
      fi
      printf '%s  %s  %s%s%s\n' "$(ccseat_pad "$k" "$kw")" "$(ccseat_pad "$(ccseat__config_shown "$v" "$k")" "$w")" \
        "$CCSEAT_C_FAINT" "$note" "$CCSEAT_C_RESET"
    done
    return 0
  fi
  ccseat_config_is_key "$key" || ccseat_die_usage "unknown setting: $key (settings: $(printf '%s' "$CCSEAT_CONFIG_KEYS" | sed 's/ /, /g'))" config
  if [ $# -lt 2 ]; then
    ccseat_config_get "$key"
    printf '\n'
    return 0
  fi
  shift
  val="$*"
  if [ "$val" = default ]; then
    ccseat_config_store "$key" default || ccseat_die "could not write $(ccseat_tilde "$CCSEAT_CONFIG_FILE")"
    ccseat_config_load
    printf '%s is back to its default: %s\n' "$key" "$(ccseat_config_get "$key")"
  else
    ccseat__config_norm "$key" "$val" || ccseat_die_usage "$CCSEAT__NORM_ERR" config
    ccseat_config_store "$key" "$CCSEAT__NORM" || ccseat_die "could not write $(ccseat_tilde "$CCSEAT_CONFIG_FILE")"
    ccseat_config_load
    printf '%s = %s\n' "$key" "$CCSEAT__NORM"
  fi
  if [ "$key" = shortcut ]; then
    v=$(ccseat_config_get shortcut)
    if [ "$v" = off ]; then
      printf 'New terminals have no shortcut; ccseat opens the picker.\n'
    elif [ "$v" = cc ]; then
      printf 'Open a new terminal to use cc (cc with arguments still runs the C compiler).\n'
    else
      printf 'Open a new terminal to use %s (%s <command> runs ccseat <command>).\n' "$v" "$v"
    fi
  fi
  if [ "$key" = share ] && declare -F ccseat__links_prune >/dev/null; then
    ccseat__registry_ensure
    k=0
    while [ "$k" -lt "$CCSEAT_N" ]; do
      v=${CCSEAT_DIRS[k]}
      if ! ccseat_is_primary_dir "$v" && [ -d "$v" ]; then
        ccseat_links_ensure "$v"
        ccseat__links_prune "$v"
      fi
      k=$((k + 1))
    done
    [ "$CCSEAT_N" -gt 1 ] && printf 'Every seat now shares: %s\n' "$(ccseat_config_get share | sed 's/,/, /g')"
  fi
  return 0
}
