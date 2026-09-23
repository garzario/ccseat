# shellcheck shell=bash
# "ccseat statusline": rendering from Claude Code's stdin JSON, and
# "statusline install|uninstall".

# statusline_input CWD [extra jq merge] : the JSON Claude Code sends.
statusline_input() {
  jq -nc --arg cwd "$1" --argjson fa "${FA:-0}" --argjson wa "${WA:-0}" '{
    session_id: "sess-1",
    transcript_path: "/dev/null",
    cwd: $cwd,
    model: {id: "claude-opus-4-5", display_name: "Opus 4.5 (1M context)"},
    workspace: {current_dir: $cwd, project_dir: $cwd},
    version: "2.1.280",
    effort: {level: "high"},
    context_window: {used_percentage: 42.4},
    rate_limits: {
      five_hour: {used_percentage: 23, resets_at: $fa},
      seven_day: {used_percentage: 61, resets_at: $wa}
    }
  }' | jq -c "${2:-.}"
}

# Rows without colors and without the blank-looking U+2800 some rows start with.
plain_rows() { printf '%s\n' "$OUT" | sed 's/^⠀*//'; }
row() { plain_rows | sed -n "${1}p"; }

test_statusline_rows() {
  pin_local_noon
  make_primary alice@example.com
  mkdir -p "$HOME/work/proj"
  FA=$((MIDNIGHT + 18 * 3600 + 20 * 60)) WA=$((MIDNIGHT + 3 * 86400 + 6 * 3600))
  export NO_COLOR=1
  cs_ok list
  run_in "$(statusline_input "$HOME/work/proj")" ccseat statusline
  assert_success
  no_ansi "$OUT" "NO_COLOR turns colors off"
  assert_eq 3 "$(plain_rows | grep -c .)" "three rows while nothing runs"
  assert_match "$(row 1)" 'alice.*Opus 4\.5.*high effort.*proj.*context 42%' "row 1: seat, model, effort, folder, context"
  assert_not_contains "$(row 1)" "(1M context)"
  assert_match "$(row 2)" '^5-hour +[●○]{10} +23% +resets 6:20 PM' "row 2: 5-hour usage"
  assert_match "$(row 3)" "^weekly +[●○]{10} +61% +resets $(epoch_fmt "$WA" %A) 6:00 AM" "row 3: weekly usage"
  assert_contains "$(row 2)" "●●○○○○○○○○" "23% fills two of ten dots"
}

test_statusline_colors_by_default() {
  make_primary alice@example.com
  cs_ok list
  run_in "$(statusline_input "$HOME")" ccseat statusline
  has_ansi "$OUT" "the status line is colored even though stdout is a pipe"
  assert_contains "$OUT" "38;2;" "24-bit colors"
}

test_statusline_colors_off_in_config() {
  make_primary alice@example.com
  cs_ok config colors never
  run_in "$(statusline_input "$HOME")" ccseat statusline
  no_ansi "$OUT"
}

test_statusline_names_the_seat_from_the_config_dir() {
  make_primary alice@example.com
  add_seat bob@example.com
  export NO_COLOR=1
  CLAUDE_CONFIG_DIR="$(seat_dir bob)" run_in "$(statusline_input "$HOME")" ccseat statusline
  assert_match "$(row 1)" '^bob ' "bob's sessions show bob"
  run_in "$(statusline_input "$HOME")" ccseat statusline
  assert_match "$(row 1)" '^alice ' "the primary shows alice"
}

test_statusline_git_branch_and_changes() {
  make_primary alice@example.com
  export NO_COLOR=1
  mkdir -p "$HOME/repo"
  git -C "$HOME/repo" init -q -b feature/login 2>/dev/null || { git -C "$HOME/repo" init -q && git -C "$HOME/repo" checkout -q -b feature/login; }
  printf 'x\n' > "$HOME/repo/a.txt"
  git -C "$HOME/repo" add a.txt && git -C "$HOME/repo" commit -qm init
  run_in "$(statusline_input "$HOME/repo")" ccseat statusline
  assert_contains "$(row 1)" "repo (feature/login)"
  printf 'y\n' >> "$HOME/repo/a.txt"
  run_in "$(statusline_input "$HOME/repo")" ccseat statusline
  assert_contains "$(row 1)" "repo (feature/login*)" "uncommitted changes are marked"
}

test_statusline_ultracode() {
  make_primary alice@example.com
  jq '.ultracode = true' "$HOME/.claude/settings.json" > "$T/s" && mv "$T/s" "$HOME/.claude/settings.json"
  run_in "$(statusline_input "$HOME" '.effort.level = "xhigh"')" ccseat statusline
  assert_contains "$OUT" "ultracode"
  assert_contains "$OUT" "167;139;250" "ultracode in purple"
}

test_statusline_high_context_and_usage_alerts() {
  make_primary alice@example.com
  run_in "$(statusline_input "$HOME" '.context_window.used_percentage = 91 | .rate_limits.five_hour.used_percentage = 90')" ccseat statusline
  assert_contains "$OUT" "217;119;87" "orange for alerts"
}

test_statusline_uses_the_cache_before_the_first_reply() {
  local now
  now=$(now_epoch)
  make_primary alice@example.com
  usage_fixture alice@example.com 17 $((now + 7200)) 58 $((now + 86400 * 2))
  cs_ok usage alice
  export NO_COLOR=1
  run_in "$(statusline_input "$HOME" 'del(.rate_limits)')" ccseat statusline
  assert_match "$(row 2)" '5-hour.* 17%'
  assert_match "$(row 3)" 'weekly.* 58%'
}

test_statusline_without_any_usage_data() {
  make_primary alice@example.com
  export NO_COLOR=1
  : > "$STUB/curl_fail"
  run_in "$(statusline_input "$HOME" 'del(.rate_limits)')" ccseat statusline
  assert_success
  assert_eq 2 "$(plain_rows | grep -c .)"
  assert_contains "$(row 2)" "no data"
}

test_statusline_never_waits_for_the_network() {
  local start took
  make_primary alice@example.com
  printf '8\n' > "$STUB/curl_delay"
  start=$(now_epoch)
  run_in "$(statusline_input "$HOME" 'del(.rate_limits)')" ccseat statusline
  took=$(( $(now_epoch) - start ))
  assert_success
  [ "$took" -le 3 ] || fail "the status line took $took s with a slow API"
}

test_statusline_survives_bad_input() {
  make_primary alice@example.com
  run_in "" ccseat statusline
  assert_success "empty stdin"
  assert_ne "" "$OUT" "prints something"
  run_in "{not json" ccseat statusline
  assert_success "invalid JSON"
  assert_ne "" "$OUT"
  run_in '{"model":{}}' ccseat statusline
  assert_success "sparse JSON"
}

test_statusline_running_row() {
  make_primary alice@example.com
  make_workflow_fixture sess-1 wf_abc ship
  export NO_COLOR=1
  run_in "$(statusline_input "$HOME")" ccseat statusline
  assert_eq 4 "$(plain_rows | grep -c .)" "a fourth row while a workflow runs"
  assert_match "$(row 4)" '^running +ship ' "row 4 names the workflow"
  assert_contains "$(row 4)" "phase 2 of 3"
  assert_contains "$(row 4)" "1 of 2 agents done"
}

test_statusline_has_no_abbreviations() {
  make_primary alice@example.com
  make_workflow_fixture sess-1 wf_abc ship
  export NO_COLOR=1
  run_in "$(statusline_input "$HOME")" ccseat statusline
  assert_no_match "$OUT" '(^|[^a-z0-9-])(5h|wk|ctx|7d)([^a-z]|$)' "no abbreviations"
}

# ---------- install / uninstall ----------

test_statusline_install_and_uninstall() {
  local f before
  make_primary alice@example.com
  add_seat bob@example.com
  f="$HOME/.claude/settings.json"
  jq '.statusLine = {type: "command", command: "bash ~/old-line.sh"} | .hooks = {Stop: []}' "$f" > "$T/s" && mv "$T/s" "$f"
  before=$(jq -S . "$f")
  cs_ok statusline install
  assert_json "$(cat "$f")" '.statusLine.command | test("ccseat[\"'"'"']? statusline$")' "points at ccseat statusline"
  assert_json "$(cat "$f")" '.model == "opus" and .hooks.Stop == []' "other settings kept"
  exists_glob "$(ccseat_home)"/backups/claude-settings.json.* || fail "a backup is written to ccseat's backups folder"
  exists_glob "$HOME/.claude"/settings.json.ccseat-backup-* && fail "no backups are left in ~/.claude"
  assert_symlink "$(seat_dir bob)/settings.json" "$f"
  assert_json "$(cat "$(seat_dir bob)/settings.json")" '.statusLine.command | test("statusline")' "every seat shares it"
  cs_ok statusline install
  assert_contains "$OUT" "already"
  cs_ok statusline uninstall
  assert_eq "$before" "$(jq -S . "$f")" "uninstall puts the previous status line back"
}

test_statusline_install_without_settings() {
  mkdir -p "$HOME/.claude"
  write_credentials "$HOME/.claude" alice@example.com
  set_email "$HOME/.claude.json" alice@example.com
  cs_ok statusline install
  assert_json "$(cat "$HOME/.claude/settings.json")" '.statusLine.type == "command"'
  cs_ok statusline uninstall
  assert_json "$(cat "$HOME/.claude/settings.json")" 'has("statusLine") | not'
}

test_statusline_install_refuses_invalid_json() {
  make_primary alice@example.com
  printf '{ broken\n' > "$HOME/.claude/settings.json"
  cs statusline install
  assert_failure
  assert_eq '{ broken' "$(cat "$HOME/.claude/settings.json")" "left untouched"
}

test_statusline_full_input_fixture() {
  make_primary alice@example.com
  mkdir -p "$HOME/work/proj"
  export NO_COLOR=1
  run_in "$(sed "s#__HOME__#$HOME#g" "$TESTS_DIR/fixtures/statusline-input.json")" ccseat statusline
  assert_success
  assert_match "$(row 1)" '^alice +Sonnet 4\.5 medium effort +proj +context 8%$'
  assert_match "$(row 2)" '^5-hour .* 37%'
  assert_match "$(row 3)" '^weekly .* 65%'
}

test_statusline_rows_fit_80_columns() {
  local w
  make_primary alice.anderson@example.com
  add_seat bob@example.com
  make_workflow_fixture sess-1 wf_abc ship-release-notes
  make_background_agent "$WF_SESSION_DIR" bg1 "look for flaky tests"
  mkdir -p "$HOME/repo"
  git -C "$HOME/repo" init -q -b feature/a-very-long-branch-name-for-testing 2>/dev/null \
    || { git -C "$HOME/repo" init -q && git -C "$HOME/repo" checkout -q -b feature/a-very-long-branch-name-for-testing; }
  export NO_COLOR=1
  run_in "$(statusline_input "$HOME/repo" '.model.display_name = "Opus 4.8" | .rate_limits.seven_day.used_percentage = 100')" ccseat statusline
  assert_success
  w=$(widest_line "$OUT")
  [ "$w" -le 80 ] || fail "a status line row is $w characters wide"$'\n'"$OUT"
  assert_contains "$OUT" "agents done" "the agents done always stay"
  assert_not_contains "$OUT" "+ 1 agent"
}

test_statusline_limit_words_follow_the_limits() {
  make_primary alice@example.com
  add_seat bob@example.com
  export NO_COLOR=1
  run_in "$(statusline_input "$HOME" '.rate_limits.five_hour.used_percentage = 97 | .rate_limits.seven_day.used_percentage = 30')" ccseat statusline
  assert_contains "$(row 2)" "LIMIT REACHED" "97% is at the default 95% limit, like ccseat list says"
  assert_not_contains "$(row 3)" "LIMIT" "the note sits on the row that caused it"
  run_in "$(statusline_input "$HOME" '.rate_limits.five_hour.used_percentage = 90 | .rate_limits.seven_day.used_percentage = 30')" ccseat statusline
  assert_contains "$(row 2)" "almost out"
  cs_ok config limit_5h 85
  run_in "$(statusline_input "$HOME" '.rate_limits.five_hour.used_percentage = 90 | .rate_limits.seven_day.used_percentage = 30')" ccseat statusline
  assert_contains "$(row 2)" "LIMIT REACHED" "a custom limit counts"
}

test_statusline_preview_hint_fits() {
  local w
  make_primary alice@example.com
  run_pty -- ccseat statusline
  w=$(widest_line "$OUT")
  [ "$w" -le 80 ] || fail "a preview line is $w characters wide"
  assert_contains "$OUT" "ccseat statusline install"
}

test_statusline_names_the_next_seat_by_number_when_the_name_is_long() {
  make_primary alice@example.com
  add_seat averyveryverylongaccountname.example@example.com
  usage_fixture averyveryverylongaccountname.example@example.com 5 0 10 0
  cs_ok list >/dev/null
  export NO_COLOR=1
  unset COLUMNS
  run_in "$(statusline_input "$HOME" '.rate_limits.five_hour.used_percentage = 97 | .rate_limits.seven_day.used_percentage = 30')" ccseat statusline
  assert_contains "$(row 2)" "next: seat 2" "a long name does not fit 80 columns, so the seat number is used"
  cs_ok config statusline_width 160
  run_in "$(statusline_input "$HOME" '.rate_limits.five_hour.used_percentage = 97 | .rate_limits.seven_day.used_percentage = 30')" ccseat statusline
  assert_contains "$(row 2)" "next: averyveryverylongaccountname.example" "a wider status line names the seat"
}

# ---------- a seat that is out (at its limit) ----------

test_statusline_says_limit_reached_until_the_seat_is_back() {
  local red=$'\033[38;2;229;83;75m'
  pin_local_noon
  make_primary alice@example.com
  add_seat bob@example.com
  usage_fixture bob@example.com 5 $((MIDNIGHT + 20 * 3600)) 10 $((MIDNIGHT + 5 * 86400))
  cs_ok list
  FA=$((MIDNIGHT + 18 * 3600 + 20 * 60)) WA=$((MIDNIGHT + 3 * 86400 + 6 * 3600))
  export NO_COLOR=1
  run_in "$(statusline_input "$HOME" '.rate_limits.seven_day.used_percentage = 100')" ccseat statusline
  assert_match "$(row 3)" "^weekly +●{10} +100% +LIMIT REACHED until $(epoch_fmt "$WA" %A) 6:00 AM, next: bob\$" \
    "the weekly row says until when, then the next seat"
  assert_not_contains "$(row 3)" "resets" "the time is said once"
  assert_match "$(row 2)" '^5-hour .* 23% +resets 6:20 PM$' "the other row keeps its reset"
  run_in "$(statusline_input "$HOME" '.rate_limits.five_hour.used_percentage = 97')" ccseat statusline
  assert_match "$(row 2)" '^5-hour +●{10} +97% +LIMIT REACHED until 6:20 PM, next: bob$'
  assert_not_contains "$(row 3)" "LIMIT"
  # Both windows out: the seat is back when the later one resets.
  FA=$((MIDNIGHT + 18 * 3600)) WA=$((MIDNIGHT + 16 * 3600))
  run_in "$(statusline_input "$HOME" '.rate_limits.five_hour.used_percentage = 97 | .rate_limits.seven_day.used_percentage = 100')" ccseat statusline
  assert_match "$(row 3)" '^weekly .* LIMIT REACHED until 6:00 PM, next: bob$' "the later reset of the two"
  assert_match "$(row 2)" '^5-hour .* 97% +resets 6:00 PM$'
  unset NO_COLOR
  export COLORTERM=truecolor
  run_in "$(statusline_input "$HOME" '.rate_limits.seven_day.used_percentage = 100')" ccseat statusline
  assert_contains "$OUT" $'\033[1m'"${red}LIMIT REACHED until" "bold red"
  assert_contains "$OUT" "${red}●●●●●●●●●●" "the dots of the window at its limit are red"
}

test_statusline_limit_reached_fits_the_width() {
  local w
  pin_local_noon
  make_primary alice.anderson@example.com
  add_seat averyveryverylongaccountname.example@example.com
  usage_fixture averyveryverylongaccountname.example@example.com 5 0 10 0
  cs_ok list
  # The longest reset words: a weekday and a two-digit hour.
  FA=$((MIDNIGHT + 22 * 3600)) WA=$((MIDNIGHT + 5 * 86400 + 10 * 3600))
  export NO_COLOR=1
  run_in "$(statusline_input "$HOME" '.rate_limits.seven_day.used_percentage = 100')" ccseat statusline
  w=$(widest_line "$OUT")
  [ "$w" -le 80 ] || fail "a status line row is $w characters wide"$'\n'"$OUT"
  assert_match "$(row 3)" "LIMIT REACHED until $(epoch_fmt "$WA" %A) 10:00 AM, next: seat 2\$" "a long name gives way to its number"
  run_in "$(statusline_input "$HOME" '.rate_limits.five_hour.used_percentage = 99')" ccseat statusline
  w=$(widest_line "$OUT")
  [ "$w" -le 80 ] || fail "a status line row is $w characters wide"$'\n'"$OUT"
  assert_contains "$(row 2)" "LIMIT REACHED until 10:00 PM"
  cs_ok config statusline_width 50
  run_in "$(statusline_input "$HOME" '.rate_limits.seven_day.used_percentage = 100')" ccseat statusline
  assert_match "$(row 3)" '^weekly +●{10} +100% +LIMIT REACHED$' "a narrow status line keeps LIMIT REACHED"
  w=$(widest_line "$(row 3)")
  [ "$w" -le 50 ] || fail "the weekly row is $w characters wide in 50 columns"
}
