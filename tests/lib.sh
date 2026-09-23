# shellcheck shell=bash
# Helpers for the ccseat test suite: sandbox, fixtures and assertions.
# tests/run.sh sources this file and one test file inside a fresh subshell per
# test, then calls sandbox_setup before the test function.
#
# Globals a test can use (all set by sandbox_setup):
#   REPO_ROOT   the repository under test
#   T           the sandbox root; HOME is $T/home
#   STUB        state folder of the stubs (keychain/, usage/, logs)
#   OUT ERR RC  stdout, stderr and exit code of the last run/cs call

TESTS_DIR="${TESTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$TESTS_DIR/.." && pwd -P)}"
STUBS_DIR="$TESTS_DIR/stubs"
OUT="" ERR="" RC=0

# ---------- sandbox ----------

sandbox_setup() {
  T="$1"
  mkdir -p "$T/home" "$T/bin" "$T/stubbin" "$T/stub/usage" "$T/stub/keychain"
  STUB="$T/stub"
  export HOME="$T/home"
  export CCSEAT_STUB_DIR="$STUB"
  unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME CCSEAT_HOME \
    CLAUDE_CONFIG_DIR CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN \
    CCSEAT_NO_WRAP CCSEAT_YES CCSEAT_REF NO_COLOR FORCE_COLOR CLICOLOR_FORCE ZDOTDIR \
    CLAUDE_CODE_SESSION_ID CLAUDECODE CCSEAT_STUB_LOGIN_EMAIL CCSEAT_STUB_LOGIN_FAIL CCSEAT_STUB_LOGIN_DELAY \
    CCSEAT_STUB_CURL_FAIL CCSEAT_STUB_CURL_DELAY CCSEAT_TARBALL_URL CCSEAT_INSTALL_TTY \
    BASH_ENV ENV COLUMNS LINES CDPATH CCSEAT_SEAT CCSEAT_SHELL
  export TZ=UTC
  export TERM=xterm-256color
  export USER="${USER:-tester}"
  export SHELL=/bin/bash
  export GIT_CEILING_DIRECTORIES="$T"
  export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=Tester GIT_AUTHOR_EMAIL=tester@example.com \
    GIT_COMMITTER_NAME=Tester GIT_COMMITTER_EMAIL=tester@example.com
  if locale -a 2>/dev/null | grep -qx 'en_US.UTF-8'; then export LANG=en_US.UTF-8
  else export LANG=C.UTF-8; fi
  unset LC_ALL LC_CTYPE LC_TIME

  # Stubs: claude and curl everywhere; security, trash and osascript only on
  # macOS, where the real ones would reach the Keychain, Finder or the Trash.
  ln -s "$STUBS_DIR/claude" "$T/stubbin/claude"
  ln -s "$STUBS_DIR/curl" "$T/stubbin/curl"
  if [ "$(uname -s)" = Darwin ]; then
    ln -s "$STUBS_DIR/security" "$T/stubbin/security"
    ln -s "$STUBS_DIR/trash" "$T/stubbin/trash"
    ln -s "$STUBS_DIR/osascript" "$T/stubbin/osascript"
  fi
  # Scripts start with "#!/usr/bin/env bash": this bash is the one they get.
  if [ -n "${CCSEAT_TEST_BASH:-}" ]; then ln -s "$CCSEAT_TEST_BASH" "$T/bin/bash"; fi

  local base
  base=$(sandbox_base_path)
  export PATH="$T/bin:$T/stubbin:$REPO_ROOT/bin:$base"
  cd "$T" || exit 1
}

# System folders plus the folders of the tools the suite needs, so nothing
# from the developer's own ~/bin or ~/.local/bin leaks into a test.
sandbox_base_path() {
  local p="/usr/bin:/bin:/usr/sbin:/sbin" tool d
  for tool in jq git zsh fish make shellcheck shasum sha256sum script pgrep perl; do
    d=$(PATH="${CCSEAT_TEST_ORIG_PATH:-$PATH}" command -v "$tool" 2>/dev/null) || continue
    d=$(dirname "$d")
    case ":$p:" in *":$d:"*) ;; *) p="$p:$d" ;; esac
  done
  printf '%s' "$p"
}

# ---------- running commands ----------

# run CMD ARGS... : runs a command with stdin from /dev/null and captures
# OUT, ERR and RC. Never exits the test.
run() {
  "$@" </dev/null >"$T/.out" 2>"$T/.err"
  RC=$?
  OUT=$(cat "$T/.out")
  ERR=$(cat "$T/.err")
  return 0
}

# run_in DATA CMD ARGS... : like run, with DATA on stdin.
run_in() {
  local data="$1"
  shift
  printf '%s' "$data" | "$@" >"$T/.out" 2>"$T/.err"
  RC=$?
  OUT=$(cat "$T/.out")
  ERR=$(cat "$T/.err")
  return 0
}

# cs ARGS... : runs ccseat from the repository.
cs() { run ccseat "$@"; }

# cs_ok ARGS... : runs ccseat and fails the test when it does not exit 0.
cs_ok() {
  run ccseat "$@"
  [ "$RC" -eq 0 ] || fail "ccseat $* exited $RC"
}

# Runs a command inside a pseudo terminal, typing KEYS after a short pause.
# KEYS uses printf escapes, one key group per argument, sent 0.3 s apart.
# Usage: run_pty "KEY1" "KEY2" -- cmd args...
run_pty() {
  local keys="" cmdline="" a
  while [ $# -gt 0 ] && [ "$1" != -- ]; do keys="$keys${keys:+ }$(printf '%q' "$1")"; shift; done
  [ "${1:-}" = -- ] && shift
  for a in "$@"; do cmdline="$cmdline${cmdline:+ }$(printf '%q' "$a")"; done
  command -v script >/dev/null 2>&1 || skip "the script command is not available"
  printf '%s\n' "$keys" > "$T/.keys"
  # shellcheck disable=SC2016  # expanded by the inner shell
  local feeder='sleep 1.5; eval "set -- $(cat "$1")"; for k in "$@"; do printf "%b" "$k"; sleep 0.3; done; sleep 1.5'
  if [ "$(uname -s)" = Darwin ]; then
    bash -c "$feeder" _ "$T/.keys" | script -q /dev/null bash -c "$cmdline" >"$T/.out" 2>"$T/.err"
  else
    bash -c "$feeder" _ "$T/.keys" | script -qfec "$cmdline" /dev/null >"$T/.out" 2>"$T/.err"
  fi
  RC=$?
  OUT=$(tr -d '\r' < "$T/.out")
  ERR=$(cat "$T/.err")
  return 0
}

# ---------- assertions ----------

fail() {
  printf 'assertion failed: %s\n' "$*"
  if [ -n "$OUT$ERR" ]; then
    printf -- '--- last stdout (exit %s) ---\n%s\n' "$RC" "$OUT" | head -40
    printf -- '--- last stderr ---\n%s\n' "$ERR" | head -20
  fi
  exit 1
}

skip() {
  printf 'skipped: %s\n' "$*"
  exit 77
}

assert_eq() {
  [ "$1" = "$2" ] || fail "${3:-values differ}"$'\n'"  expected: $1"$'\n'"  actual:   $2"
}

assert_ne() {
  [ "$1" != "$2" ] || fail "${3:-values should differ}: both are '$1'"
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "${3:-text does not contain \"$2\"}"$'\n'"  text: $(printf '%s' "$1" | head -20)" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "${3:-text should not contain \"$2\"}"$'\n'"  text: $(printf '%s' "$1" | head -20)" ;;
  esac
}

# assert_match TEXT ERE [msg]
assert_match() {
  printf '%s\n' "$1" | grep -Eq -- "$2" || fail "${3:-text does not match /$2/}"$'\n'"  text: $(printf '%s' "$1" | head -20)"
}

assert_no_match() {
  if printf '%s\n' "$1" | grep -Eq -- "$2"; then
    fail "${3:-text should not match /$2/}"$'\n'"  text: $(printf '%s' "$1" | head -20)"
  fi
}

# assert_exit CODE [msg] : checks RC of the last run.
assert_exit() {
  [ "$RC" -eq "$1" ] || fail "${2:-exit code} (expected $1, got $RC)"
}

assert_success() { [ "$RC" -eq 0 ] || fail "${1:-command failed} (exit $RC)"; }
assert_failure() { [ "$RC" -ne 0 ] || fail "${1:-command should have failed} (exit 0)"; }

assert_file() { [ -f "$1" ] || fail "${2:-missing file: $1}"; }
assert_dir() { [ -d "$1" ] || fail "${2:-missing folder: $1}"; }
assert_no_path() { { [ ! -e "$1" ] && [ ! -L "$1" ]; } || fail "${2:-should not exist: $1}"; }

# assert_symlink PATH [TARGET] : PATH is a valid symlink (and resolves to TARGET).
assert_symlink() {
  [ -L "$1" ] || fail "not a symlink: $1"
  [ -e "$1" ] || fail "dangling symlink: $1 -> $(readlink "$1")"
  if [ -n "${2:-}" ]; then
    assert_eq "$(physical "$2")" "$(physical "$1")" "symlink $1 points elsewhere"
  fi
}

assert_not_symlink() { [ ! -L "$1" ] || fail "${2:-should not be a symlink: $1 -> $(readlink "$1")}"; }

assert_mode() {
  local m
  m=$(file_mode "$1")
  assert_eq "$2" "$m" "mode of $1"
}

assert_json() {
  # assert_json JSON JQ_FILTER [msg] : the filter must yield true.
  printf '%s' "$1" | jq -e "$2" >/dev/null 2>&1 || fail "${3:-JSON check failed: $2}"$'\n'"  json: $(printf '%s' "$1" | head -c 600)"
}

no_ansi() {
  case "$1" in
    *$'\033'*) fail "${2:-output has ANSI escape codes}" ;;
  esac
}

has_ansi() {
  case "$1" in
    *$'\033'*) ;;
    *) fail "${2:-output has no ANSI escape codes}" ;;
  esac
}

# ---------- portable helpers ----------

now_epoch() { date +%s; }

# epoch_fmt EPOCH FORMAT : date(1) formatting of an epoch in the local TZ.
epoch_fmt() {
  if date -r 0 +%s >/dev/null 2>&1; then
    LC_ALL=C date -r "$1" "+$2"
  else
    LC_ALL=C date -d "@$1" "+$2"
  fi
}

# "6:20 PM" style clock of an epoch, as ccseat prints it.
clock_of() { epoch_fmt "$1" '%I:%M %p' | sed 's/^0//'; }

file_mode() {
  if stat -c %a / >/dev/null 2>&1; then stat -c %a "$1"; else stat -f %Lp "$1"; fi
}

file_mtime() {
  if stat -c %Y / >/dev/null 2>&1; then stat -c %Y "$1"; else stat -f %m "$1"; fi
}

# set_age PATH SECONDS : sets the modification time SECONDS in the past.
set_age() {
  touch -t "$(epoch_fmt $(( $(now_epoch) - $2 )) '%Y%m%d%H%M.%S')" "$1"
}

physical() {
  local p="$1"
  if [ -d "$p" ]; then (cd "$p" && pwd -P); return; fi
  local d
  d=$(cd "$(dirname "$p")" 2>/dev/null && pwd -P) || { printf '%s' "$p"; return; }
  if [ -L "$p" ]; then
    local t
    t=$(readlink "$p")
    case "$t" in /*) ;; *) t="$d/$t" ;; esac
    physical "$t"
    return
  fi
  printf '%s/%s' "$d" "$(basename "$p")"
}

sha8() {
  if command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum -a 256 | cut -c1-8
  else printf '%s' "$1" | sha256sum | cut -c1-8; fi
}

# Pins TZ to a fixed offset where the local time is between 12:00 and 12:59,
# so "today", "tomorrow" and weekday resets are predictable at any hour.
# Sets MIDNIGHT to the epoch of today's local midnight.
pin_local_noon() {
  local now h off secs
  now=$(now_epoch)
  h=$(date -u +%H)
  h=${h#0}
  off=$(( 12 - h ))
  if [ "$off" -ge 0 ]; then export TZ="TST-$off"; else export TZ="TST+$(( -off ))"; fi
  secs=$(( (now + off * 3600) % 86400 ))
  # shellcheck disable=SC2034  # read by the test files
  MIDNIGHT=$(( now - secs ))
}

# iso EPOCH [FRACTION] : UTC ISO 8601 in the usage API's style,
# e.g. 2026-09-22T21:59:59.990000+00:00.
iso() {
  local s
  s=$(jq -rn --argjson e "$1" '$e | todate')
  printf '%s' "${s%Z}.${2:-000000}+00:00"
}

# ---------- fixtures ----------

token_for() { printf 'tok-%s' "$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '-')"; }

email_name() { printf '%s' "${1%@*}" | tr '[:upper:]' '[:lower:]'; }

ccseat_home() { printf '%s' "${CCSEAT_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/ccseat}"; }
seats_file() { printf '%s/seats' "$(ccseat_home)"; }
data_seats_dir() { printf '%s/ccseat/seats' "${XDG_DATA_HOME:-$HOME/.local/share}"; }
cache_dir() { printf '%s/ccseat' "${XDG_CACHE_HOME:-$HOME/.cache}"; }

# seat_dir NAME : config dir registered for NAME in the seats file.
seat_dir() { awk -F '\t' -v n="$1" '$1 == n { print $2; exit }' "$(seats_file)" 2>/dev/null; }

seat_names() { cut -f1 "$(seats_file)" 2>/dev/null; }

# Global config file Claude Code uses for a config dir ("" = the primary).
global_config() {
  local d="$1"
  if [ -z "$d" ] || [ "$(physical "$d")" = "$(physical "$HOME/.claude")" ]; then
    printf '%s/.claude.json' "$HOME"
  elif [ -f "$d/.config.json" ]; then
    printf '%s/.config.json' "$d"
  else
    printf '%s/.claude.json' "$d"
  fi
}

# write_credentials DIR EMAIL [expired] : a logged-in credentials file.
write_credentials() {
  local dir="$1" email="$2" exp
  if [ "${3:-}" = expired ]; then exp=$(( ($(now_epoch) - 3600) * 1000 ))
  else exp=$(( ($(now_epoch) + 8 * 3600) * 1000 )); fi
  mkdir -p "$dir"
  jq -n --arg t "$(token_for "$email")" --argjson e "$exp" '{claudeAiOauth: {
    accessToken: $t, refreshToken: ("ref-" + $t), expiresAt: $e,
    scopes: ["user:inference", "user:profile"], subscriptionType: "max"}}' > "$dir/.credentials.json"
  chmod 600 "$dir/.credentials.json"
}

# set_email GLOBAL_CONFIG EMAIL : merges oauthAccount.emailAddress.
set_email() {
  local f="$1" email="$2"
  [ -f "$f" ] || printf '{}\n' > "$f"
  jq --arg m "$email" '.oauthAccount = ((.oauthAccount // {}) + {emailAddress: $m})' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# make_primary EMAIL [expired] : the user's existing ~/.claude, logged in,
# with settings, memory, MCP servers and trusted folders.
make_primary() {
  local email="$1"
  mkdir -p "$HOME/.claude/skills/hello" "$HOME/.claude/agents" "$HOME/.claude/commands" "$HOME/.claude/projects"
  write_credentials "$HOME/.claude" "$email" "${2:-}"
  printf '{\n  "model": "opus",\n  "theme": "dark"\n}\n' > "$HOME/.claude/settings.json"
  printf '# Memory\nBe brief.\n' > "$HOME/.claude/CLAUDE.md"
  printf -- '---\nname: hello\n---\nSay hello.\n' > "$HOME/.claude/skills/hello/SKILL.md"
  printf '{"display":"hi"}\n' > "$HOME/.claude/history.jsonl"
  jq -n --arg m "$email" --arg a "$HOME/work/app" --arg b "$HOME/work/untrusted" '{
    numStartups: 12,
    hasCompletedOnboarding: true,
    oauthAccount: {emailAddress: $m, accountUuid: "uuid-primary"},
    mcpServers: {
      github: {type: "stdio", command: "gh-mcp", args: ["--stdio"], env: {GITHUB_TOKEN: "secret-value"}},
      docs: {type: "http", url: "https://example.com/mcp"}
    },
    projects: {
      ($a): {hasTrustDialogAccepted: true, allowedTools: []},
      ($b): {hasTrustDialogAccepted: false}
    }
  }' > "$HOME/.claude.json"
}

# login_seat_dir DIR EMAIL [expired] : an extra config dir logged in as EMAIL.
login_seat_dir() {
  local dir="$1" email="$2"
  mkdir -p "$dir"
  write_credentials "$dir" "$email" "${3:-}"
  set_email "$(global_config "$dir")" "$email"
}

# usage_fixture EMAIL P5 R5 P7 R7 : what the usage API returns for EMAIL's
# token. R5 and R7 are epochs (resets at EPOCH - 0.01 s, like the real API)
# or "-" for no reset.
usage_fixture() {
  local email="$1" p5="$2" r5="$3" p7="$4" r7="$5" i5=null i7=null
  [ "$r5" != - ] && i5="\"$(iso $(( r5 - 1 )) 990000)\""
  [ "$r7" != - ] && i7="\"$(iso $(( r7 - 1 )) 990000)\""
  mkdir -p "$STUB/usage"
  cat > "$STUB/usage/$(token_for "$email").json" <<EOF
{"five_hour":{"utilization":$p5,"resets_at":$i5},"seven_day":{"utilization":$p7,"resets_at":$i7},"seven_day_oauth_apps":null,"seven_day_opus":null,"extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,"utilization":null}}
EOF
}

# add_seat EMAIL [ccseat add options...] : adds a seat through the CLI,
# logging in as EMAIL. Fails the test when it does not work.
add_seat() {
  local email="$1"
  shift
  CCSEAT_STUB_LOGIN_EMAIL="$email" run ccseat add "$@"
  [ "$RC" -eq 0 ] || fail "ccseat add ($email) exited $RC"
}

# Lines launched by the claude stub: "<config dir or <unset>>\t<args>".
launches() { cat "$STUB/launches" 2>/dev/null; }
last_launch() { tail -n 1 "$STUB/launches" 2>/dev/null; }
launch_count() { if [ -f "$STUB/launches" ]; then wc -l < "$STUB/launches" | tr -d ' '; else echo 0; fi; }

# Folder a config dir resolves to, for comparing with CLAUDE_CONFIG_DIR values.
same_dir() { [ "$(physical "$1")" = "$(physical "$2")" ]; }

# exists_glob PATTERN_RESULTS... : true when a glob matched something.
exists_glob() {
  local f
  for f in "$@"; do { [ -e "$f" ] || [ -L "$f" ]; } && return 0; done
  return 1
}

# in_trash NAME : a file or folder named NAME (or NAME plus a suffix) is in
# the sandbox Trash (macOS ~/.Trash or the freedesktop Trash).
in_trash() {
  exists_glob "$HOME/.Trash/$1"* "$HOME/.local/share/Trash/files/$1"*
}

# Everything the user can see after a command, used to check that no token
# ever leaks into output.
assert_no_tokens() {
  assert_not_contains "$OUT$ERR" "tok-" "a token leaked into the output"
}

# make_workflow_fixture SID RUN NAME [PROJECTS_ROOT] : a running workflow in a
# session, laid out like Claude Code 2.1 does it. Phase 2 of 3 ("Build") with
# two agents started: "core" finished, "tests" still running.
make_workflow_fixture() {
  local sid="$1" run="$2" name="$3" root="${4:-$HOME/.claude/projects}" sd wd
  sd="$root/-work-proj/$sid"
  wd="$sd/subagents/workflows/$run"
  mkdir -p "$wd" "$sd/workflows/scripts"
  cat > "$sd/workflows/scripts/$name-$run.js" <<JS
export const meta = {
  name: '$name',
  description: 'Fixture workflow',
  phases: [
    { title: 'Plan' },
    { title: 'Build' },
    { title: 'Verify' },
  ],
}

export default async function run() {}
JS
  cat > "$wd/journal.jsonl" <<JSONL
{"type":"started","key":"core","agentId":"a1","label":"core","phase":"Build"}
{"type":"started","key":"tests","agentId":"a2","label":"tests","phase":"Build"}
{"type":"result","key":"core","agentId":"a1"}
JSONL
  printf '{"agentType":"general-purpose"}\n' > "$wd/agent-a1.meta.json"
  printf '{"agentType":"general-purpose"}\n' > "$wd/agent-a2.meta.json"
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{}}]}}\n' > "$wd/agent-a1.jsonl"
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{}}]}}\n' > "$wd/agent-a2.jsonl"
  # shellcheck disable=SC2034  # read by the test files
  WF_SESSION_DIR="$sd" WF_RUN_DIR="$wd"
}

# make_background_agent SESSION_DIR ID DESCRIPTION : an agent started with the
# Agent tool in the background, still running.
make_background_agent() {
  local sd="$1" id="$2" desc="$3"
  mkdir -p "$sd/subagents"
  jq -nc --arg d "$desc" '{requestShape: "background", description: $d, agentType: "Explore"}' > "$sd/subagents/agent-$id.meta.json"
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t9","name":"Grep","input":{}}]}}\n' > "$sd/subagents/agent-$id.jsonl"
}

# path_without TOOL... : prints a PATH made of the sandbox PATH minus the given
# tools (a folder of links to everything else), to check missing dependencies.
path_without() {
  local farm d f b skip_it t old_ifs
  farm="$T/path-without-$(printf '%s' "$*" | tr -c 'A-Za-z0-9' '_')"
  if [ ! -d "$farm" ]; then
    mkdir -p "$farm"
    old_ifs=$IFS
    IFS=:
    for d in $PATH; do
      IFS=$old_ifs
      [ -d "$d" ] || continue
      for f in "$d"/*; do
        b=${f##*/}
        [ -x "$f" ] && [ ! -d "$f" ] || continue
        [ -e "$farm/$b" ] || [ -L "$farm/$b" ] && continue
        skip_it=0
        for t in "$@"; do [ "$b" = "$t" ] && skip_it=1; done
        [ "$skip_it" -eq 1 ] && continue
        ln -s "$f" "$farm/$b"
      done
    done
    IFS=$old_ifs
  fi
  printf '%s' "$farm"
}

# widest_line TEXT : the width in characters of the longest line, without
# escape codes (screen redraws split lines too).
widest_line() {
  local line n w=0 esc
  esc=$(printf '\033')
  while IFS= read -r line; do
    n=$(printf '%s' "$line" | sed "s/${esc}\\[[0-9;?]*[A-Za-z]//g" | tr -d '\r' | wc -m | tr -d ' ')
    [ "$n" -gt "$w" ] && w=$n
  done <<END_TEXT
$(printf '%s\n' "$1" | sed "s/${esc}\\[H${esc}\\[J/\\
/g")
END_TEXT
  printf '%s' "$w"
}

# frame_count TEXT : how many times the picker redrew the screen.
frame_count() {
  local esc
  esc=$(printf '\033')
  printf '%s' "$1" | grep -o "${esc}\\[H${esc}\\[J" | grep -c .
}

# write_usage_json EMAIL JSON : the usage API answer for EMAIL's token, as is.
write_usage_json() {
  mkdir -p "$STUB/usage"
  printf '%s\n' "$2" > "$STUB/usage/$(token_for "$1").json"
}
