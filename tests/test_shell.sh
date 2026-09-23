# shellcheck shell=bash
# "ccseat init <shell>": syntax, the claude wrapper function and the cs alias.

# Two seats, bob current, so a wrapped launch (bob's dir) and a direct one
# (<unset>) are easy to tell apart.
two_seats_bob_current() {
  make_primary alice@example.com
  add_seat bob@example.com
  cs_ok use bob
  BOB_DIR=$(seat_dir bob)
}

test_init_zsh_is_valid() {
  command -v zsh >/dev/null 2>&1 || skip "zsh is not installed"
  cs_ok init zsh
  printf '%s\n' "$OUT" > "$T/init.zsh"
  run zsh -n "$T/init.zsh"
  assert_success "zsh -n accepts the output: $ERR"
  assert_contains "$(cat "$T/init.zsh")" "claude"
  assert_contains "$(cat "$T/init.zsh")" "CCSEAT_NO_WRAP"
}

test_init_bash_is_valid() {
  cs_ok init bash
  printf '%s\n' "$OUT" > "$T/init.bash"
  run bash -n "$T/init.bash"
  assert_success "bash -n accepts the output: $ERR"
  assert_contains "$(cat "$T/init.bash")" "CCSEAT_NO_WRAP"
}

test_init_fish_is_valid() {
  command -v fish >/dev/null 2>&1 || skip "fish is not installed"
  cs_ok init fish
  printf '%s\n' "$OUT" > "$T/init.fish"
  run fish -n "$T/init.fish"
  assert_success "fish -n accepts the output: $ERR"
  assert_contains "$(cat "$T/init.fish")" "CCSEAT_NO_WRAP"
}

test_init_is_quick_and_has_no_side_effects() {
  local sh
  make_primary alice@example.com
  for sh in zsh bash fish; do
    cs_ok init "$sh"
    assert_eq "" "$ERR" "init $sh writes nothing to stderr"
  done
  assert_no_path "$STUB/curl.args" "init never calls the network"
  assert_not_contains "$(cat "$STUB/claude.log" 2>/dev/null)" "launch" "init never launches claude"
}

test_bash_wrapper_in_an_interactive_shell() {
  two_seats_bob_current
  run bash --norc --noprofile -i -c 'eval "$(ccseat init bash)"; claude --resume "a b"'
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=$BOB_DIR" "claude goes through ccseat"
  assert_contains "$OUT" "args=--resume a b" "arguments pass through intact"
}

test_bash_wrapper_is_off_in_scripts() {
  two_seats_bob_current
  run bash --norc --noprofile -c 'eval "$(ccseat init bash)"; claude -p hi'
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=<unset>" "non-interactive shells run claude directly"
}

test_bash_wrapper_honors_no_wrap() {
  two_seats_bob_current
  CCSEAT_NO_WRAP=1 run bash --norc --noprofile -i -c 'eval "$(ccseat init bash)"; claude -p hi'
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=<unset>"
}

test_bash_cs_alias() {
  two_seats_bob_current
  run bash --norc --noprofile -i -c 'eval "$(ccseat init bash)"; eval "cs current"'
  assert_contains "$OUT" "bob"
}

test_bash_init_prints_nothing_at_startup() {
  two_seats_bob_current
  run bash --norc --noprofile -i -c 'eval "$(ccseat init bash)"'
  assert_eq "" "$OUT" "loading the integration prints nothing"
}

test_zsh_wrapper_in_an_interactive_shell() {
  command -v zsh >/dev/null 2>&1 || skip "zsh is not installed"
  two_seats_bob_current
  run zsh -f -i -c 'eval "$(ccseat init zsh)"; claude --resume "a b"'
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=$BOB_DIR"
  assert_contains "$OUT" "args=--resume a b"
  run zsh -f -c 'eval "$(ccseat init zsh)"; claude -p hi'
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=<unset>" "non-interactive zsh runs claude directly"
  CCSEAT_NO_WRAP=1 run zsh -f -i -c 'eval "$(ccseat init zsh)"; claude -p hi'
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=<unset>" "CCSEAT_NO_WRAP=1 turns the wrapper off"
}

test_zsh_cs_alias_and_quiet_startup() {
  command -v zsh >/dev/null 2>&1 || skip "zsh is not installed"
  two_seats_bob_current
  run zsh -f -i -c 'eval "$(ccseat init zsh)"; eval "cs current"'
  assert_contains "$OUT" "bob"
  run zsh -f -i -c 'eval "$(ccseat init zsh)"'
  assert_eq "" "$OUT"
}

test_fish_wrapper() {
  command -v fish >/dev/null 2>&1 || skip "fish is not installed"
  two_seats_bob_current
  run fish --no-config -i -c 'ccseat init fish | source; claude --resume "a b"'
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=$BOB_DIR"
  assert_contains "$OUT" "args=--resume a b"
  run fish --no-config -c 'ccseat init fish | source; claude -p hi'
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=<unset>"
  run fish --no-config -i -c 'ccseat init fish | source; cs current'
  assert_contains "$OUT" "bob"
}

test_wrapper_with_the_primary_current() {
  make_primary alice@example.com
  add_seat bob@example.com
  cs_ok use alice
  run bash --norc --noprofile -i -c 'eval "$(ccseat init bash)"; claude'
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=<unset>" "the primary launches with CLAUDE_CONFIG_DIR unset"
  # Inside bob's session CLAUDE_CONFIG_DIR is bob's folder: a nested claude
  # stays on bob, and the primary still launches with it unset.
  CLAUDE_CONFIG_DIR="$(seat_dir bob)" CCSEAT_SEAT=bob run bash --norc --noprofile -i -c 'eval "$(ccseat init bash)"; claude'
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=$(seat_dir bob)"
  CLAUDE_CONFIG_DIR="$HOME/.claude" run bash --norc --noprofile -i -c 'eval "$(ccseat init bash)"; claude'
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=<unset>" "the primary folder is the primary seat"
}

test_wrapper_wins_over_a_claude_alias() {
  two_seats_bob_current
  run bash --norc --noprofile -i -c 'alias claude="$HOME/.claude/local/claude"
eval "$(ccseat init bash)"
claude -p hi'
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=$BOB_DIR" "bash: the alias is replaced by the wrapper"
  if command -v zsh >/dev/null 2>&1; then
    run zsh -f -i -c 'alias claude="$HOME/.claude/local/claude"
eval "$(ccseat init zsh)"
claude -p hi'
    assert_contains "$OUT" "CLAUDE_CONFIG_DIR=$BOB_DIR" "zsh: the alias is replaced by the wrapper"
  fi
}

test_cs_keeps_a_function_the_user_has() {
  two_seats_bob_current
  run bash --norc --noprofile -i -c 'cs() { echo my-own-cs; }
eval "$(ccseat init bash)"
cs version'
  assert_contains "$OUT" "my-own-cs"
  if command -v zsh >/dev/null 2>&1; then
    run zsh -f -i -c 'cs() { echo my-own-cs; }
eval "$(ccseat init zsh)"
cs version'
    assert_contains "$OUT" "my-own-cs"
  fi
}

test_uninstall_keeps_lines_after_a_lone_marker() {
  export SHELL=/bin/zsh
  # shellcheck disable=SC2016  # startup file lines, written as is
  printf 'export EDITOR=vim\n# >>> ccseat >>>\neval "$(ccseat init zsh)"\nalias gs="git status"\nexport PATH="$HOME/go/bin:$PATH"\n' > "$HOME/.zshrc"
  cs_ok uninstall -y
  assert_contains "$(cat "$HOME/.zshrc")" 'alias gs="git status"' "lines after a marker without its end stay"
  assert_contains "$(cat "$HOME/.zshrc")" 'go/bin' "lines after a marker without its end stay"
  assert_contains "$(cat "$HOME/.zshrc")" "export EDITOR=vim"
}
