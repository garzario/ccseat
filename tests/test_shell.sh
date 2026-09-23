# shellcheck shell=bash
# The single-quoted -c scripts below are meant to expand in the inner shell.
# shellcheck disable=SC2016
# "ccseat init <shell>": syntax, the claude wrapper function and the cc
# shortcut (the "shortcut" setting).

# Two seats, bob current, so a wrapped launch (bob's dir) and a direct one
# (<unset>) are easy to tell apart.
two_seats_bob_current() {
  make_primary alice@example.com
  add_seat bob@example.com
  cs_ok use bob
  BOB_DIR=$(seat_dir bob)
}

# A stand-in C compiler first on PATH, so "cc" with arguments can be told
# apart from ccseat.
fake_compiler() {
  printf '#!/bin/sh\necho "stub-cc: args=$*"\n' > "$T/bin/cc"
  chmod +x "$T/bin/cc"
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
  run_i bash --norc --noprofile -i -c 'eval "$(ccseat init bash)"; claude --resume "a b"'
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
  CCSEAT_NO_WRAP=1 run_i bash --norc --noprofile -i -c 'eval "$(ccseat init bash)"; claude -p hi'
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=<unset>"
}

test_bash_cc_opens_the_picker_and_keeps_the_compiler() {
  two_seats_bob_current
  fake_compiler
  run_i bash --norc --noprofile -i -c 'eval "$(ccseat init bash)"; cc; cc -o app app.c; type -t cs || echo no-cs'
  assert_match "$OUT" 'seat +5-hour' "cc on its own is ccseat (the list, without a terminal)"
  assert_contains "$OUT" "stub-cc: args=-o app app.c" "cc with arguments is still the C compiler"
  assert_contains "$OUT" "no-cs" "cs is no longer defined"
  assert_eq 0 "$(launch_count)"
}

test_bash_cc_without_a_compiler_runs_ccseat() {
  local p
  two_seats_bob_current
  p=$(path_without cc)
  PATH=$p run_i bash --norc --noprofile -i -c 'eval "$(ccseat init bash)"; cc current'
  assert_eq bob "$OUT" "with no compiler installed, cc <command> is ccseat <command>"
}

test_bash_cc_survives_loading_the_integration_twice() {
  two_seats_bob_current
  fake_compiler
  run_i bash --norc --noprofile -i -c 'eval "$(ccseat init bash)"; eval "$(ccseat init bash)"; cc; cc -c x.c'
  assert_match "$OUT" 'seat +5-hour' "ccseat's own cc is redefined, not taken for the user's"
  assert_contains "$OUT" "stub-cc: args=-c x.c"
}

test_bash_init_prints_nothing_at_startup() {
  two_seats_bob_current
  run_i bash --norc --noprofile -i -c 'eval "$(ccseat init bash)"'
  assert_eq "" "$OUT" "loading the integration prints nothing"
}

test_zsh_wrapper_in_an_interactive_shell() {
  command -v zsh >/dev/null 2>&1 || skip "zsh is not installed"
  two_seats_bob_current
  run_i zsh -f -i -c 'eval "$(ccseat init zsh)"; claude --resume "a b"'
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=$BOB_DIR"
  assert_contains "$OUT" "args=--resume a b"
  run zsh -f -c 'eval "$(ccseat init zsh)"; claude -p hi'
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=<unset>" "non-interactive zsh runs claude directly"
  CCSEAT_NO_WRAP=1 run_i zsh -f -i -c 'eval "$(ccseat init zsh)"; claude -p hi'
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=<unset>" "CCSEAT_NO_WRAP=1 turns the wrapper off"
}

test_zsh_cc_shortcut_and_quiet_startup() {
  local p
  command -v zsh >/dev/null 2>&1 || skip "zsh is not installed"
  two_seats_bob_current
  fake_compiler
  run_i zsh -f -i -c 'eval "$(ccseat init zsh)"; cc; cc -o app app.c; whence -w cs || echo no-cs'
  assert_match "$OUT" 'seat +5-hour' "cc on its own is ccseat"
  assert_contains "$OUT" "stub-cc: args=-o app app.c" "cc with arguments is still the C compiler"
  assert_contains "$OUT" "no-cs"
  rm -f "$T/bin/cc"
  p=$(path_without cc)
  PATH=$p run_i zsh -f -i -c 'eval "$(ccseat init zsh)"; cc current'
  assert_eq bob "$OUT" "with no compiler installed, cc <command> is ccseat <command>"
  run_i zsh -f -i -c 'eval "$(ccseat init zsh)"'
  assert_eq "" "$OUT"
}

test_fish_wrapper() {
  command -v fish >/dev/null 2>&1 || skip "fish is not installed"
  two_seats_bob_current
  run_i fish --no-config -i -c 'ccseat init fish | source; claude --resume "a b"'
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=$BOB_DIR"
  assert_contains "$OUT" "args=--resume a b"
  run fish --no-config -c 'ccseat init fish | source; claude -p hi'
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=<unset>"
  fake_compiler
  run_i fish --no-config -i -c 'ccseat init fish | source; cc; cc -o app app.c'
  assert_match "$OUT" 'seat +5-hour' "cc on its own is ccseat"
  assert_contains "$OUT" "stub-cc: args=-o app app.c" "cc with arguments is still the C compiler"
  rm -f "$T/bin/cc"
  PATH=$(path_without cc) run_i fish --no-config -i -c 'ccseat init fish | source; cc current'
  assert_eq bob "$OUT"
}

test_wrapper_with_the_primary_current() {
  make_primary alice@example.com
  add_seat bob@example.com
  cs_ok use alice
  run_i bash --norc --noprofile -i -c 'eval "$(ccseat init bash)"; claude'
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=<unset>" "the primary launches with CLAUDE_CONFIG_DIR unset"
  # Inside bob's session CLAUDE_CONFIG_DIR is bob's folder: a nested claude
  # stays on bob, and the primary still launches with it unset.
  CLAUDE_CONFIG_DIR="$(seat_dir bob)" CCSEAT_SEAT=bob run_i bash --norc --noprofile -i -c 'eval "$(ccseat init bash)"; claude'
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=$(seat_dir bob)"
  CLAUDE_CONFIG_DIR="$HOME/.claude" run_i bash --norc --noprofile -i -c 'eval "$(ccseat init bash)"; claude'
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=<unset>" "the primary folder is the primary seat"
}

test_wrapper_wins_over_a_claude_alias() {
  two_seats_bob_current
  run_i bash --norc --noprofile -i -c 'alias claude="$HOME/.claude/local/claude"
eval "$(ccseat init bash)"
claude -p hi'
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=$BOB_DIR" "bash: the alias is replaced by the wrapper"
  if command -v zsh >/dev/null 2>&1; then
    run_i zsh -f -i -c 'alias claude="$HOME/.claude/local/claude"
eval "$(ccseat init zsh)"
claude -p hi'
    assert_contains "$OUT" "CLAUDE_CONFIG_DIR=$BOB_DIR" "zsh: the alias is replaced by the wrapper"
  fi
}

test_cc_keeps_a_function_the_user_has() {
  two_seats_bob_current
  run_i bash --norc --noprofile -i -c 'cc() { echo my-own-cc; }
eval "$(ccseat init bash)"
cc version'
  assert_contains "$OUT" "my-own-cc"
  if command -v zsh >/dev/null 2>&1; then
    run_i zsh -f -i -c 'cc() { echo my-own-cc; }
eval "$(ccseat init zsh)"
cc version'
    assert_contains "$OUT" "my-own-cc"
  fi
  if command -v fish >/dev/null 2>&1; then
    run_i fish --no-config -i -c 'function cc; echo my-own-cc; end
ccseat init fish | source
cc version'
    assert_contains "$OUT" "my-own-cc"
  fi
}

test_cc_keeps_an_alias_the_user_has() {
  two_seats_bob_current
  # eval: an alias applies to lines read after it is defined.
  run_i bash --norc --noprofile -i -c 'alias cc="echo my-alias-cc"
eval "$(ccseat init bash)"
eval "cc version"
declare -F cc || echo no-cc-function'
  assert_contains "$OUT" "my-alias-cc"
  assert_contains "$OUT" "no-cc-function" "bash: no function is added behind the alias"
  if command -v zsh >/dev/null 2>&1; then
    run_i zsh -f -i -c 'alias cc="echo my-alias-cc"
eval "$(ccseat init zsh)"
eval "cc version"
(( $+functions[cc] )) || echo no-cc-function'
    assert_contains "$OUT" "my-alias-cc"
    assert_contains "$OUT" "no-cc-function" "zsh: no function is added behind the alias"
  fi
}

test_the_shortcut_setting_names_it() {
  two_seats_bob_current
  fake_compiler
  cs_ok config shortcut cs
  assert_contains "$OUT" "new terminal"
  run_i bash --norc --noprofile -i -c 'eval "$(ccseat init bash)"; cs current; cc -c x.c; cs'
  assert_contains "$OUT" "bob" "cs <command> is ccseat <command>"
  assert_contains "$OUT" "stub-cc: args=-c x.c" "cc is left to the compiler"
  assert_match "$OUT" 'seat +5-hour' "cs on its own is ccseat"
  if command -v zsh >/dev/null 2>&1; then
    run_i zsh -f -i -c 'eval "$(ccseat init zsh)"; cs current; whence -w cc'
    assert_contains "$OUT" "bob"
    assert_contains "$OUT" "cc: command" "zsh: cc stays the compiler"
  fi
  cs_ok config shortcut off
  run_i bash --norc --noprofile -i -c 'eval "$(ccseat init bash)"; type -t cs || echo no-cs; type -t cc'
  assert_contains "$OUT" "no-cs" "off defines no shortcut"
  assert_contains "$OUT" "file" "off leaves cc alone"
  assert_not_contains "$(ccseat init zsh)" "__ccseat_shortcut"
  cs_ok config shortcut default
  cs_ok config shortcut
  assert_eq cc "$OUT" "cc is the default"
}

test_the_shortcut_never_takes_a_name_that_breaks_the_shell() {
  local bad
  for bad in 'two words' cd claude ccseat if exec -x 'a;b' '$(id)' 9lives 'café'; do
    cs config shortcut "$bad"
    assert_exit 2 "shortcut \"$bad\" is refused"
  done
  cs_ok config shortcut
  assert_eq cc "$OUT" "a refused name is not stored"
  # A hand-edited config file is checked too: the name never reaches the shell.
  mkdir -p "$(ccseat_home)"
  printf 'shortcut=a;touch %s\n' "$T/pwned" > "$(ccseat_home)/config"
  cs_ok init bash
  assert_not_contains "$OUT" "pwned"
  assert_contains "$OUT" "function cc"
}

test_init_is_valid_with_every_shortcut() {
  local sc
  two_seats_bob_current
  for sc in cc cs my-seats off; do
    cs_ok config shortcut "$sc"
    cs_ok init bash
    printf '%s\n' "$OUT" > "$T/init.bash"
    run bash -n "$T/init.bash"
    assert_success "bash -n accepts the output with shortcut $sc: $ERR"
    if command -v zsh >/dev/null 2>&1; then
      cs_ok init zsh
      printf '%s\n' "$OUT" > "$T/init.zsh"
      run zsh -n "$T/init.zsh"
      assert_success "zsh -n accepts the output with shortcut $sc: $ERR"
    fi
    if command -v fish >/dev/null 2>&1; then
      cs_ok init fish
      printf '%s\n' "$OUT" > "$T/init.fish"
      run fish -n "$T/init.fish"
      assert_success "fish -n accepts the output with shortcut $sc: $ERR"
    fi
  done
  cs_ok config shortcut my-seats
  run_i bash --norc --noprofile -i -c 'eval "$(ccseat init bash)"; my-seats current'
  assert_eq bob "$OUT" "a name with a dash works"
}

test_uninstall_keeps_lines_after_a_lone_marker() {
  program_copy
  export SHELL=/bin/zsh
  # shellcheck disable=SC2016  # startup file lines, written as is
  printf 'export EDITOR=vim\n# >>> ccseat >>>\neval "$(ccseat init zsh)"\nalias gs="git status"\nexport PATH="$HOME/go/bin:$PATH"\n' > "$HOME/.zshrc"
  cs_ok uninstall -y
  assert_contains "$(cat "$HOME/.zshrc")" 'alias gs="git status"' "lines after a marker without its end stay"
  assert_contains "$(cat "$HOME/.zshrc")" 'go/bin' "lines after a marker without its end stay"
  assert_contains "$(cat "$HOME/.zshrc")" "export EDITOR=vim"
}

test_uninstall_removes_the_one_line_forms_only() {
  program_copy
  export SHELL=/bin/bash
  # shellcheck disable=SC2016  # startup file lines, written as is
  printf 'export EDITOR=vim\neval "$(ccseat init bash)"   # ccseat\nalias ll="ls -l"\n' > "$HOME/.bashrc"
  # shellcheck disable=SC2016
  printf 'if command -v ccseat >/dev/null 2>&1; then eval "$(ccseat init zsh)"; fi\nalias gs="git status"\n' > "$HOME/.zshrc"
  mkdir -p "$HOME/.config/fish"
  printf 'set -gx EDITOR vim\nccseat init fish | source\n' > "$HOME/.config/fish/config.fish"
  cs_ok uninstall -y
  assert_eq "$(printf 'export EDITOR=vim\nalias ll="ls -l"')" "$(cat "$HOME/.bashrc")"
  assert_eq 'alias gs="git status"' "$(cat "$HOME/.zshrc")"
  assert_eq "set -gx EDITOR vim" "$(cat "$HOME/.config/fish/config.fish")"
  assert_not_contains "$OUT" "by hand"
}

test_uninstall_never_breaks_a_hand_written_guard() {
  program_copy
  export SHELL=/bin/bash
  # shellcheck disable=SC2016  # startup file lines, written as is
  printf 'export EDITOR=vim\nif command -v ccseat >/dev/null 2>&1; then\n  eval "$(ccseat init bash)"\nfi\nalias ll="ls -l"\n' > "$HOME/.bashrc"
  cp "$HOME/.bashrc" "$T/bashrc.before"
  cs_ok uninstall -y
  assert_contains "$OUT" "still runs ccseat init on line 3"
  run bash --norc --noprofile -n "$HOME/.bashrc"
  assert_success "the startup file still parses: $ERR"
  assert_eq "$(cat "$T/bashrc.before")" "$(cat "$HOME/.bashrc")" "a guard that would be left empty stays whole"
}

test_setup_names_the_shortcut() {
  make_primary alice@example.com
  cs_ok setup --yes --no-statusline
  assert_match "$OUT" '^  cc +pick a seat with the arrow keys \(cc file\.c still compiles\)$'
  assert_not_contains "$OUT" "cs for short"
  cs_ok config shortcut off
  cs_ok setup --yes --no-statusline
  assert_match "$OUT" '^  ccseat +pick a seat with the arrow keys$' "no shortcut, so ccseat itself"
}
