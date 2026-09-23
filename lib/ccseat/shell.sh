# shellcheck shell=bash
# shellcheck disable=SC2016 # shell code for the user's shell, printed as is
# shellcheck disable=SC2034 # CCSEAT_YES is read by ccseat_confirm in core.sh
# ccseat shell: "ccseat init <shell>" (the claude wrapper, the cc shortcut and
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
  local sh="" me sc
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
  sc=$(ccseat__shortcut_name)
  case "$sh" in
    zsh) ccseat__init_zsh "$(ccseat__q "$me")" "$sc" ;;
    bash) ccseat__init_bash "$(ccseat__q "$me")" "$sc" ;;
    fish) ccseat__init_fish "$me" "$sc" ;;
    *) ccseat_die_usage "ccseat supports zsh, bash and fish (not $sh)" init ;;
  esac
}

# The shortcut the shell integration defines ("shortcut" in ccseat config),
# or nothing when it is off. The name goes into shell code unquoted, so it is
# checked again here, whatever the config file says.
ccseat__shortcut_name() {
  local sc
  sc=$(ccseat_config_get shortcut)
  [ "$sc" = off ] && return 0
  ccseat__config_norm shortcut "$sc" || return 0
  [ "$CCSEAT__NORM" = off ] && return 0
  printf '%s' "$CCSEAT__NORM"
}

ccseat__init_zsh() {
  local me="$1" sc="${2:-}"
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
EOF
  if [ -n "$sc" ]; then
    cat <<EOF
  # $sc opens the seat picker (ccseat config shortcut changes the name). A
  # function or alias of your own with that name is left alone.
  if (( ! \$+aliases[$sc] )) && { (( ! \$+functions[$sc] )) || [[ "\${__ccseat_shortcut:-}" == $sc ]]; }; then
    __ccseat_shortcut=$sc
EOF
    if [ "$sc" = cc ]; then
      cat <<EOF
    # With arguments, cc is still the C compiler when one is installed.
    function cc {
      if (( \$# )) && (( \$+commands[cc] )); then
        command cc "\$@"
      else
        command $me "\$@"
      fi
    }
EOF
    else
      cat <<EOF
    function $sc { command $me "\$@"; }
EOF
    fi
    cat <<EOF
  fi
EOF
  fi
  cat <<EOF
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
        config) (( CURRENT == 3 )) && compadd $CCSEAT_CONFIG_KEYS ;;
        statusline) compadd install uninstall ;;
        help) compadd \${(@f)"\$(command $me __complete commands 2>/dev/null)"} ;;
      esac
    }
    compdef _ccseat ccseat
EOF
  if [ "$sc" = cc ]; then
    cat <<EOF
    # cc keeps the compiler's completions while a compiler is installed.
    if [[ "\${__ccseat_shortcut:-}" == cc ]] && (( ! \$+commands[cc] )); then compdef _ccseat cc; fi
EOF
  elif [ -n "$sc" ]; then
    cat <<EOF
    if [[ "\${__ccseat_shortcut:-}" == $sc ]]; then compdef _ccseat $sc; fi
EOF
  fi
  cat <<EOF
  fi
fi
EOF
}

ccseat__init_bash() {
  local me="$1" sc="${2:-}"
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
EOF
  if [ -n "$sc" ]; then
    cat <<EOF
  # $sc opens the seat picker (ccseat config shortcut changes the name). A
  # function or alias of your own with that name is left alone.
  if ! alias $sc >/dev/null 2>&1 && { ! declare -F $sc >/dev/null 2>&1 || [ "\${__ccseat_shortcut:-}" = $sc ]; }; then
    __ccseat_shortcut=$sc
EOF
    if [ "$sc" = cc ]; then
      cat <<EOF
    # With arguments, cc is still the C compiler when one is installed.
    function cc {
      if [ \$# -gt 0 ] && type -P cc >/dev/null 2>&1; then
        command cc "\$@"
      else
        command $me "\$@"
      fi
    }
EOF
    else
      cat <<EOF
    function $sc { command $me "\$@"; }
EOF
    fi
    cat <<EOF
  fi
EOF
  fi
  cat <<EOF
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
        config) [ "\$COMP_CWORD" -eq 2 ] && words="$CCSEAT_CONFIG_KEYS" ;;
        statusline) words="install uninstall" ;;
        help) words=\$(command $me __complete commands 2>/dev/null) ;;
        *) return 0 ;;
      esac
    fi
    COMPREPLY=(\$(compgen -W "\$words" -- "\$cur"))
  }
  complete -F _ccseat_complete ccseat
EOF
  if [ "$sc" = cc ]; then
    cat <<EOF
  # cc keeps the compiler's completions while a compiler is installed.
  if [ "\${__ccseat_shortcut:-}" = cc ] && ! type -P cc >/dev/null 2>&1; then complete -F _ccseat_complete cc; fi
EOF
  elif [ -n "$sc" ]; then
    cat <<EOF
  if [ "\${__ccseat_shortcut:-}" = $sc ]; then complete -F _ccseat_complete $sc; fi
EOF
  fi
  cat <<EOF
fi
EOF
}

ccseat__init_fish() {
  local me="$1" sc="${2:-}" qme
  # A fish single-quoted word: backslashes first, then quotes.
  qme=$(printf '%s' "$me" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g")
  qme="'$qme'"
  [ "$me" = ccseat ] && qme=ccseat
  # The completions below are single-quoted strings fish runs later, so they
  # name ccseat through a variable instead of pasting the quoted path in.
  cat <<EOF
# ccseat shell integration for fish: ccseat init fish | source
if status is-interactive
    set -gx CCSEAT_SHELL fish
    set -g __ccseat_cmd $qme
    function claude --wraps claude --description 'Claude Code in the current ccseat seat'
        if test -n "\$CCSEAT_NO_WRAP"; or not command -sq $qme
            command claude \$argv
        else
            command $qme claude \$argv
        end
    end
EOF
  if [ -n "$sc" ]; then
    cat <<EOF
    # $sc opens the seat picker (ccseat config shortcut changes the name). A
    # function or alias of your own with that name is left alone.
    if not functions -q $sc; or test "\$__ccseat_shortcut" = $sc
        set -g __ccseat_shortcut $sc
EOF
    if [ "$sc" = cc ]; then
      cat <<EOF
        # With arguments, cc is still the C compiler when one is installed.
        function cc --description 'ccseat seat picker; the C compiler with arguments'
            if set -q argv[1]; and command -sq cc
                command cc \$argv
            else
                command $qme \$argv
            end
        end
        not command -sq cc; and complete -c cc --wraps ccseat
EOF
    else
      cat <<EOF
        function $sc --wraps ccseat --description 'ccseat'
            command $qme \$argv
        end
EOF
    fi
    cat <<EOF
    end
EOF
  fi
  cat <<EOF
    complete -c ccseat -f
    complete -c ccseat -n __fish_use_subcommand -a '(command \$__ccseat_cmd __complete commands-fish 2>/dev/null)'
    complete -c ccseat -n '__fish_seen_subcommand_from run use remove rm rename usage sync' -a '(command \$__ccseat_cmd __complete seats 2>/dev/null)'
    complete -c ccseat -n '__fish_seen_subcommand_from init setup' -a 'zsh bash fish'
    complete -c ccseat -n '__fish_seen_subcommand_from config' -a '$CCSEAT_CONFIG_KEYS'
    complete -c ccseat -n '__fish_seen_subcommand_from statusline' -a 'install uninstall'
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

# shellcheck disable=SC2120 # the arguments are optional
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

# A folder as it goes between double quotes in a startup file: $HOME for
# the home folder (it survives a moved home), the rest escaped, so a folder
# name with $, `, " or \ stays text and never runs. $1 = sh or fish (fish
# has no backquotes and keeps a backslash before other characters).
ccseat__rc_word() {
  local sh="$1" d="$2" pre="" chars='[\\"$`]'
  [ "$sh" = fish ] && chars='[\\"$]'
  case "$d" in
    "$CCSEAT_USER_HOME"/*) pre="\$HOME"; d=${d#"$CCSEAT_USER_HOME"} ;;
  esac
  printf '%s%s' "$pre" "$(printf '%s' "$d" | sed "s/$chars/\\\\&/g")"
}

ccseat__block() {
  local sh="$1" me word=""
  me=$(ccseat__self_word)
  if [ "$me" != ccseat ]; then
    if [ "$sh" = fish ]; then word=$(ccseat__rc_word fish "$(dirname "$me")")
    else word=$(ccseat__rc_word sh "$(dirname "$me")"); fi
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
  local sh="" want_sl="" rc shown rc_status f sc
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
  sc=$(ccseat__shortcut_name)
  if [ "$sc" = cc ]; then
    printf '  cc           pick a seat with the arrow keys (cc file.c still compiles)\n'
  elif [ -n "$sc" ]; then
    printf '  %s  pick a seat with the arrow keys (the same as ccseat)\n' "$(ccseat_pad "$sc" 11)"
  else
    printf '  ccseat       pick a seat with the arrow keys\n'
  fi
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

# Removes our block, and the one-line forms of "ccseat init" that ccseat
# prints, from a startup file. Any other line that runs ccseat init (inside a
# hand-written if, say) stays, and is listed for the user. When the result
# would no longer parse in its shell, only the block goes, or nothing.
# Writes in place so a symlinked dotfile stays a symlink; keeps a backup.
ccseat__strip_rc() {
  local f="$1" tmp mode ok_before=0
  [ -f "$f" ] || return 1
  grep -qF "$CCSEAT_MARK_BEGIN" "$f" 2>/dev/null || grep -Eq 'ccseat[[:space:]]+init' "$f" 2>/dev/null || return 1
  tmp=$(mktemp "${TMPDIR:-/tmp}/ccseat-rc.XXXXXX") || return 1
  ccseat__rc_parses "$f" "$f" && ok_before=1
  for mode in lines block; do
    ccseat__strip_rc_awk "$mode" "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
    [ "$ok_before" = 0 ] && break
    ccseat__rc_parses "$tmp" "$f" && break
    mode=none
  done
  if [ "$mode" = none ] || cmp -s "$f" "$tmp"; then
    rm -f "$tmp"
    ccseat__rc_leftovers "$f"
    return 1
  fi
  ccseat__backup_to_trash "$f"
  cat "$tmp" > "$f"
  rm -f "$tmp"
  ccseat__rc_leftovers "$f"
  return 0
}

# ccseat__strip_rc_awk lines|block FILE : prints FILE without our marked
# block ("block"), and also without the exact one-line forms ("lines"):
#   eval "$(ccseat init zsh)"   (or bash, or a path to ccseat)
#   ccseat init fish | source
#   if command -v ccseat >/dev/null 2>&1; then eval "$(ccseat init zsh)"; fi
# A begin marker without its end marker is left alone with everything after
# it: only a whole block is removed.
ccseat__strip_rc_awk() {
  awk -v b="$CCSEAT_MARK_BEGIN" -v e="$CCSEAT_MARK_END" -v lines="$([ "$1" = lines ] && echo 1)" '
    function ours(s) {
      sub(/^[ \t]+/, "", s); sub(/[ \t]+#[^"]*$/, "", s); sub(/[ \t]+$/, "", s)
      if (s ~ /^eval "\$\((command )?[^ "()]*ccseat init (zsh|bash)\)"$/) return 1
      if (s ~ /^(command )?[^ "()|]*ccseat init fish \| source$/) return 1
      if (s ~ /^if command -v ccseat >\/dev\/null 2>&1; then eval "\$\(ccseat init (zsh|bash)\)"; fi$/) return 1
      return 0
    }
    !skip && $0 == b { skip = 1; dropped = held; held = 0; n = 0; buf[++n] = $0; next }
    skip && $0 == e { skip = 0; next }
    skip { buf[++n] = $0; next }
    lines && ours($0) { next }
    { if (held) print ""; held = 0 }
    $0 == "" { held = 1; next }
    { print }
    END {
      if (skip) { if (dropped) print ""; for (i = 1; i <= n; i++) print buf[i] }
      else if (held) print ""
    }
  ' "$2"
}

# ccseat__rc_parses FILE AS : true when FILE parses in the shell that reads
# the startup file AS, or when that shell is not installed.
ccseat__rc_parses() {
  case "$2" in
    *.fish)
      command -v fish >/dev/null 2>&1 || return 0
      fish --no-config -n "$1" >/dev/null 2>&1 ;;
    */.zshrc|*/.zprofile)
      command -v zsh >/dev/null 2>&1 || return 0
      zsh -f -n "$1" >/dev/null 2>&1 ;;
    *)
      command -v bash >/dev/null 2>&1 || return 0
      BASH_ENV='' ENV='' bash --norc --noprofile -n "$1" >/dev/null 2>&1 ;;
  esac
}

# Lists the lines of a startup file that still run ccseat init.
ccseat__rc_leftovers() {
  local nums word=line
  nums=$(grep -nE '^[^#]*ccseat[[:space:]]+init' "$1" 2>/dev/null | cut -d: -f1 | paste -sd, - | sed 's/,/, /g')
  [ -n "$nums" ] || return 0
  case "$nums" in *,*) word=lines ;; esac
  printf '%s·%s %s still runs ccseat init on %s %s; remove it by hand.\n' \
    "$CCSEAT_C_FAINT" "$CCSEAT_C_RESET" "$(ccseat_tilde "$1")" "$word" "$nums"
}

# True when every entry of a folder matches one of the patterns after it.
ccseat__holds_only_own() {
  local dir="$1" e b pat ok
  shift
  for e in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    b=${e##*/}
    ok=0
    for pat in "$@"; do
      # shellcheck disable=SC2254 # the patterns are globs on purpose
      case "$b" in $pat) ok=1; break ;; esac
    done
    [ "$ok" = 1 ] || return 1
  done
  return 0
}

# True when the program's folder holds ccseat and nothing else, so uninstall
# may move all of it: the installer's copy, the share/ccseat of "make
# install" or an unpacked release. bin and lib must hold only ccseat, and
# anything else must be a file of the source tree.
ccseat__program_dir_is_own() {
  local root="$1"
  [ "$root" = "$CCSEAT_DATA_DIR/app" ] && return 0
  ccseat__holds_only_own "$root/bin" ccseat || return 1
  ccseat__holds_only_own "$root/lib" ccseat || return 1
  ccseat__holds_only_own "$root" bin lib LICENSE README.md CHANGELOG.md CONTRIBUTING.md \
    CODE_OF_CONDUCT.md SECURITY.md Makefile install.sh docs tests Formula .github \
    .editorconfig .gitignore .shellcheckrc .DS_Store
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
      [ -e "$p" ] || continue
      # CCSEAT_HOME can point at a folder other programs use too.
      if [ "$p" = "$CCSEAT_HOME" ] && ! ccseat__holds_only_own "$p" \
        seats current config backups statusline-previous.json .seats.lock '.ccseat.*' '.ccseat-edit-*' .DS_Store; then
        printf 'Left %s in place: it holds other files too.\n' "$(ccseat_tilde "$p")"
        printf "ccseat's own files there are seats, current, config and backups.\n"
        continue
      fi
      ccseat_trash "$p" && printf 'Moved %s to the Trash.\n' "$(ccseat_tilde "$p")"
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
        { [ -n "$p" ] && [ -L "$p" ]; } || continue
        [ "$(ccseat_realpath "$p")" = "${CCSEAT_SELF:-}" ] || continue
        rm -f "$p" 2>/dev/null && printf 'Removed %s.\n' "$(ccseat_tilde "$p")"
      done
      # .git is a folder in a clone and a file in a worktree or submodule.
      if [ -e "$root/.git" ]; then
        printf 'Left the source folder %s in place.\n' "$(ccseat_tilde "$root")"
      elif [ -n "$root" ] && [ -f "$root/bin/ccseat" ] && [ -d "$root/lib/ccseat" ] \
        && ! [ -e "$root/seats" ] && [ "$root" != "$CCSEAT_USER_HOME" ] && [ "$root" != "$CCSEAT_DATA_DIR" ]; then
        if ccseat__program_dir_is_own "$root"; then
          if ccseat_trash "$root"; then
            printf 'Moved the program (%s) to the Trash.\n' "$(ccseat_tilde "$root")"
            rmdir "$CCSEAT_DATA_DIR" 2>/dev/null
          fi
        else
          # bin/ccseat and lib/ccseat copied into a prefix other programs
          # share, like ~/.local or /usr/local: only those two leave it.
          for p in "$root/bin/ccseat" "$root/lib/ccseat"; do
            ccseat_trash "$p" && printf 'Moved %s to the Trash.\n' "$(ccseat_tilde "$p")"
          done
        fi
      fi ;;
  esac
  if [ "$purge" != 1 ] && [ "$CCSEAT_N" -gt 0 ]; then
    printf 'Your seats and ~/.claude stay as they are.\n'
  fi
  printf 'Open a new terminal to finish.\n'
}
