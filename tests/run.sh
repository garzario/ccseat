#!/usr/bin/env bash
# Test runner for ccseat. No dependencies beyond bash, jq and the usual tools.
#
# Usage: tests/run.sh [-j N] [-v] [-k] [-t SECONDS] [PATTERN...]
#   PATTERN     run only tests whose "file:function" contains one of the patterns
#   -j N        run N tests at a time (default 1)
#   -v          print the output of passing tests too
#   -k          keep every sandbox (failed ones are always kept)
#   -t SECONDS  time limit per test (default 60)
#   -l          list the tests and exit
#
# Every tests/test_*.sh file holds functions named test_*. Each one runs in its
# own subshell with a fresh sandbox HOME, stubbed claude/curl (and security,
# trash and osascript on macOS) first on PATH. A test passes when it exits 0,
# is skipped when it exits 77, and fails otherwise.
#
# Environment: CCSEAT_TEST_BASH is the bash that "#!/usr/bin/env bash" scripts
# get inside the sandbox (default /bin/bash on macOS, so bash 3.2 is what runs);
# CCSEAT_TEST_TMP is where sandboxes go (default .tmp/tests in the repository).

set -u

TESTS_DIR=$(cd "$(dirname "$0")" && pwd -P)
REPO_ROOT=$(cd "$TESTS_DIR/.." && pwd -P)
export TESTS_DIR REPO_ROOT
# Checked after the run: no test may remove the program under test.
program="$REPO_ROOT/bin/ccseat" program_lib="$REPO_ROOT/lib/ccseat/core.sh"
export CCSEAT_TEST_ORIG_PATH="$PATH"

jobs=1 verbose=0 keep=0 timeout=60 list_only=0
patterns=""
while [ $# -gt 0 ]; do
  case "$1" in
    -j) jobs="${2:-1}"; shift ;;
    -j*) jobs="${1#-j}" ;;
    -v|--verbose) verbose=1 ;;
    -k|--keep) keep=1 ;;
    -t) timeout="${2:-60}"; shift ;;
    -l|--list) list_only=1 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "run.sh: unknown option: $1" >&2; exit 2 ;;
    *) patterns="$patterns$1"$'\n' ;;
  esac
  shift
done
case "$jobs" in ''|*[!0-9]*|0) echo "run.sh: -j needs a positive number" >&2; exit 2 ;; esac
case "$timeout" in ''|*[!0-9]*|0) echo "run.sh: -t needs a positive number" >&2; exit 2 ;; esac

if [ -z "${CCSEAT_TEST_BASH:-}" ] && [ "$(uname -s)" = Darwin ] && [ -x /bin/bash ]; then
  CCSEAT_TEST_BASH=/bin/bash
fi
export CCSEAT_TEST_BASH="${CCSEAT_TEST_BASH:-}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  c_ok=$'\033[38;2;120;140;93m' c_bad=$'\033[38;2;217;119;87m' c_dim=$'\033[38;2;176;174;165m' c_r=$'\033[0m'
else
  c_ok="" c_bad="" c_dim="" c_r=""
fi

command -v jq >/dev/null 2>&1 || { echo "run.sh: jq is required to run the tests" >&2; exit 1; }

# ---------- discovery ----------

selected() {
  local id="$1" p
  [ -z "$patterns" ] && return 0
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    case "$id" in *"$p"*) return 0 ;; esac
  done <<EOF
$patterns
EOF
  return 1
}

queue=""
total=0
for f in "$TESTS_DIR"/test_*.sh; do
  [ -f "$f" ] || continue
  while IFS= read -r fn; do
    [ -n "$fn" ] || continue
    id="$(basename "$f"):$fn"
    selected "$id" || continue
    queue="$queue$id"$'\n'
    total=$((total + 1))
  done <<EOF
$(sed -n 's/^\(test_[A-Za-z0-9_]*\)[[:space:]]*()[[:space:]]*{*.*$/\1/p' "$f")
EOF
done

if [ "$list_only" -eq 1 ]; then
  printf '%s' "$queue"
  exit 0
fi
if [ "$total" -eq 0 ]; then
  echo "run.sh: no tests matched" >&2
  exit 1
fi

base="${CCSEAT_TEST_TMP:-$REPO_ROOT/.tmp/tests}"
mkdir -p "$base" || exit 1
base=$(cd "$base" && pwd -P)
run_dir=$(mktemp -d "$base/run.XXXXXX") || exit 1

bash_used="${CCSEAT_TEST_BASH:-$(command -v bash)}"
# shellcheck disable=SC2016  # expanded by the bash being reported
printf '%sccseat tests: %s tests, bash %s (%s), %s%s\n' "$c_dim" "$total" \
  "$("$bash_used" -c 'echo "${BASH_VERSION%%(*}"')" "$bash_used" "$(uname -s)" "$c_r"

# ---------- running ----------

# Lists a process and its children (pid, state, elapsed time, command), so a
# timed-out test shows what it was waiting on.
dump_tree() {
  local pid="$1" indent="${2:-}" child
  printf '%s%s\n' "$indent" "$(ps -o pid=,stat=,etime=,args= -p "$pid" 2>/dev/null)"
  for child in $(pgrep -P "$pid" 2>/dev/null); do dump_tree "$child" "$indent  "; done
}

kill_tree() {
  local pid="$1" child
  for child in $(pgrep -P "$pid" 2>/dev/null); do kill_tree "$child"; done
  kill -TERM "$pid" 2>/dev/null
}

# Runs one test in the background; writes its exit code to <dir>/rc.
start_test() {
  local id="$1" tdir="$2" file fn
  file="${id%%:*}"
  fn="${id#*:}"
  mkdir -p "$tdir/sandbox"
  (
    (
      set -u
      # shellcheck source=lib.sh
      . "$TESTS_DIR/lib.sh"
      # shellcheck disable=SC1090
      . "$TESTS_DIR/$file"
      sandbox_setup "$tdir/sandbox"
      "$fn"
    ) </dev/null >"$tdir/log" 2>&1 &
    local pid=$!
    # Watchdog: marks the test as timed out only if it is still running, so a
    # watchdog that outlives a finished test (the kill below can race with it
    # on Linux) never turns a pass into a timeout.
    (
      sleep "$timeout"
      if kill -0 "$pid" 2>/dev/null; then
        : > "$tdir/timeout"
        dump_tree "$pid" > "$tdir/tree" 2>/dev/null
        kill_tree "$pid"
      fi
    ) </dev/null >/dev/null 2>&1 &
    local wd=$!
    wait "$pid"
    local rc=$?
    kill_tree "$wd"
    # Reaping the watchdog here keeps bash from printing "Terminated" for it.
    wait "$wd" 2>/dev/null
    printf '%s\n' "$rc" > "$tdir/rc.tmp" && mv "$tdir/rc.tmp" "$tdir/rc"
  ) &
}

passed=0 failed=0 skipped=0
failed_list=""
started_at=$(date +%s)

report() {
  local id="$1" dir="$2" rc
  rc=$(cat "$dir/rc")
  if [ -f "$dir/timeout" ]; then
    rc=124
    printf 'timed out after %s s\n' "$timeout" >> "$dir/log"
    if [ -s "$dir/tree" ]; then
      printf 'processes still running:\n' >> "$dir/log"
      sed 's/^/  /' "$dir/tree" >> "$dir/log"
    fi
  fi
  case "$rc" in
    0)
      passed=$((passed + 1))
      printf '%sPASS%s  %s\n' "$c_ok" "$c_r" "$id"
      if [ "$verbose" -eq 1 ] && [ -s "$dir/log" ]; then sed 's/^/      | /' "$dir/log"; fi
      [ "$keep" -eq 1 ] || rm -rf "${dir:?}"
      ;;
    77)
      skipped=$((skipped + 1))
      printf '%sSKIP%s  %s %s(%s)%s\n' "$c_dim" "$c_r" "$id" "$c_dim" "$(grep -m1 '^skipped:' "$dir/log" | sed 's/^skipped: //')" "$c_r"
      [ "$keep" -eq 1 ] || rm -rf "${dir:?}"
      ;;
    *)
      failed=$((failed + 1))
      failed_list="$failed_list  $id"$'\n'
      printf '%sFAIL%s  %s\n' "$c_bad" "$c_r" "$id"
      tail -n 60 "$dir/log" | sed 's/^/      | /'
      printf '      %ssandbox: %s%s\n' "$c_dim" "$dir/sandbox" "$c_r"
      ;;
  esac
}

running=""   # lines "id<TAB>dir"
n=0
remaining="$queue"
while [ -n "$remaining" ] || [ -n "$running" ]; do
  count=0
  [ -n "$running" ] && count=$(printf '%s' "$running" | grep -c .)
  if [ -n "$remaining" ] && [ "$count" -lt "$jobs" ]; then
    id="${remaining%%$'\n'*}"
    remaining="${remaining#*$'\n'}"
    n=$((n + 1))
    dir="$run_dir/$(printf '%03d' "$n")-$(printf '%s' "$id" | tr -c 'A-Za-z0-9_' '_')"
    mkdir -p "$dir"
    start_test "$id" "$dir"
    running="$running$id"$'\t'"$dir"$'\n'
    continue
  fi
  still=""
  while IFS=$'\t' read -r id dir; do
    [ -z "$id" ] && continue
    if [ -f "$dir/rc" ]; then
      report "$id" "$dir"
    else
      still="$still$id"$'\t'"$dir"$'\n'
    fi
  done <<EOF
$running
EOF
  if [ "$still" = "$running" ]; then sleep 0.1; fi
  running="$still"
done
wait 2>/dev/null

elapsed=$(( $(date +%s) - started_at ))
printf '\n'
# A test must never remove or trash the program under test.
if [ ! -f "$program" ] || [ ! -f "$program_lib" ]; then
  failed=$((failed + 1))
  failed_list="$failed_list  the program under test is gone: a test removed bin/ccseat or lib/ccseat"$'\n'
fi
if [ "$failed" -gt 0 ]; then
  printf '%sFailed:%s\n%s' "$c_bad" "$c_r" "$failed_list"
fi
printf '%s passed, %s failed, %s skipped in %s s\n' "$passed" "$failed" "$skipped" "$elapsed"

if [ "$failed" -eq 0 ] && [ "$keep" -eq 0 ]; then
  rmdir "$run_dir" 2>/dev/null
fi
[ "$failed" -eq 0 ]
