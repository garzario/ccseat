# shellcheck shell=bash
# Help, version, exit codes and "ccseat config".

test_version_flags() {
  local v
  cs_ok version
  assert_match "$OUT" '[0-9]+\.[0-9]+\.[0-9]+' "version prints a semantic version"
  v="$OUT"
  cs_ok --version
  assert_eq "$v" "$OUT" "--version matches version"
  cs_ok -v
  assert_eq "$v" "$OUT" "-v matches version"
  assert_eq 1 "$(printf '%s\n' "$v" | grep -c .)" "version is one line"
}

test_help_lists_every_command() {
  local c
  cs_ok help
  for c in add remove rename list use current run sync usage init statusline progress doctor config uninstall version; do
    assert_match "$OUT" "(^|[^a-z-])$c([^a-z-]|$)" "help mentions $c"
  done
  cs_ok --help
  assert_contains "$OUT" "add"
  cs_ok -h
  assert_contains "$OUT" "add"
}

test_help_for_a_command() {
  cs_ok help add
  assert_contains "$OUT" "--email"
  assert_contains "$OUT" "--dir"
  cs_ok help remove
  assert_contains "$OUT" "--keep-files"
  cs_ok help init
  assert_contains "$OUT" "zsh"
  assert_contains "$OUT" "fish"
}

test_every_command_has_help() {
  local c
  for c in pick list use current run claude add remove rename sync usage init statusline progress doctor config uninstall; do
    cs help "$c"
    [ "$RC" -eq 0 ] || fail "ccseat help $c exited $RC"
    [ -n "$OUT" ] || fail "ccseat help $c printed nothing"
    cs "$c" --help
    [ "$RC" -eq 0 ] || fail "ccseat $c --help exited $RC"
  done
  cs help no-such-command
  assert_failure "help for an unknown command"
}

test_help_text_has_no_abbreviations() {
  cs_ok help
  assert_no_match "$OUT" '(^|[^a-z])(wk|ctx)([^a-z]|$)' "help avoids wk/ctx"
  assert_not_contains "$OUT" $'\xe2\x80\x94' "help has no em dashes"
}

test_unknown_command_is_a_usage_error() {
  cs frobnicate
  assert_exit 2 "unknown command"
  assert_contains "$ERR" "frobnicate"
  assert_contains "$ERR" "help"
}

test_missing_argument_is_a_usage_error() {
  make_primary alice@example.com
  cs use
  assert_exit 2 "use without a seat"
  cs rename alice
  assert_exit 2 "rename without the new name"
  cs init
  assert_exit 2 "init without a shell"
  cs init powershell
  assert_exit 2 "init with an unknown shell"
}

test_config_defaults() {
  cs_ok config
  assert_match "$OUT" 'auto_switch[ =:]+on'
  assert_match "$OUT" 'limit_5h[ =:]+95'
  assert_match "$OUT" 'limit_weekly[ =:]+100'
  assert_match "$OUT" 'remember[ =:]+on'
  assert_match "$OUT" 'colors[ =:]+auto'
  assert_contains "$OUT" "share"
  cs_ok config limit_5h
  assert_eq 95 "$OUT"
  cs_ok config auto_switch
  assert_eq on "$OUT"
}

test_config_set_and_read_back() {
  cs_ok config limit_5h 80
  cs_ok config limit_5h
  assert_eq 80 "$OUT"
  assert_file "$(ccseat_home)/config"
  assert_contains "$(cat "$(ccseat_home)/config")" "limit_5h=80"
  cs_ok config auto_switch off
  cs_ok config auto_switch
  assert_eq off "$OUT"
  # Other keys keep their defaults.
  cs_ok config limit_weekly
  assert_eq 100 "$OUT"
}

test_config_rejects_bad_keys_and_values() {
  cs config no_such_key
  assert_failure "unknown key"
  cs config no_such_key 1
  assert_failure "unknown key on write"
  cs config limit_5h lots
  assert_failure "non-numeric limit"
  cs config auto_switch maybe
  assert_failure "auto_switch only takes on or off"
  cs_ok config limit_5h
  assert_eq 95 "$OUT" "a rejected value is not stored"
}

test_ccseat_home_override() {
  export CCSEAT_HOME="$T/custom-home"
  cs_ok config limit_weekly 90
  assert_file "$T/custom-home/config"
  assert_no_path "$HOME/.config/ccseat/config"
}

test_xdg_config_home_is_respected() {
  export XDG_CONFIG_HOME="$T/xdg-config"
  cs_ok config remember off
  assert_file "$T/xdg-config/ccseat/config"
}

test_runs_from_a_symlinked_entrypoint() {
  mkdir -p "$T/elsewhere/bin"
  ln -s "$REPO_ROOT/bin/ccseat" "$T/elsewhere/bin/ccseat"
  ln -s "$T/elsewhere/bin/ccseat" "$T/elsewhere/cs-link"
  run "$T/elsewhere/cs-link" version
  assert_success "ccseat runs through a chain of symlinks"
  assert_match "$OUT" '[0-9]+\.[0-9]+\.[0-9]+'
}

test_an_exported_cdpath_does_not_break_ccseat() {
  mkdir -p "$T/links b"
  ln -s "$REPO_ROOT/bin/ccseat" "$T/links b/two"
  (cd "$T" && CDPATH=.:/nonexistent "links b/two" version) >"$T/.out" 2>"$T/.err"
  assert_eq 0 "$?" "ccseat runs with CDPATH set: $(cat "$T/.err")"
  assert_match "$(cat "$T/.out")" '^ccseat [0-9]'
}

test_config_table_lines_up() {
  local w
  cs_ok config limit_5h 90
  export NO_COLOR=1
  run_pty -- bash -c 'stty cols 80 rows 30; exec ccseat config'
  assert_match "$OUT" 'limit_5h +90 +5-hour percent that counts as the limit \(default 95\)'
  assert_match "$OUT" 'share +14 items +shared with'
  w=$(widest_line "$OUT")
  [ "$w" -le 80 ] || fail "a config line is $w characters wide"
}

test_help_for_statusline_matches_its_own_help() {
  cs_ok help statusline
  assert_contains "$OUT" "--seat"
  assert_contains "$OUT" "--quiet"
  cs_ok help list
  assert_contains "$OUT" "offline"
  assert_contains "$OUT" "limit"
}
