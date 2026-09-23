# shellcheck shell=bash
# "ccseat doctor": dependencies, seats, links, shell integration, status line.

test_doctor_on_a_healthy_setup() {
  local now
  now=$(now_epoch)
  make_primary alice@example.com
  add_seat bob@example.com
  usage_fixture alice@example.com 12 $((now + 7200)) 79 $((now + 86400))
  export SHELL=/bin/bash
  # shellcheck disable=SC2016  # the startup file line, written as is
  printf 'eval "$(ccseat init bash)"\n' > "$HOME/.bashrc"
  cp "$HOME/.bashrc" "$HOME/.bash_profile"
  cs_ok statusline install
  cs doctor
  assert_success "no problems found"
  assert_contains "$OUT" "jq"
  assert_contains "$OUT" "curl"
  assert_contains "$OUT" "claude"
  assert_contains "$OUT" "alice"
  assert_contains "$OUT" "bob"
  no_ansi "$OUT"
  assert_no_tokens
}

test_doctor_reports_a_broken_link() {
  make_primary alice@example.com
  add_seat bob@example.com
  rm "$HOME/.claude/CLAUDE.md"
  cs doctor
  assert_contains "$OUT$ERR" "CLAUDE.md" "names the broken link"
  assert_contains "$OUT$ERR" "ccseat" "prints the command that fixes it"
}

test_doctor_reports_a_logged_out_seat() {
  make_primary alice@example.com
  add_seat bob@example.com
  rm -f "$(seat_dir bob)/.credentials.json"
  cs doctor
  assert_match "$OUT$ERR" 'bob.*not logged in|not logged in.*bob'
}

test_doctor_reports_missing_jq() {
  make_primary alice@example.com
  PATH="$(path_without jq)" run ccseat doctor
  assert_failure "a missing dependency is a problem"
  assert_contains "$OUT$ERR" "jq"
  assert_match "$OUT$ERR" '(brew|apt-get|apt|dnf|pacman|zypper|apk) (install|-S|add)' "prints how to install jq"
}

test_doctor_reports_missing_shell_integration() {
  make_primary alice@example.com
  export SHELL=/bin/zsh
  cs doctor
  assert_match "$OUT$ERR" 'ccseat (setup|init zsh)' "prints the command that sets up the shell"
}

test_doctor_reports_missing_status_line() {
  make_primary alice@example.com
  cs doctor
  assert_contains "$OUT$ERR" "ccseat statusline install"
}

test_doctor_without_any_seat() {
  cs doctor
  assert_contains "$OUT$ERR" "ccseat add"
}

test_doctor_finds_a_claude_alias_after_the_block() {
  make_primary alice@example.com
  export SHELL=/bin/zsh
  # shellcheck disable=SC2016  # startup file lines, written as is
  printf '# >>> ccseat >>>\nif command -v ccseat >/dev/null 2>&1; then eval "$(ccseat init zsh)"; fi\n# <<< ccseat <<<\nalias claude="$HOME/.claude/local/claude"\n' > "$HOME/.zshrc"
  cs doctor
  assert_contains "$OUT" ".zshrc line 4 makes claude an alias"
  # shellcheck disable=SC2016
  printf 'alias claude="$HOME/.claude/local/claude"\n# >>> ccseat >>>\neval "$(ccseat init zsh)"\n# <<< ccseat <<<\n' > "$HOME/.zshrc"
  cs doctor
  assert_not_contains "$OUT" "makes claude an alias" "an alias before the block is removed by the integration"
}

test_doctor_lines_fit_and_line_up() {
  local w
  make_primary patricio.garza@example.com
  add_seat bob@example.com
  export SHELL=/bin/bash
  CLAUDE_CONFIG_DIR="$HOME/.claude-cuenta2" run ccseat doctor
  # The sandbox path of the claude stub is long only in tests.
  w=$(widest_line "$(printf '%s\n' "$OUT" | grep -v 'Claude Code 2\.')")
  [ "$w" -le 80 ] || fail "a doctor line is $w characters wide"$'\n'"$OUT"
  assert_match "$OUT" 'jq [0-9]' "jq shows as a plain version"
  assert_eq "$(printf '%s\n' "$OUT" | awk '/patricio\.garza@/ { print index($0, "patricio.garza@") }')" \
    "$(printf '%s\n' "$OUT" | awk '/ bob@/ { print index($0, "bob@") }')" "seat names are padded so the emails line up"
}

test_doctor_without_jq_says_seats_need_it() {
  make_primary alice@example.com
  PATH="$(path_without jq)" run ccseat doctor
  assert_contains "$OUT" "Seats"
  assert_contains "$OUT" "needs jq to check"
}
