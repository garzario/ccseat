# shellcheck shell=bash
# Launching Claude Code: "ccseat run", the "ccseat claude" wrapper with
# auto-switch, and the interactive picker (driven through a pseudo terminal).

# ---------- run ----------

test_run_sets_the_config_dir() {
  local dir
  make_primary alice@example.com
  add_seat bob@example.com
  dir=$(seat_dir bob)
  cs_ok run bob --resume "two words"
  assert_contains "$OUT" "stub-claude: CLAUDE_CONFIG_DIR=$dir"
  assert_contains "$OUT" "stub-claude: args=--resume two words"
  assert_eq "$dir"$'\t'"--resume two words" "$(last_launch)"
}

test_run_unsets_the_config_dir_for_the_primary() {
  make_primary alice@example.com
  add_seat bob@example.com
  export CLAUDE_CONFIG_DIR="$T/leftover"
  cs_ok run alice -p hello
  assert_contains "$OUT" "stub-claude: CLAUDE_CONFIG_DIR=<unset>"
  assert_contains "$OUT" "stub-claude: args=-p hello"
}

test_run_by_index_and_prefix() {
  make_primary alice@example.com
  add_seat bob@example.com
  cs_ok run 2
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=$(seat_dir bob)"
  cs_ok run al
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=<unset>"
}

test_run_unknown_seat_fails_without_launching() {
  make_primary alice@example.com
  cs run nobody
  assert_failure
  assert_eq 0 "$(launch_count)"
}

test_run_syncs_before_launch() {
  local gc
  make_primary alice@example.com
  add_seat bob@example.com
  gc=$(global_config "$(seat_dir bob)")
  jq '.mcpServers.fresh = {type: "http", url: "https://fresh.example"}' "$HOME/.claude.json" > "$T/p" && mv "$T/p" "$HOME/.claude.json"
  cs_ok run bob
  assert_json "$(cat "$gc")" '.mcpServers.fresh.url == "https://fresh.example"' "silent sync before launch"
  assert_eq "" "$ERR" "sync is silent"
}

test_run_repairs_a_missing_shared_link() {
  local dir
  make_primary alice@example.com
  add_seat bob@example.com
  dir=$(seat_dir bob)
  rm "$dir/CLAUDE.md"
  cs_ok run bob
  assert_symlink "$dir/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
}

# ---------- claude wrapper ----------

test_wrapper_launches_the_current_seat() {
  local now
  now=$(now_epoch)
  make_primary alice@example.com
  add_seat bob@example.com
  usage_fixture alice@example.com 20 $((now + 3600)) 20 $((now + 86400))
  usage_fixture bob@example.com 10 $((now + 3600)) 10 $((now + 86400))
  cs_ok use alice
  cs_ok list
  cs_ok claude --continue
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=<unset>"
  assert_contains "$OUT" "args=--continue"
  assert_eq "" "$ERR" "no notice when the current seat has room"
  cs_ok use bob
  cs_ok claude
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=$(seat_dir bob)"
}

test_wrapper_switches_at_the_5_hour_limit() {
  pin_local_noon
  make_primary alice@example.com
  add_seat bob@example.com
  add_seat carol@example.com
  usage_fixture alice@example.com 96 $((MIDNIGHT + 18 * 3600 + 20 * 60)) 40 $((MIDNIGHT + 3 * 86400))
  usage_fixture bob@example.com 70 $((MIDNIGHT + 15 * 3600)) 60 $((MIDNIGHT + 2 * 86400))
  usage_fixture carol@example.com 5 $((MIDNIGHT + 16 * 3600)) 10 $((MIDNIGHT + 4 * 86400))
  cs_ok use alice
  cs_ok list
  cs_ok claude -p hi
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=$(seat_dir carol)" "the freest seat is used"
  assert_contains "$OUT" "args=-p hi"
  assert_eq 1 "$(printf '%s\n' "$ERR" | grep -c .)" "exactly one line on stderr"
  assert_eq "ccseat: alice is at its 5-hour limit until 6:20 PM, using carol" "$ERR"
}

test_wrapper_switches_at_the_weekly_limit() {
  local when
  pin_local_noon
  make_primary alice@example.com
  add_seat bob@example.com
  usage_fixture alice@example.com 10 $((MIDNIGHT + 14 * 3600)) 100 $((MIDNIGHT + 3 * 86400 + 16 * 3600))
  usage_fixture bob@example.com 30 $((MIDNIGHT + 15 * 3600)) 50 $((MIDNIGHT + 5 * 86400))
  cs_ok use alice
  cs_ok list
  cs_ok claude
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=$(seat_dir bob)"
  when="$(epoch_fmt $((MIDNIGHT + 3 * 86400 + 16 * 3600)) %A) 4:00 PM"
  assert_eq "ccseat: alice is at its weekly limit until $when, using bob" "$ERR"
}

test_wrapper_respects_custom_limits() {
  local now
  now=$(now_epoch)
  make_primary alice@example.com
  add_seat bob@example.com
  usage_fixture alice@example.com 81 $((now + 3600)) 20 $((now + 86400))
  usage_fixture bob@example.com 10 $((now + 3600)) 10 $((now + 86400))
  cs_ok use alice
  cs_ok list
  cs_ok claude
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=<unset>" "81% is under the default 95% limit"
  cs_ok config limit_5h 80
  cs_ok claude
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=$(seat_dir bob)" "81% is over a custom 80% limit"
}

test_wrapper_without_auto_switch_stays_put() {
  local now
  now=$(now_epoch)
  make_primary alice@example.com
  add_seat bob@example.com
  usage_fixture alice@example.com 99 $((now + 3600)) 100 $((now + 86400))
  usage_fixture bob@example.com 10 $((now + 3600)) 10 $((now + 86400))
  cs_ok use alice
  cs_ok config auto_switch off
  cs_ok list
  cs_ok claude
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=<unset>"
}

test_wrapper_skips_seats_that_are_not_logged_in() {
  local now
  now=$(now_epoch)
  make_primary alice@example.com
  add_seat bob@example.com
  add_seat carol@example.com
  usage_fixture alice@example.com 99 $((now + 3600)) 50 $((now + 86400))
  usage_fixture bob@example.com 1 $((now + 3600)) 1 $((now + 86400))
  usage_fixture carol@example.com 40 $((now + 3600)) 40 $((now + 86400))
  cs_ok use alice
  cs_ok list
  rm -f "$(seat_dir bob)/.credentials.json"
  cs_ok claude
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=$(seat_dir carol)" "bob is logged out, so carol is the freest"
}

test_wrapper_when_every_seat_is_at_its_limit() {
  local now
  now=$(now_epoch)
  make_primary alice@example.com
  add_seat bob@example.com
  usage_fixture alice@example.com 100 $((now + 3600)) 50 $((now + 86400))
  usage_fixture bob@example.com 100 $((now + 7200)) 100 $((now + 86400))
  cs_ok use alice
  cs_ok list
  cs claude
  assert_success "still launches"
  assert_eq 1 "$(launch_count)" "launched once"
  assert_ne "" "$(launches)"
}

test_wrapper_does_not_block_on_a_slow_api() {
  local now start took
  now=$(now_epoch)
  make_primary alice@example.com
  add_seat bob@example.com
  usage_fixture alice@example.com 10 $((now + 3600)) 10 $((now + 86400))
  printf '8\n' > "$STUB/curl_delay"
  cs_ok use alice
  start=$(now_epoch)
  cs_ok claude
  took=$(( $(now_epoch) - start ))
  [ "$took" -le 4 ] || fail "ccseat claude waited $took s for a slow API (limit about 1.5 s)"
  assert_contains "$OUT" "stub-claude:"
}

test_wrapper_launches_when_the_api_is_down() {
  make_primary alice@example.com
  : > "$STUB/curl_fail"
  cs_ok claude
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=<unset>"
}

test_wrapper_without_seats_runs_claude() {
  cs claude --version
  assert_success "ccseat claude works before any seat exists"
  assert_contains "$OUT" "2.1.280"
}

# ---------- picker ----------

test_picker_opens_the_chosen_seat() {
  local now
  now=$(now_epoch)
  make_primary alice@example.com
  add_seat bob@example.com
  usage_fixture alice@example.com 12 $((now + 3600)) 20 $((now + 86400))
  usage_fixture bob@example.com 50 $((now + 3600)) 60 $((now + 86400))
  cs_ok list
  run_pty '\033[B' '\r' -- ccseat
  assert_contains "$OUT" "Choose a seat"
  assert_contains "$OUT" "5-hour"
  assert_contains "$OUT" "weekly"
  assert_contains "$OUT" $'\033[?1049h' "draws on the alternate screen"
  assert_contains "$OUT" $'\033[?1049l' "leaves the alternate screen"
  assert_contains "$OUT" $'\033[?25h' "shows the cursor again"
  assert_contains "$OUT" "stub-claude: CLAUDE_CONFIG_DIR=$(seat_dir bob)" "down arrow then enter opens seat 2"
  cs_ok current
  assert_eq bob "$OUT" "the chosen seat is remembered"
}

test_picker_starts_on_the_freest_seat() {
  local now
  now=$(now_epoch)
  make_primary alice@example.com
  add_seat bob@example.com
  add_seat carol@example.com
  usage_fixture alice@example.com 80 $((now + 3600)) 20 $((now + 86400))
  usage_fixture bob@example.com 30 $((now + 3600)) 60 $((now + 86400))
  usage_fixture carol@example.com 5 $((now + 3600)) 10 $((now + 86400))
  cs_ok list
  run_pty '\r' -- ccseat pick
  assert_contains "$OUT" "stub-claude: CLAUDE_CONFIG_DIR=$(seat_dir carol)"
}

test_picker_number_keys() {
  make_primary alice@example.com
  add_seat bob@example.com
  add_seat carol@example.com
  cs_ok list
  run_pty '3' '\r' -- ccseat pick
  assert_contains "$OUT" "stub-claude: CLAUDE_CONFIG_DIR=$(seat_dir carol)" "3 jumps to the third seat"
}

test_picker_vim_keys() {
  local now
  now=$(now_epoch)
  make_primary alice@example.com
  add_seat bob@example.com
  add_seat carol@example.com
  usage_fixture alice@example.com 1 $((now + 3600)) 1 $((now + 86400))
  usage_fixture bob@example.com 50 $((now + 3600)) 50 $((now + 86400))
  usage_fixture carol@example.com 60 $((now + 3600)) 60 $((now + 86400))
  cs_ok list
  run_pty 'j' '\r' -- ccseat pick
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=$(seat_dir bob)" "j moves down from alice, the freest"
  usage_fixture alice@example.com 70 $((now + 3600)) 70 $((now + 86400))
  usage_fixture carol@example.com 2 $((now + 3600)) 2 $((now + 86400))
  cs_ok usage --refresh
  run_pty 'k' '\r' -- ccseat pick
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=$(seat_dir bob)" "k moves up from carol, the freest"
}

test_picker_cancel_launches_nothing() {
  local key
  make_primary alice@example.com
  add_seat bob@example.com
  cs_ok use bob
  for key in q '\033'; do
    run_pty "$key" -- ccseat pick
    assert_eq 0 "$(launch_count)" "cancelled with $key"
    assert_contains "$OUT" $'\033[?1049l' "the screen is restored after $key"
  done
  cs_ok current
  assert_eq bob "$OUT" "cancel keeps the current seat"
}

test_picker_without_remember_keeps_current() {
  make_primary alice@example.com
  add_seat bob@example.com
  cs_ok use alice
  cs_ok config remember off
  run_pty '2' '\r' -- ccseat pick
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=$(seat_dir bob)"
  cs_ok current
  assert_eq alice "$OUT"
}

test_picker_output_has_no_color_with_no_color() {
  make_primary alice@example.com
  add_seat bob@example.com
  export NO_COLOR=1
  run_pty q -- ccseat pick
  assert_contains "$OUT" "Choose a seat"
  assert_no_match "$OUT" $'\033''\[(38|48);' "no color codes with NO_COLOR"
}

test_picker_fits_a_narrow_terminal() {
  local now line n widest=0 esc
  esc=$(printf '\033')
  now=$(now_epoch)
  make_primary alice.with.a.long.name@example.com
  add_seat bob@example.com
  usage_fixture alice.with.a.long.name@example.com 12 $((now + 7200)) 79 $((now + 3 * 86400))
  usage_fixture bob@example.com 40 $((now + 3600)) 20 $((now + 5 * 86400))
  cs_ok list
  export COLUMNS=40 LINES=24
  run_pty q -- ccseat pick
  assert_contains "$OUT" "Choose a seat"
  while IFS= read -r line; do
    line=$(printf '%s' "$line" | sed "s/${esc}\\[[0-9;?]*[A-Za-z]//g")
    n=$(printf '%s' "$line" | wc -m | tr -d ' ')
    [ "$n" -gt "$widest" ] && widest=$n
  done <<END_OUT
$OUT
END_OUT
  [ "$widest" -le 40 ] || fail "a picker line is $widest characters wide on a 40-column terminal"
}

# ---------- terminal size, redraws and the terminal state ----------

test_picker_reads_the_size_from_the_terminal() {
  local now w
  now=$(now_epoch)
  make_primary alice.with.a.long.name@example.com
  add_seat bob@example.com
  usage_fixture alice.with.a.long.name@example.com 12 $((now + 7200)) 79 $((now + 3 * 86400))
  usage_fixture bob@example.com 40 $((now + 3600)) 10 $((now + 5 * 86400))
  cs_ok list
  # No COLUMNS or LINES: shells do not export them, so only the terminal knows.
  run_pty q -- bash -c 'stty cols 44 rows 12; exec ccseat pick'
  assert_contains "$OUT" "Choose a seat"
  w=$(widest_line "$OUT")
  [ "$w" -le 44 ] || fail "a picker line is $w characters wide on a 44-column terminal"
}

test_picker_uses_a_tall_terminal_for_many_seats() {
  local e
  make_primary alice@example.com
  for e in bob@example.com carol@example.com dave@example.com eve@example.com frank@example.com; do
    add_seat "$e"
  done
  for e in alice@example.com bob@example.com carol@example.com dave@example.com eve@example.com frank@example.com; do
    usage_fixture "$e" 20 $(( $(now_epoch) + 3600 )) 30 $(( $(now_epoch) + 86400 ))
  done
  cs_ok list
  run_pty q -- bash -c 'stty cols 100 rows 50; exec ccseat pick'
  assert_contains "$OUT" "frank"
  assert_contains "$OUT" "●●" "six seats get the full layout with bars on 50 rows"
  assert_contains "$OUT" "resets"
}

test_picker_one_line_layout_keeps_the_notes() {
  local now e
  now=$(now_epoch)
  make_primary alice.smith@example.com
  for e in bob@example.com carol@example.com dave@example.com eve@example.com frank@example.com; do
    add_seat "$e"
  done
  usage_fixture alice.smith@example.com 10 $((now + 3600)) 100 $((now + 86400))
  usage_fixture bob@example.com 70 $((now + 3600)) 30 $((now + 86400))
  usage_fixture carol@example.com 5 $((now + 3600)) 10 $((now + 86400))
  cs_ok use carol
  cs_ok list
  export NO_COLOR=1
  run_pty q -- bash -c 'stty cols 80 rows 12; exec ccseat pick'
  assert_match "$OUT" 'alice\.smith +5-hour +10% +weekly +100%!' "names are padded and a limit is marked"
  assert_match "$OUT" 'bob +5-hour +70%' "the numbers line up"
  assert_contains "$OUT" "at its weekly limit"
  assert_contains "$OUT" "current"
}

test_picker_redraws_only_on_a_change() {
  local now
  now=$(now_epoch)
  make_primary alice@example.com
  add_seat bob@example.com
  usage_fixture alice@example.com 1 $((now + 3600)) 1 $((now + 86400))
  usage_fixture bob@example.com 50 $((now + 3600)) 50 $((now + 86400))
  cs_ok list
  # The cursor starts on alice, the first seat: up and unknown keys change
  # nothing, down moves once.
  run_pty 'k' 'x' '\033[A' 'j' 'j' 'q' -- ccseat pick
  assert_eq 2 "$(frame_count "$OUT")" "the first frame plus one for the single move"
}

test_picker_ctrl_c_restores_the_terminal() {
  make_primary alice@example.com
  add_seat bob@example.com
  cs_ok list
  cat > "$T/inner.sh" <<'INNER'
ccseat pick
echo "rc=$?"
stty -a | tr ' ' '\n' | grep -x -e echo -e -echo
INNER
  # The test runner starts tests in the background, where SIGINT is ignored
  # and a shell cannot trap it: perl puts the default back first.
  command -v perl >/dev/null 2>&1 || skip "perl is not available"
  # shellcheck disable=SC2016  # a perl program
  run_pty '\003' -- perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' bash "$T/inner.sh"
  assert_contains "$OUT" "rc=130" "Ctrl-C cancels"
  assert_match "$OUT" '^echo$' "echo is back on after Ctrl-C"
  assert_eq 0 "$(launch_count)"
}

test_list_fits_the_terminal_with_a_seat_at_its_limit() {
  local now w
  now=$(now_epoch)
  make_primary alice.smith@example.com
  add_seat bob@example.com
  usage_fixture alice.smith@example.com 10 $((now + 3600)) 100 $((now + 3 * 86400))
  usage_fixture bob@example.com 96 $((now + 3600)) 40 $((now + 3 * 86400))
  cs_ok list
  export NO_COLOR=1
  run_pty -- bash -c 'stty cols 80 rows 30; exec ccseat list'
  assert_contains "$OUT" "weekly limit"
  assert_contains "$OUT" "5-hour limit"
  assert_match "$OUT" '^  #  seat' "the table still fits, with the short limit words"
  assert_not_contains "$OUT" "live, " "a seat at a limit says only that"
  w=$(widest_line "$OUT")
  [ "$w" -le 80 ] || fail "a list line is $w characters wide on an 80-column terminal"
  run_pty -- bash -c 'stty cols 40 rows 30; exec ccseat list'
  w=$(widest_line "$OUT")
  [ "$w" -le 40 ] || fail "a list line is $w characters wide on a 40-column terminal"
  assert_match "$OUT" '5-hour +96%' "the stacked layout keeps the numbers"
}

# ---------- a CLAUDE_CONFIG_DIR the user set ----------

test_wrapper_respects_a_config_dir_set_by_the_user() {
  local now
  now=$(now_epoch)
  make_primary alice@example.com
  login_seat_dir "$HOME/.claude-work" carol@example.com
  cs_ok add --dir "$HOME/.claude-work"
  add_seat dave@example.com
  cs_ok use dave
  # A registered folder opens that seat, not the current one.
  CLAUDE_CONFIG_DIR="$HOME/.claude-work" run ccseat claude -p x
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=$HOME/.claude-work"
  # An alias like claude2='CLAUDE_CONFIG_DIR=... claude' works the same way.
  run_i bash --norc --noprofile -i -c "eval \"\$(ccseat init bash)\"; alias claude2='CLAUDE_CONFIG_DIR=$HOME/.claude-work claude'
claude2 -p hi"
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=$HOME/.claude-work"
  # A folder that is not a seat opens exactly as asked.
  mkdir -p "$T/elsewhere"
  CLAUDE_CONFIG_DIR="$T/elsewhere" run ccseat claude -p x
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=$T/elsewhere"
  assert_no_path "$T/elsewhere/settings.json" "an unknown folder gets no links"
  # Auto-switch still applies to a seat chosen that way.
  usage_fixture carol@example.com 99 $((now + 3600)) 10 $((now + 86400))
  usage_fixture dave@example.com 5 $((now + 3600)) 5 $((now + 86400))
  usage_fixture alice@example.com 50 $((now + 3600)) 50 $((now + 86400))
  cs_ok usage --refresh
  CLAUDE_CONFIG_DIR="$HOME/.claude-work" run ccseat claude
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=$(seat_dir dave)"
  assert_contains "$ERR" "carol is at its 5-hour limit"
}

test_wrapper_sends_user_mcp_changes_to_the_primary() {
  local gc
  make_primary alice@example.com
  add_seat bob@example.com
  cs_ok use bob
  run ccseat claude mcp add -s user linear https://linear.example
  assert_success
  assert_contains "$(cat "$STUB/claude.log")" "launch dir=<unset> args=mcp add -s user linear" "the primary gets user-scope servers"
  assert_contains "$ERR" "every seat"
  run ccseat claude mcp add local-one x
  assert_contains "$(cat "$STUB/claude.log")" "launch dir=$(seat_dir bob) args=mcp add local-one" "other scopes stay in the seat"
  run ccseat claude mcp remove github
  assert_contains "$(cat "$STUB/claude.log")" "launch dir=<unset> args=mcp remove github" "a copied server is removed at its source"
  gc=$(global_config "$(seat_dir bob)")
  assert_file "$gc"
}

test_wrapper_names_the_seat_it_signs_in_again() {
  make_primary alice@example.com
  add_seat bob@example.com
  cs_ok use bob
  CCSEAT_STUB_LOGIN_EMAIL=bob@example.com run ccseat claude auth login
  assert_contains "$ERR" "bob"
  assert_contains "$ERR" "ccseat add"
}

test_picker_without_seats_adds_one_and_opens_it() {
  mkdir -p "$HOME/.claude"
  CCSEAT_STUB_LOGIN_EMAIL=alice@example.com run_pty '\r' -- ccseat
  assert_contains "$OUT" "Add an account now?"
  assert_contains "$OUT" "Opening"
  assert_contains "$OUT" "stub-claude: CLAUDE_CONFIG_DIR=<unset>" "the first account is ~/.claude and opens right away"
  assert_eq "$HOME/.claude" "$(seat_dir alice)"
}

test_picker_without_seats_can_be_declined() {
  mkdir -p "$HOME/.claude"
  run_pty 'n\r' -- bash -c 'ccseat; echo "rc=$?"'
  assert_contains "$OUT" "rc=130"
  assert_eq 0 "$(launch_count)"
}
