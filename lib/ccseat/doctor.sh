# shellcheck shell=bash
# ccseat doctor: checks tools, seats, shared links, the shell integration and
# the status line, and prints the fix for anything that is off. It changes
# nothing but the usage cache.

ccseat__doc_ok() { printf '  %s✓%s %s\n' "$CCSEAT_C_GREEN" "$CCSEAT_C_RESET" "$1"; }

ccseat__doc_info() {
  printf '  %s·%s %s\n' "$CCSEAT_C_FAINT" "$CCSEAT_C_RESET" "$1"
  [ -n "${2:-}" ] && printf '      %s%s%s\n' "$CCSEAT_C_MID" "$2" "$CCSEAT_C_RESET"
  return 0
}

# A warning, its fix, and any further lines of the fix.
ccseat__doc_warn() {
  local l
  CCSEAT__DOC_WARN=$((CCSEAT__DOC_WARN + 1))
  printf '  %s!%s %s\n' "$CCSEAT_C_KRAFT" "$CCSEAT_C_RESET" "$1"
  [ -n "${2:-}" ] && printf '      %sfix: %s%s\n' "$CCSEAT_C_MID" "$2" "$CCSEAT_C_RESET"
  [ $# -gt 2 ] || return 0
  shift 2
  for l in "$@"; do printf '      %s%s%s\n' "$CCSEAT_C_MID" "$l" "$CCSEAT_C_RESET"; done
  return 0
}

ccseat__doc_bad() {
  CCSEAT__DOC_BAD=$((CCSEAT__DOC_BAD + 1))
  printf '  %s✗%s %s\n' "$CCSEAT_C_ORANGE" "$CCSEAT_C_RESET" "$1"
  [ -n "${2:-}" ] && printf '      %sfix: %s%s\n' "$CCSEAT_C_MID" "$2" "$CCSEAT_C_RESET"
  return 0
}

ccseat__doc_head() { printf '\n%s%s%s\n' "$CCSEAT_C_BOLD" "$1" "$CCSEAT_C_RESET"; }

ccseat__doc_install_hint() {
  if ccseat_is_macos; then printf 'brew install %s' "$1"
  elif command -v apt-get >/dev/null 2>&1; then printf 'sudo apt-get install -y %s' "$1"
  elif command -v dnf >/dev/null 2>&1; then printf 'sudo dnf install -y %s' "$1"
  elif command -v pacman >/dev/null 2>&1; then printf 'sudo pacman -S %s' "$1"
  else printf 'install %s with your package manager' "$1"; fi
}

ccseat__doc_tools() {
  local v bin
  ccseat__doc_head "Tools"
  ccseat__doc_ok "bash $BASH_VERSION"
  if command -v jq >/dev/null 2>&1; then
    # "jq-1.7.1-apple" reads as "jq 1.7.1".
    v=$(jq --version 2>/dev/null)
    v=${v#jq-}
    v=${v%%-*}
    case "$v" in [0-9]*) v="jq $v" ;; *) v=jq ;; esac
    ccseat__doc_ok "$v"
  else
    ccseat__doc_bad "jq is not installed" "$(ccseat__doc_install_hint jq)"
  fi
  if command -v curl >/dev/null 2>&1; then
    v=$(curl --version 2>/dev/null | head -n 1 | cut -d' ' -f1-2)
    case "$v" in curl\ *) ;; *) v=curl ;; esac
    ccseat__doc_ok "$v"
  else
    ccseat__doc_bad "curl is not installed" "$(ccseat__doc_install_hint curl)"
  fi
  if bin=$(ccseat_claude_bin); then
    v=$("$bin" --version </dev/null 2>/dev/null | head -n 1)
    ccseat__doc_ok "Claude Code ${v%% (*} ($(ccseat_tilde "$bin"))"
  else
    ccseat__doc_bad "Claude Code is not installed (no claude command)" \
      "curl -fsSL https://claude.ai/install.sh | bash"
  fi
  if ccseat_is_macos; then
    if command -v security >/dev/null 2>&1; then
      ccseat__doc_ok "macOS Keychain (security)"
    else
      ccseat__doc_warn "the security command is missing, so Keychain logins cannot be read"
    fi
  fi
}

# Shared items of a seat that are not linked to the primary (read-only).
ccseat__doc_links() {
  local dir="$1" item bad="" custom="" private=""
  for item in $(ccseat_share_items); do
    ccseat_never_shared "$item" && continue
    if [ -L "$dir/$item" ] && [ -e "$dir/$item" ]; then
      [ "$dir/$item" -ef "$CCSEAT_PRIMARY_DIR/$item" ] || custom="$custom $item"
    else
      bad="$bad $item"
    fi
  done
  for item in $CCSEAT_NEVER_SHARE; do
    if [ -L "$dir/$item" ] && [ -e "$CCSEAT_PRIMARY_DIR/$item" ] && [ "$dir/$item" -ef "$CCSEAT_PRIMARY_DIR/$item" ]; then
      private="$private $item"
    fi
  done
  CCSEAT__DOC_LBAD=${bad# } CCSEAT__DOC_LCUSTOM=${custom# } CCSEAT__DOC_LPRIVATE=${private# }
}

ccseat__doc_seats() {
  local i name dir e plan desc emails="" le other cur prim gc pm sm w=4 shown
  ccseat__doc_head "Seats"
  if ! command -v jq >/dev/null 2>&1; then
    ccseat__doc_info "needs jq to check"
    return 0
  fi
  ccseat__registry_ensure
  cur=$(ccseat_current_get 2>/dev/null)
  if [ "$CCSEAT_N" -eq 0 ]; then
    ccseat__doc_warn "no seats yet" "ccseat add"
  fi
  i=0
  while [ "$i" -lt "$CCSEAT_N" ]; do
    [ "${#CCSEAT_NAMES[i]}" -gt "$w" ] && w=${#CCSEAT_NAMES[i]}
    i=$((i + 1))
  done
  pm=""
  gc=$(ccseat_global_config "$CCSEAT_PRIMARY_DIR")
  if [ -f "$gc" ] && command -v jq >/dev/null 2>&1; then
    pm=$(jq -r '(.mcpServers // {}) | if type == "object" then keys | join(" ") else "" end' "$gc" 2>/dev/null)
  fi
  i=0
  while [ "$i" -lt "$CCSEAT_N" ]; do
    name=${CCSEAT_NAMES[i]}
    dir=${CCSEAT_DIRS[i]}
    i=$((i + 1))
    prim=""
    ccseat_is_primary_dir "$dir" && prim=", primary"
    [ "$name" = "$cur" ] && prim="$prim, current"
    if ! [ -d "$dir" ]; then
      ccseat__doc_bad "$name: folder missing ($(ccseat_tilde "$dir"))" "ccseat remove $name"
      continue
    fi
    ccseat_auth_check "$dir"
    plan=$(ccseat_plan_label "$CCSEAT_PLAN")
    e=$(ccseat_email "$dir" 2>/dev/null)
    shown=$(ccseat_pad "$name" "$w")
    desc="$shown "
    [ -n "$e" ] && desc="$desc $e"
    [ -n "$plan" ] && desc="$desc, $plan"
    case "$CCSEAT_AUTH" in
      ok) ccseat__doc_ok "$desc$prim" ;;
      expired) ccseat__doc_ok "$desc, idle, renews when opened$prim" ;;
      *) ccseat__doc_warn "$shown  not logged in$prim" "ccseat run $name  (Claude Code asks you to sign in)" ;;
    esac
    if [ -n "$e" ]; then
      le=$(printf '%s' "$e" | tr '[:upper:]' '[:lower:]')
      case " $emails " in
        *" $le="*)
          other=${emails#* "$le="}
          other=${other%% *}
          ccseat__doc_warn "$name and $other are the same account ($e), so they share one usage limit" "ccseat remove $name"
          ;;
      esac
      emails="$emails $le=$name"
    fi
    ccseat_is_primary_place "$dir" && continue
    ccseat__doc_links "$dir"
    if [ -n "$CCSEAT__DOC_LPRIVATE" ]; then
      ccseat__doc_bad "$name: $CCSEAT__DOC_LPRIVATE linked to the primary, but each seat needs its own" \
        "remove those links inside $(ccseat_tilde "$dir"), then: ccseat run $name"
    fi
    if [ -n "$CCSEAT__DOC_LBAD" ]; then
      # shellcheck disable=SC2086 # one word per item
      ccseat__doc_warn "$name does not share $(ccseat__join_and $CCSEAT__DOC_LBAD) yet" "ccseat sync $name"
    fi
    if [ -n "$CCSEAT__DOC_LCUSTOM" ]; then
      ccseat__doc_info "$name: $CCSEAT__DOC_LCUSTOM point somewhere other than ~/.claude (kept as you set them)"
    fi
    gc=$(ccseat_global_config "$dir")
    if [ -n "$pm" ] && command -v jq >/dev/null 2>&1; then
      sm=$(jq -r --arg want "$pm" '($want | split(" ")) - ((.mcpServers // {}) | keys) | join(" ")' "$gc" 2>/dev/null)
      [ -n "$sm" ] && ccseat__doc_warn "$name: missing MCP servers: $sm" "ccseat sync $name"
    fi
  done
  if ! ccseat_primary_name >/dev/null 2>&1 && [ -d "$CCSEAT_PRIMARY_DIR" ]; then
    ccseat_auth_check "$CCSEAT_PRIMARY_DIR"
    if [ "$CCSEAT_AUTH" != none ]; then
      ccseat__doc_warn "your Claude Code login in ~/.claude is not a seat" "ccseat add --dir ~/.claude"
    fi
  fi
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    ccseat__doc_info "$(ccseat_tilde "$dir") is logged in but not a seat" "add it with: ccseat add --dir $(ccseat_tilde "$dir")"
  done <<EOF
$(ccseat_find_other_dirs)
EOF
}

ccseat__doc_shell() {
  local sh rc f found=""
  ccseat__doc_head "Shell"
  sh=$(ccseat__detect_shell)
  if [ -z "$sh" ]; then
    ccseat__doc_warn "unknown shell (${SHELL:-unset}); ccseat supports zsh, bash and fish" \
      "ccseat setup --shell zsh   (or bash, or fish)"
  else
    rc=$(ccseat_rc_file "$sh")
    if [ -f "$rc" ] && { grep -qF "$CCSEAT_MARK_BEGIN" "$rc" || grep -Eq 'ccseat[[:space:]]+init' "$rc"; }; then
      found=$rc
    else
      for f in "$(ccseat__xdg "${XDG_CONFIG_HOME:-}" "$CCSEAT_USER_HOME/.config")/fish/config.fish" \
        "$CCSEAT_USER_HOME/.bashrc" "$CCSEAT_USER_HOME/.bash_profile" "$CCSEAT_USER_HOME/.profile"; do
        case "$sh:$f" in fish:*/config.fish|bash:*/.bash*|bash:*/.profile) ;; *) continue ;; esac
        if [ -f "$f" ] && grep -Eq 'ccseat[[:space:]]+init' "$f"; then found=$f; break; fi
      done
    fi
    if [ -n "$found" ]; then
      ccseat__doc_ok "$sh integration in $(ccseat_tilde "$found")"
      if [ -z "${CCSEAT_SHELL:-}" ]; then
        ccseat__doc_warn "not active in this terminal yet" "open a new terminal, or run: exec $sh"
      fi
    elif [ -n "${CCSEAT_SHELL:-}" ]; then
      ccseat__doc_ok "the claude command goes through ccseat in this shell"
    else
      if [ "$sh" = fish ]; then
        ccseat__doc_warn "the claude command does not switch seats yet (no shell integration)" \
          "ccseat setup" "or add to $(ccseat_tilde "$rc"): ccseat init fish | source"
      else
        ccseat__doc_warn "the claude command does not switch seats yet (no shell integration)" \
          "ccseat setup" "or add to $(ccseat_tilde "$rc"): eval \"\$(ccseat init $sh)\""
      fi
    fi
    ccseat__doc_alias "$sh"
  fi
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ -z "${CCSEAT_SEAT:-}" ]; then
    ccseat__doc_warn "CLAUDE_CONFIG_DIR is set ($(ccseat_tilde "$CLAUDE_CONFIG_DIR")), so claude opens it" \
      "remove that export to use the current seat"
  fi
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    ccseat__doc_warn "CLAUDE_CODE_OAUTH_TOKEN is set, so every seat would use that one token" \
      "remove it from your environment to use each seat's own login"
  fi
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    ccseat__doc_info "ANTHROPIC_API_KEY is set; Claude Code may bill that key instead of the seat's plan"
  fi
}

# An alias for claude set after ccseat's block wins over the claude
# function, so claude would skip ccseat. One set before it is removed by the
# integration itself.
ccseat__doc_alias() {
  local sh="$1" f line blk zd
  zd=$(ccseat_strip_slash "${ZDOTDIR:-$CCSEAT_USER_HOME}")
  case "$sh" in
    zsh) set -- "$zd/.zshrc" "$zd/.zlogin" "$CCSEAT_USER_HOME/.zsh_aliases" "$CCSEAT_USER_HOME/.aliases" ;;
    bash) set -- "$CCSEAT_USER_HOME/.bashrc" "$CCSEAT_USER_HOME/.bash_profile" "$CCSEAT_USER_HOME/.profile" \
      "$CCSEAT_USER_HOME/.bash_aliases" "$CCSEAT_USER_HOME/.aliases" ;;
    *) return 0 ;;
  esac
  for f in "$@"; do
    [ -f "$f" ] || continue
    line=$(grep -nE '^[[:space:]]*alias[[:space:]]+claude=' "$f" 2>/dev/null | tail -n 1 | cut -d: -f1)
    [ -n "$line" ] || continue
    blk=$(grep -nE 'ccseat[[:space:]]+init|^# >>> ccseat >>>$' "$f" 2>/dev/null | head -n 1 | cut -d: -f1)
    if [ -n "$blk" ]; then
      [ "$line" -gt "$blk" ] || continue
      ccseat__doc_warn "$(ccseat_tilde "$f") line $line makes claude an alias, so it skips ccseat" \
        "delete that line (ccseat finds that claude program by itself)"
    else
      case "$f" in */.profile|*/.bash_profile|*/.bashrc) continue ;; esac
      ccseat__doc_warn "$(ccseat_tilde "$f") line $line makes claude an alias, which can skip ccseat" \
        "delete that line (ccseat finds that claude program by itself)"
    fi
  done
  return 0
}

ccseat__doc_statusline() {
  ccseat__doc_head "Status line"
  if ! command -v jq >/dev/null 2>&1; then
    ccseat__doc_info "needs jq to check"
  elif ccseat__statusline_installed; then
    ccseat__doc_ok "shows the seat and its usage"
  elif ccseat__statusline_other; then
    ccseat__doc_info "you use your own status line" "to show seats there: ccseat statusline install"
  else
    ccseat__doc_info "not installed (optional)" "ccseat statusline install"
  fi
}

ccseat__doc_usage() {
  local cur err
  cur=$(ccseat_current_get 2>/dev/null) || return 0
  command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 || return 0
  ccseat__doc_head "Usage data"
  ccseat_auth_check "$(ccseat_seat_dir "$cur")"
  if [ "$CCSEAT_AUTH" != ok ]; then
    ccseat__doc_info "skipped: $cur has no fresh login to ask with"
    return 0
  fi
  if ccseat_usage_fetch "$cur" 8; then
    ccseat__doc_ok "the usage API answers for $cur"
    return 0
  fi
  err=$(ccseat_usage_err "$cur")
  case "$err" in
    offline) ccseat__doc_warn "could not reach api.anthropic.com" "check your connection or proxy; ccseat keeps using the last numbers" ;;
    auth) ccseat__doc_warn "the usage API refused the login of $cur" "open it once so Claude Code renews it: ccseat run $cur" ;;
    ratelimited) ccseat__doc_info "the usage API asked to slow down; numbers refresh in a minute" ;;
    "") ccseat__doc_info "another refresh was running; try again in a moment" ;;
    *) ccseat__doc_warn "the usage API gave an unexpected answer ($err)" "try again later" ;;
  esac
}

ccseat_cmd_doctor() {
  case "${1:-}" in
    -h|--help) ccseat_help doctor; return 0 ;;
    "") ;;
    *) ccseat_die_usage "doctor takes no arguments" doctor ;;
  esac
  CCSEAT__DOC_WARN=0 CCSEAT__DOC_BAD=0
  ccseat_colors_init 1
  printf '%sccseat %s%s  %s%s%s\n' "$CCSEAT_C_BOLD" "$CCSEAT_VERSION" "$CCSEAT_C_RESET" \
    "$CCSEAT_C_FAINT" "$(ccseat_tilde "${CCSEAT_SELF:-}")" "$CCSEAT_C_RESET"
  ccseat__doc_tools
  ccseat__doc_seats
  ccseat__doc_shell
  ccseat__doc_statusline
  ccseat__doc_usage
  printf '\n'
  if [ "$CCSEAT__DOC_BAD" -eq 0 ] && [ "$CCSEAT__DOC_WARN" -eq 0 ]; then
    printf '%sEverything looks good.%s\n' "$CCSEAT_C_GREEN" "$CCSEAT_C_RESET"
    return 0
  fi
  printf '%s, %s.\n' "$(ccseat__plural "$CCSEAT__DOC_BAD" problem)" "$(ccseat__plural "$CCSEAT__DOC_WARN" warning)"
  [ "$CCSEAT__DOC_BAD" -eq 0 ]
}
