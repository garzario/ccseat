# shellcheck shell=bash
# shellcheck disable=SC2034 # globals set here are read by the other library files
# ccseat auth: where each seat keeps its login, whether it is logged in, and
# which account it is.
#
# Claude Code stores the login of a config dir in the macOS Keychain under
# "Claude Code-credentials" when CLAUDE_CONFIG_DIR is unset, and under
# "Claude Code-credentials-<first 8 hex of sha256(dir)>" when it is set, with
# the user name as account. Elsewhere (and as a fallback) it uses
# <dir>/.credentials.json. The account itself is in the global config:
# ~/.claude.json for the primary, <dir>/.claude.json for other dirs, or the
# legacy <dir>/.config.json when that file exists.
#
# Tokens stay in shell variables and pipes: they are never printed, never
# written to disk and never passed as command-line arguments.

CCSEAT_KC_BASE="Claude Code-credentials"

# Path of Claude Code's global config file for a config dir.
ccseat_global_config() {
  local d
  d=$(ccseat_strip_slash "${1:-}")
  if [ -f "$d/.config.json" ]; then
    printf '%s' "$d/.config.json"
  elif ccseat_is_primary_dir "$d"; then
    printf '%s' "$CCSEAT_USER_HOME/.claude.json"
  else
    printf '%s' "$d/.claude.json"
  fi
}

ccseat_sha256() {
  local out
  if command -v sha256sum >/dev/null 2>&1; then
    out=$(printf '%s' "$1" | sha256sum 2>/dev/null)
  elif command -v shasum >/dev/null 2>&1; then
    out=$(printf '%s' "$1" | shasum -a 256 2>/dev/null)
  else
    out=$(printf '%s' "$1" | openssl dgst -sha256 -r 2>/dev/null)
  fi
  printf '%s' "${out%% *}"
}

ccseat_kc_service() {
  local d h
  d=$(ccseat_strip_slash "${1:-}")
  if ccseat_is_primary_dir "$d"; then
    printf '%s' "$CCSEAT_KC_BASE"
    return
  fi
  h=$(ccseat_sha256 "$d")
  printf '%s-%s' "$CCSEAT_KC_BASE" "${h:0:8}"
}

ccseat_kc_account() {
  local u="${USER:-}"
  [ -n "$u" ] || u=$(id -un 2>/dev/null)
  case "$u" in ''|*[!a-zA-Z0-9._-]*) u="claude-code-user" ;; esac
  printf '%s' "$u"
}

ccseat__kc_read() {
  local svc="$1" blob
  blob=$(security find-generic-password -a "$(ccseat_kc_account)" -s "$svc" -w 2>/dev/null)
  [ -n "$blob" ] || blob=$(security find-generic-password -s "$svc" -w 2>/dev/null)
  # security prints payloads with non-printable bytes as hex.
  case "$blob" in
    ""|"{"*) ;;
    *)
      if printf '%s' "$blob" | grep -Eq '^[0-9a-fA-F]+$'; then
        if command -v xxd >/dev/null 2>&1; then
          blob=$(printf '%s' "$blob" | xxd -r -p 2>/dev/null)
        else
          blob=$(printf '%s' "$blob" | perl -pe 's/([0-9a-fA-F]{2})/chr hex $1/ge' 2>/dev/null)
        fi
      fi ;;
  esac
  printf '%s' "$blob"
}

# The credential JSON of a config dir, or nothing. Only ever captured into a
# variable by the callers below.
ccseat__cred_blob() {
  local d blob=""
  d=$(ccseat_strip_slash "${1:-}")
  if ccseat_is_macos && command -v security >/dev/null 2>&1; then
    blob=$(ccseat__kc_read "$(ccseat_kc_service "$d")")
    if [ -z "$blob" ] && ccseat_is_primary_dir "$d"; then
      # The primary opened with CLAUDE_CONFIG_DIR=~/.claude uses a hashed name.
      blob=$(ccseat__kc_read "$CCSEAT_KC_BASE-$(ccseat_sha256 "$d" | cut -c1-8)")
    fi
  fi
  if [ -z "$blob" ] && [ -f "$d/.credentials.json" ]; then
    blob=$(cat "$d/.credentials.json" 2>/dev/null)
  fi
  printf '%s' "$blob"
}

# Loads the login of a config dir into CCSEAT_TOKEN, CCSEAT_TOKEN_EXP (ms,
# 0 when unknown), CCSEAT_TOKEN_REFRESH (1 when a refresh token exists) and
# CCSEAT_TOKEN_PLAN. Returns 1 when the dir has no login. Callers clear
# CCSEAT_TOKEN as soon as they are done with it.
ccseat_token_load() {
  local blob line
  CCSEAT_TOKEN="" CCSEAT_TOKEN_EXP=0 CCSEAT_TOKEN_REFRESH=0 CCSEAT_TOKEN_PLAN=""
  blob=$(ccseat__cred_blob "${1:-}")
  [ -n "$blob" ] || return 1
  line=$(printf '%s' "$blob" | jq -r '
    (.claudeAiOauth // {}) as $o
    | if ($o.accessToken // "") == "" then empty
      else [$o.accessToken, ($o.expiresAt // 0 | tostring),
            (if ($o.refreshToken // "") != "" then "1" else "0" end),
            ($o.rateLimitTier // $o.subscriptionType // "" | tostring)] | join("\t") end' 2>/dev/null)
  blob=""
  [ -n "$line" ] || return 1
  # Split in memory: a here-string would put the token in a temporary file
  # (bash 3.2 backs here-strings with one).
  CCSEAT_TOKEN=${line%%"$CCSEAT_TAB"*}
  line=${line#*"$CCSEAT_TAB"}
  CCSEAT_TOKEN_EXP=${line%%"$CCSEAT_TAB"*}
  line=${line#*"$CCSEAT_TAB"}
  CCSEAT_TOKEN_REFRESH=${line%%"$CCSEAT_TAB"*}
  CCSEAT_TOKEN_PLAN=${line#*"$CCSEAT_TAB"}
  line=""
  case "$CCSEAT_TOKEN_EXP" in ''|*[!0-9]*) CCSEAT_TOKEN_EXP=0 ;; esac
  [ -n "$CCSEAT_TOKEN" ]
}

# Sets CCSEAT_AUTH to ok, expired (Claude Code renews it the next time the
# seat opens) or none, and CCSEAT_PLAN to the raw plan name.
ccseat_auth_check() {
  CCSEAT_AUTH=none CCSEAT_PLAN=""
  if ! ccseat_token_load "${1:-}"; then
    CCSEAT_TOKEN=""
    return 0
  fi
  CCSEAT_TOKEN=""
  CCSEAT_PLAN=$CCSEAT_TOKEN_PLAN
  ccseat__now_init
  if [ "$CCSEAT_TOKEN_EXP" -gt 0 ] && [ "$CCSEAT_TOKEN_EXP" -le $(( CCSEAT_NOW * 1000 )) ]; then
    CCSEAT_AUTH=expired
  else
    CCSEAT_AUTH=ok
  fi
}

ccseat_auth_state() {
  ccseat_auth_check "${1:-}"
  printf '%s' "$CCSEAT_AUTH"
}

ccseat_is_logged_in() {
  ccseat_auth_check "${1:-}"
  [ "$CCSEAT_AUTH" != none ]
}

# Friendly plan name from subscriptionType or rateLimitTier.
ccseat_plan_label() {
  local p
  p=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  case "$p" in
    *max*20x*) printf 'Max 20x' ;;
    *max*5x*) printf 'Max 5x' ;;
    *max*) printf 'Max' ;;
    *pro*) printf 'Pro' ;;
    *team*) printf 'Team' ;;
    *enterprise*) printf 'Enterprise' ;;
    '') ;;
    *) printf '%s' "$1" ;;
  esac
}

# Login email of a config dir, from its global config (no process started).
ccseat_email() {
  local gc e
  gc=$(ccseat_global_config "${1:-}")
  [ -f "$gc" ] || return 1
  e=$(jq -r '.oauthAccount.emailAddress // empty' "$gc" 2>/dev/null)
  [ -n "$e" ] || return 1
  printf '%s' "$e"
}

# Email as Claude Code itself reports it ("claude auth status --json").
ccseat_email_live() {
  local d bin out e
  d=$(ccseat_strip_slash "${1:-}")
  bin=$(ccseat_claude_bin) || return 1
  if ccseat_is_primary_dir "$d"; then
    out=$(env -u CLAUDE_CONFIG_DIR -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN \
      "$bin" auth status --json </dev/null 2>/dev/null)
  else
    out=$(env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR="$d" \
      "$bin" auth status --json </dev/null 2>/dev/null)
  fi
  e=$(printf '%s' "$out" | jq -r '.email // empty' 2>/dev/null)
  [ -n "$e" ] || return 1
  printf '%s' "$e"
}

# Local part of the login email, lowercased (what a seat is named after).
ccseat_email_name() {
  local e
  e=$(ccseat_email "${1:-}") || return 1
  printf '%s' "${e%%@*}" | tr '[:upper:]' '[:lower:]'
}

# ---------- the Claude Code binary ----------

# Path of the real claude program (never the shell function, never ccseat).
ccseat_claude_bin() {
  local c me cand
  if [ -n "${CCSEAT_CLAUDE:-}" ]; then
    printf '%s' "$CCSEAT_CLAUDE"
    return 0
  fi
  if [ -n "${CCSEAT__CLAUDE_BIN:-}" ]; then
    printf '%s' "$CCSEAT__CLAUDE_BIN"
    return 0
  fi
  me=${CCSEAT_SELF:-}
  for cand in "$(type -P claude 2>/dev/null)" "$CCSEAT_USER_HOME/.local/bin/claude" \
    "$CCSEAT_USER_HOME/.claude/local/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
    [ -n "$cand" ] && [ -x "$cand" ] || continue
    c=$cand
    if [ -n "$me" ] && [ "$(ccseat_realpath "$c")" = "$me" ]; then
      continue
    fi
    CCSEAT__CLAUDE_BIN=$c
    printf '%s' "$c"
    return 0
  done
  return 1
}

ccseat_need_claude() {
  ccseat_claude_bin >/dev/null && return 0
  ccseat_die "Claude Code is not installed (the claude command was not found)" \
    "Install it with: curl -fsSL https://claude.ai/install.sh | bash" \
    "Then run this again."
}

# Resolves symlinks of a file path, portably (no readlink -f on old macOS).
ccseat_realpath() {
  local p="${1:-}" d l n=0
  while [ -L "$p" ] && [ "$n" -lt 40 ]; do
    d=$(cd -P "$(dirname "$p")" 2>/dev/null && pwd) || break
    l=$(readlink "$p") || break
    case "$l" in /*) p=$l ;; *) p="$d/$l" ;; esac
    n=$((n + 1))
  done
  d=$(cd -P "$(dirname "$p")" 2>/dev/null && pwd) || { printf '%s' "$p"; return; }
  printf '%s/%s' "$d" "$(basename "$p")"
}

# Runs the claude program for a config dir: CLAUDE_CONFIG_DIR unset for the
# primary, set to the dir otherwise.
ccseat_claude_in() {
  local d bin
  d=$(ccseat_strip_slash "$1")
  shift
  bin=$(ccseat_claude_bin) || return 127
  if ccseat_is_primary_dir "$d"; then
    env -u CLAUDE_CONFIG_DIR "$bin" "$@"
  else
    CLAUDE_CONFIG_DIR="$d" "$bin" "$@"
  fi
}

# Runs "claude auth login" in a config dir on the user's terminal.
ccseat_login() {
  local d="$1" email="${2:-}"
  if [ -n "$email" ]; then
    ccseat_claude_in "$d" auth login --email "$email"
  else
    ccseat_claude_in "$d" auth login
  fi
}
