# shellcheck shell=bash
# shellcheck disable=SC2016 # shell code for the user's shell, printed as is
# shellcheck disable=SC2034 # CCSEAT_YES is read by ccseat_confirm in core.sh
# ccseat shell: "ccseat init <shell>" (the claude wrapper, the cs shortcut and
# completions), "ccseat setup" (adds it to the shell startup file) and
# "ccseat uninstall".
#
# The startup file gets one marked block, the same one install.sh writes:
#   # >>> ccseat >>>
#   if command -v ccseat >/dev/null 2>&1; then eval "$(ccseat init zsh)"; fi
#   # <<< ccseat <<<

CCSEAT_MARK_BEGIN="# >>> ccseat >>>"
CCSEAT_MARK_END="# <<< ccseat <<<"

CCSEAT_COMMANDS="pick:choose a seat and open Claude Code
list:every seat with its usage
run:open Claude Code with a seat
use:make a seat the current one
current:print the current seat
add:add a seat (logs in to another account)
remove:remove a seat
rename:rename a seat
sync:copy MCP servers and trusted folders to every seat
usage:usage of a seat
setup:add the shell integration to your shell
init:print the shell integration
statusline:the Claude Code status line
progress:workflow and agent progress
doctor:check the setup and print fixes
config:read or change settings
uninstall:remove ccseat
version:print the version
help:show help"

# How to call ccseat from the user's shell: the bare name when the ccseat on
# PATH is this one, else the full path it was started with.
ccseat__self_word() {
  local p
  p=$(type -P ccseat 2>/dev/null)
  if [ -n "$p" ] && [ "$(ccseat_realpath "$p")" = "${CCSEAT_SELF:-}" ]; then
    printf 'ccseat'
    return
  fi
  printf '%s' "${CCSEAT_INVOKED:-${CCSEAT_SELF:-ccseat}}"
}

ccseat__q() {
  # Quotes a word for sh-like shells.
  case "$1" in
    *[!A-Za-z0-9_./-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s' "$1" ;;
  esac
}

ccseat_cmd_init() {
  local sh="" me
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) ccseat_help init; return 0 ;;
      -*) ccseat_die_usage "unknown option for init: $1" init ;;
      *) [ -z "$sh" ] || ccseat_die_usage "init takes one shell" init; sh=$1 ;;
    esac
    shift
  done
  [ -n "$sh" ] || ccseat_die_usage "which shell? Usage: ccseat init zsh (or bash, or fish)" init
  sh=${sh##*/}
  me=$(ccseat__self_word)
  case "$sh" in
    zsh) ccseat__init_zsh "$(ccseat__q "$me")" ;;
    bash) ccseat__init_bash "$(ccseat__q "$me")" ;;
    fish) ccseat__init_fish "$me" ;;
    *) ccseat_die_usage "ccseat supports zsh, bash and fish (not $sh)" init ;;
  esac
}

ccseat__init_zsh() {
  local me="$1"
  cat <<EOF
# ccseat shell integration for zsh: eval "\$(ccseat init zsh)" in ~/.zshrc
if [[ -o interactive ]]; then
  export CCSEAT_SHELL=zsh
  # An alias would win over the function (Claude Code's local installer adds
  # one); ccseat finds that claude program by itself.
  unalias claude 2>/dev/null
  function claude {
    if [[ -n "\${CCSEAT_NO_WRAP:-}" ]] || ! command -v $me >/dev/null 2>&1; then
      command claude "\$@"
    else
      command $me claude "\$@"
    fi
  }
  if (( ! \$+commands[cs] && ! \$+aliases[cs] && ! \$+functions[cs] )); then
    function cs { command $me "\$@"; }
  fi
  if (( \$+functions[compdef] )); then
    function _ccseat {
      local -a cmds seats
      if (( CURRENT == 2 )); then
        cmds=("\${(@f)\$(command $me __complete commands-described 2>/dev/null)}")
        _describe 'command' cmds
        return
      fi
      case "\$words[2]" in
        run|use|remove|rm|rename|usage|sync)
          (( CURRENT == 3 )) || return
          seats=("\${(@f)\$(command $me __complete seats 2>/dev/null)}")
          compadd -a seats ;;
        init|setup) compadd zsh bash fish ;;
        config) (( CURRENT == 3 )) && compadd auto_switch limit_5h limit_weekly remember share colors ;;
        statusline) compadd install uninstall ;;
        help) compadd \${(@f)"\$(command $me __complete commands 2>/dev/null)"} ;;
      esac
    }
    compdef _ccseat ccseat
    (( \$+functions[cs] )) && compdef _ccseat cs
  fi
fi
EOF
}

ccseat__init_bash() {
  local me="$1"
  cat <<EOF
# ccseat shell integration for bash: eval "\$(ccseat init bash)" in ~/.bashrc
if [[ \$- == *i* ]]; then
  export CCSEAT_SHELL=bash
  # An alias would win over the function (Claude Code's local installer adds
  # one); ccseat finds that claude program by itself.
  unalias claude 2>/dev/null || true
  function claude {
    if [ -n "\${CCSEAT_NO_WRAP:-}" ] || ! command -v $me >/dev/null 2>&1; then
      command claude "\$@"
    else
      command $me claude "\$@"
    fi
  }
  if ! type -P cs >/dev/null 2>&1 && ! alias cs >/dev/null 2>&1 && ! declare -F cs >/dev/null 2>&1; then
    function cs { command $me "\$@"; }
  fi
  _ccseat_complete() {
    local cur=\${COMP_WORDS[COMP_CWORD]} words
    COMPREPLY=()
    if [ "\$COMP_CWORD" -eq 1 ]; then
      words=\$(command $me __complete commands 2>/dev/null)
    else
      case "\${COMP_WORDS[1]}" in
        run|use|remove|rm|rename|usage|sync)
          [ "\$COMP_CWORD" -eq 2 ] || return 0
          words=\$(command $me __complete seats 2>/dev/null) ;;
        init|setup) words="zsh bash fish" ;;
        config) [ "\$COMP_CWORD" -eq 2 ] && words="auto_switch limit_5h limit_weekly remember share colors" ;;
        statusline) words="install uninstall" ;;
        help) words=\$(command $me __complete commands 2>/dev/null) ;;
        *) return 0 ;;
      esac
    fi
    COMPREPLY=(\$(compgen -W "\$words" -- "\$cur"))
  }
  complete -F _ccseat_complete ccseat
  type -t cs 2>/dev/null | grep -q function && complete -F _ccseat_complete cs
fi
EOF
}

ccseat__init_fish() {
  local me="$1" qme
  qme=$(printf '%s' "$me" | sed "s/'/\\\\'/g")
  qme="'$qme'"
  [ "$me" = ccseat ] && qme=ccseat
  cat <<EOF
# ccseat shell integration for fish: ccseat init fish | source
if status is-interactive
    set -gx CCSEAT_SHELL fish
    function claude --wraps claude --description 'Claude Code in the current ccseat seat'
        if test -n "\$CCSEAT_NO_WRAP"; or not command -sq $qme
            command claude \$argv
        else
            command $qme claude \$argv
        end
    end
    if not command -sq cs; and not functions -q cs
        function cs --wraps ccseat --description 'ccseat'
            command $qme \$argv
        end
    end
    complete -c ccseat -f
    complete -c ccseat -n __fish_use_subcommand -a '(command $qme __complete commands-fish 2>/dev/null)'
    complete -c ccseat -n '__fish_seen_subcommand_from run use remove rm rename usage sync' -a '(command $qme __complete seats 2>/dev/null)'
    complete -c ccseat -n '__fish_seen_subcommand_from init setup' -a 'zsh bash fish'
    complete -c ccseat -n '__fish_seen_subcommand_from config' -a 'auto_switch limit_5h limit_weekly remember share colors'
    complete -c ccseat -n '__fish_seen_subcommand_from statusline' -a 'install uninstall'
    functions -q cs; and complete -c cs --wraps ccseat
end
EOF
}

# Hidden helper for shell completions.
ccseat_cmd_complete() {
  case "${1:-}" in
    seats) ccseat__registry_ensure; ccseat_seat_list | cut -f1 ;;
    commands) printf '%s\n' "$CCSEAT_COMMANDS" | cut -d: -f1 ;;
    commands-described) printf '%s\n' "$CCSEAT_COMMANDS" ;;
    commands-fish) printf '%s\n' "$CCSEAT_COMMANDS" | tr ':' '\t' ;;
  esac
  return 0
}

# ---------- setup ----------

ccseat__detect_shell() {
  local s="${1:-${SHELL:-}}"
  s=${s##*/}
  case "$s" in zsh|bash|fish) printf '%s' "$s" ;; esac
}

ccseat_rc_file() {
  case "$1" in
    zsh) printf '%s/.zshrc' "$(ccseat_strip_slash "${ZDOTDIR:-$CCSEAT_USER_HOME}")" ;;
    bash)
      if ccseat_is_macos; then printf '%s/.bash_profile' "$CCSEAT_USER_HOME"
      else printf '%s/.bashrc' "$CCSEAT_USER_HOME"; fi ;;
    fish) printf '%s/fish/conf.d/ccseat.fish' "$(ccseat__xdg "${XDG_CONFIG_HOME:-}" "$CCSEAT_USER_HOME/.config")" ;;
  esac
}

ccseat__on_path() {
  case ":${PATH:-}:" in *":$1:"*) return 0 ;; esac
  return 1
}

ccseat__block() {
  local sh="$1" me dir word=""
  me=$(ccseat__self_word)
  if [ "$me" != ccseat ]; then
    dir=$(dirname "$me")
    case "$dir" in
      "$CCSEAT_USER_HOME"/*) word="\$HOME${dir#"$CCSEAT_USER_HOME"}" ;;
      *) word=$dir ;;
    esac
  fi
  printf '%s\n' "$CCSEAT_MARK_BEGIN"
  case "$sh" in
    fish)
      [ -n "$word" ] && printf 'if not contains -- "%s" $PATH\n    set -gx PATH "%s" $PATH\nend\n' "$word" "$word"
      printf 'if type -q ccseat\n    ccseat init fish | source\nend\n' ;;
    *)
      [ -n "$word" ] && printf 'case ":$PATH:" in\n  *":%s:"*) ;;\n  *) export PATH="%s:$PATH" ;;\nesac\n' "$word" "$word"
      printf 'if command -v ccseat >/dev/null 2>&1; then eval "$(ccseat init %s)"; fi\n' "$sh" ;;
  esac
  printf '%s\n' "$CCSEAT_MARK_END"
}

ccseat_cmd_setup() {
  local sh="" want_sl="" rc shown rc_status f
  while [ $# -gt 0 ]; do
    case "$1" in
      --shell) [ $# -ge 2 ] || ccseat_die_usage "--shell needs zsh, bash or fish" setup; sh=$2; shift ;;
      --shell=*) sh=${1#--shell=} ;;
      zsh|bash|fish) sh=$1 ;;
      --statusline) want_sl=yes ;;
      --no-statusline) want_sl=no ;;
      -y|--yes) CCSEAT_YES=1 ;;
      -h|--help) ccseat_help setup; return 0 ;;
      *) ccseat_die_usage "unknown option for setup: $1" setup ;;
    esac
    shift
  done
  if [ -n "$sh" ]; then
    case "${sh##*/}" in zsh|bash|fish) sh=${sh##*/} ;; *) ccseat_die_usage "ccseat supports zsh, bash and fish (not $sh)" setup ;; esac
  else
    sh=$(ccseat__detect_shell)
    [ -n "$sh" ] || ccseat_die "could not tell your shell from \$SHELL (${SHELL:-unset})" \
      "Run: ccseat setup --shell zsh   (or bash, or fish)"
  fi
  ccseat_colors_init 1
  rc=$(ccseat_rc_file "$sh")
  shown=$(ccseat_tilde "$rc")
  rc_status=added
  if [ -f "$rc" ] && { grep -qF "$CCSEAT_MARK_BEGIN" "$rc" || grep -Eq 'ccseat[[:space:]]+init' "$rc"; }; then
    rc_status=present
  else
    mkdir -p "$(dirname "$rc")" 2>/dev/null || ccseat_die "cannot create $(ccseat_tilde "$(dirname "$rc")")"
    if [ -s "$rc" ] && [ -n "$(tail -c 1 "$rc")" ]; then printf '\n' >> "$rc"; fi
    if [ -s "$rc" ] && [ -n "$(tail -n 1 "$rc")" ]; then printf '\n' >> "$rc"; fi
    ccseat__block "$sh" >> "$rc" || ccseat_die "cannot write $shown"
  fi
  if [ "$rc_status" = present ]; then
    printf '%s✓%s Shell integration is already in %s.\n' "$CCSEAT_C_GREEN" "$CCSEAT_C_RESET" "$shown"
  else
    printf '%s✓%s Added the shell integration to %s.\n' "$CCSEAT_C_GREEN" "$CCSEAT_C_RESET" "$shown"
  fi

  if ! ccseat_claude_bin >/dev/null; then
    printf '%s!%s Claude Code is not installed yet: curl -fsSL https://claude.ai/install.sh | bash\n' "$CCSEAT_C_KRAFT" "$CCSEAT_C_RESET"
  fi
  for f in jq curl; do
    command -v "$f" >/dev/null 2>&1 && continue
    printf '%s!%s ccseat needs %s: %s\n' "$CCSEAT_C_KRAFT" "$CCSEAT_C_RESET" "$f" "$(ccseat__doc_install_hint "$f")"
  done
  ccseat__registry_ensure
  if [ "$CCSEAT_N" -gt 0 ]; then
    printf '%s✓%s Seats: %s\n' "$CCSEAT_C_GREEN" "$CCSEAT_C_RESET" "$(ccseat__names_joined)"
  else
    printf '%s!%s No seats yet. Add your first account with: ccseat add\n' "$CCSEAT_C_KRAFT" "$CCSEAT_C_RESET"
  fi
  ccseat__setup_statusline "$want_sl"

  printf '\nOpen a new terminal (or run: exec %s). Then:\n' "$sh"
  printf '  claude       opens the current seat; switches seats at a limit\n'
  printf '  ccseat       pick a seat with the arrow keys (cs for short)\n'
  printf '  ccseat add   add another account\n'
}

ccseat__statusline_installed() {
  local s="$CCSEAT_PRIMARY_DIR/settings.json"
  [ -f "$s" ] || return 1
  jq -r '.statusLine.command // empty' "$s" 2>/dev/null | grep -q 'ccseat'
}

ccseat__statusline_other() {
  local s="$CCSEAT_PRIMARY_DIR/settings.json" c
  [ -f "$s" ] || return 1
  c=$(jq -r '.statusLine.command // empty' "$s" 2>/dev/null)
  [ -n "$c" ] && ! printf '%s' "$c" | grep -q 'ccseat'
}

ccseat__setup_statusline() {
  local want="$1" rc
  declare -F ccseat_statusline_main >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  if ccseat__statusline_installed; then
    printf '%s✓%s The status line shows the seat and its usage.\n' "$CCSEAT_C_GREEN" "$CCSEAT_C_RESET"
    return 0
  fi
  [ "$want" = no ] && return 0
  if [ "$want" != yes ]; then
    if ccseat__statusline_other; then
      printf '%s·%s Your own status line stays. To show seats there: ccseat statusline install\n' "$CCSEAT_C_FAINT" "$CCSEAT_C_RESET"
      return 0
    fi
    ccseat_confirm "Show the seat and its usage in Claude Code's status line?" y
    rc=$?
    if [ "$rc" -ne 0 ]; then
      printf '%s·%s Status line skipped. Turn it on later with: ccseat statusline install\n' "$CCSEAT_C_FAINT" "$CCSEAT_C_RESET"
      return 0
    fi
  fi
  ccseat_statusline_main install
}

# ---------- uninstall ----------

# Removes our block, and hand-added "ccseat init" lines, from a startup file.
# Writes in place so a symlinked dotfile stays a symlink; keeps a backup.
ccseat__strip_rc() {
  local f="$1" tmp
  [ -f "$f" ] || return 1
  grep -qF "$CCSEAT_MARK_BEGIN" "$f" 2>/dev/null || grep -Eq 'ccseat[[:space:]]+init' "$f" 2>/dev/null || return 1
  tmp=$(mktemp "${TMPDIR:-/tmp}/ccseat-rc.XXXXXX") || return 1
  # A begin marker without its end marker is left alone with everything
  # after it: only a whole block is removed.
  awk -v b="$CCSEAT_MARK_BEGIN" -v e="$CCSEAT_MARK_END" '
    !skip && $0 == b { skip = 1; dropped = held; held = 0; n = 0; buf[++n] = $0; next }
    skip && $0 == e { skip = 0; next }
    skip { buf[++n] = $0; next }
    /ccseat[ \t]+init/ { next }
    { if (held) print ""; held = 0 }
    $0 == "" { held = 1; next }
    { print }
    END {
      if (skip) { if (dropped) print ""; for (i = 1; i <= n; i++) print buf[i] }
      else if (held) print ""
    }
  ' "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
  ccseat__backup_to_trash "$f"
  cat "$tmp" > "$f"
  rm -f "$tmp"
  return 0
}

# Puts a copy of a file in the Trash before it is edited, so the old version
# can be recovered without leaving backups next to it.
ccseat__backup_to_trash() {
  local f="$1" d copy base
  d=$(mktemp -d "${TMPDIR:-/tmp}/ccseat-backup.XXXXXX") || return 1
  base=$(basename "$f")
  copy="$d/${base#.} before ccseat uninstall"
  cp -p "$f" "$copy" 2>/dev/null && ccseat_trash "$copy" >/dev/null 2>&1
  rmdir "$d" 2>/dev/null
  return 0
}

ccseat_cmd_uninstall() {
  local purge=0 q rc f removed="" i dir root inv p again
  while [ $# -gt 0 ]; do
    case "$1" in
      --purge) purge=1 ;;
      -y|--yes) CCSEAT_YES=1 ;;
      -h|--help) ccseat_help uninstall; return 0 ;;
      *) ccseat_die_usage "unknown option for uninstall: $1" uninstall ;;
    esac
    shift
  done
  ccseat__registry_ensure
  if [ "$purge" = 1 ]; then
    q="Uninstall ccseat and move every seat folder except ~/.claude, plus ccseat's settings, to the Trash?"
    again="ccseat uninstall --purge -y"
  else
    q="Uninstall ccseat? Seats and settings stay (--purge removes them)."
    again="ccseat uninstall -y"
  fi
  ccseat_confirm "$q"
  rc=$?
  case "$rc" in
    0) ;;
    2) ccseat_die "not uninstalling without a confirmation" "Run it in a terminal, or add -y: $again" ;;
    *) printf 'Nothing was changed.\n'; exit 130 ;;
  esac
  ccseat_colors_init 1

  # Shell startup files.
  for f in "$(ccseat_strip_slash "${ZDOTDIR:-$CCSEAT_USER_HOME}")/.zshrc" "$CCSEAT_USER_HOME/.bashrc" \
    "$CCSEAT_USER_HOME/.bash_profile" "$CCSEAT_USER_HOME/.profile" "$CCSEAT_USER_HOME/.zprofile" \
    "$(ccseat__xdg "${XDG_CONFIG_HOME:-}" "$CCSEAT_USER_HOME/.config")/fish/config.fish"; do
    if ccseat__strip_rc "$f"; then removed="$removed $(ccseat_tilde "$f")"; fi
  done
  f=$(ccseat_rc_file fish)
  if [ -f "$f" ] && grep -q 'ccseat' "$f" 2>/dev/null; then
    ccseat_trash "$f" && removed="$removed $(ccseat_tilde "$f")"
  fi
  if [ -n "$removed" ]; then
    printf 'Removed the shell integration from%s.\n' "$removed"
  else
    printf 'No shell integration to remove.\n'
  fi

  # Status line, when it points at ccseat.
  if declare -F ccseat_statusline_main >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
    && ccseat__statusline_installed; then
    ccseat_statusline_main uninstall || true
  fi

  if [ "$purge" = 1 ]; then
    i=0
    while [ "$i" -lt "$CCSEAT_N" ]; do
      dir=${CCSEAT_DIRS[i]}
      # Never a folder that leads to ~/.claude or holds the home folder: its
      # login would be the primary's.
      if ! ccseat_is_primary_place "$dir" && [ -d "$dir" ] \
        && ! ccseat_path_within "$CCSEAT_USER_HOME" "$dir" && ! ccseat_path_within "$CCSEAT_PRIMARY_DIR" "$dir" \
        && ! ccseat_path_within "$dir" "$CCSEAT_PRIMARY_DIR"; then
        ccseat_auth_check "$dir"
        if [ "$CCSEAT_AUTH" != none ] && ccseat_claude_bin >/dev/null; then
          ccseat_claude_in "$dir" auth logout </dev/null >/dev/null 2>&1
        fi
        if ccseat_trash "$dir"; then
          printf 'Moved the seat %s (%s) to the Trash.\n' "${CCSEAT_NAMES[i]}" "$(ccseat_tilde "$dir")"
        fi
      fi
      i=$((i + 1))
    done
    for p in "$CCSEAT_HOME" "$CCSEAT_CACHE_DIR"; do
      [ -e "$p" ] && ccseat_trash "$p" && printf 'Moved %s to the Trash.\n' "$(ccseat_tilde "$p")"
    done
    rmdir "$CCSEAT_SEATS_DIR" 2>/dev/null
  fi

  # The program itself.
  root=${CCSEAT_ROOT:-}
  inv=${CCSEAT_INVOKED:-}
  case "$root" in
    */Cellar/*|*/homebrew/*|*/linuxbrew/*)
      printf 'ccseat was installed with Homebrew. Finish with: brew uninstall ccseat\n' ;;
    *)
      for p in "$inv" "$CCSEAT_USER_HOME/.local/bin/ccseat" "$(type -P ccseat 2>/dev/null)"; do
        [ -n "$p" ] && [ -L "$p" ] || continue
        [ "$(ccseat_realpath "$p")" = "${CCSEAT_SELF:-}" ] || continue
        rm -f "$p" 2>/dev/null && printf 'Removed %s.\n' "$(ccseat_tilde "$p")"
      done
      if [ -d "$root/.git" ]; then
        printf 'Left the source folder %s in place.\n' "$(ccseat_tilde "$root")"
      elif [ -n "$root" ] && [ -f "$root/bin/ccseat" ] && [ -d "$root/lib/ccseat" ] \
        && ! [ -e "$root/seats" ] && [ "$root" != "$CCSEAT_USER_HOME" ] && [ "$root" != "$CCSEAT_DATA_DIR" ]; then
        if ccseat_trash "$root"; then
          printf 'Moved the program (%s) to the Trash.\n' "$(ccseat_tilde "$root")"
          rmdir "$CCSEAT_DATA_DIR" 2>/dev/null
        fi
      fi ;;
  esac
  if [ "$purge" != 1 ] && [ "$CCSEAT_N" -gt 0 ]; then
    printf 'Your seats and ~/.claude stay as they are.\n'
  fi
  printf 'Open a new terminal to finish.\n'
}
