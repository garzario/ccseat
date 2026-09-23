# shellcheck shell=bash
# Usage data: fetching, caching, reset times, statuses and token safety.

test_reset_times_round_to_the_nearest_minute() {
  pin_local_noon
  make_primary alice@example.com
  # The API reports 21:59:59.99 for a 10:00 PM reset.
  usage_fixture alice@example.com 12 $((MIDNIGHT + 22 * 3600)) 79 $((MIDNIGHT + 86400 + 9 * 3600))
  cs_ok usage alice
  assert_contains "$OUT" "10:00 PM"
  assert_contains "$OUT" "tomorrow 9:00 AM"
  assert_not_contains "$OUT" "9:59 PM"
  assert_not_contains "$OUT" "8:59 AM"
  assert_not_contains "$OUT" "09:00" "no leading zero on the hour"
  cs_ok list
  assert_contains "$OUT" "10:00 PM"
  assert_contains "$OUT" "tomorrow 9:00 AM"
}

test_reset_seconds_round_both_ways() {
  pin_local_noon
  make_primary alice@example.com
  # 6:20:29.99 PM and 6:21:31.99 PM (usage_fixture subtracts 0.01 s).
  usage_fixture alice@example.com 12 $((MIDNIGHT + 18 * 3600 + 20 * 60 + 30)) 79 $((MIDNIGHT + 18 * 3600 + 21 * 60 + 32))
  cs_ok usage alice
  assert_contains "$OUT" "6:20 PM"
  assert_contains "$OUT" "6:22 PM"
}

test_reset_later_in_the_week_shows_the_weekday() {
  local day
  pin_local_noon
  make_primary alice@example.com
  usage_fixture alice@example.com 12 $((MIDNIGHT + 13 * 3600)) 79 $((MIDNIGHT + 3 * 86400 + 6 * 3600))
  day=$(epoch_fmt $((MIDNIGHT + 3 * 86400 + 6 * 3600)) %A)
  cs_ok usage alice
  assert_contains "$OUT" "$day 6:00 AM"
  assert_contains "$OUT" "1:00 PM"
  assert_not_contains "$OUT" "tomorrow 1:00 PM"
}

test_usage_shows_both_windows() {
  local now
  now=$(now_epoch)
  make_primary alice@example.com
  usage_fixture alice@example.com 12.0 $((now + 7200)) 79.0 $((now + 3 * 86400))
  cs_ok usage alice
  assert_contains "$OUT" "5-hour"
  assert_contains "$OUT" "weekly"
  assert_contains "$OUT" "12%"
  assert_contains "$OUT" "79%"
  assert_not_contains "$OUT" "12.0"
  no_ansi "$OUT"
}

test_usage_defaults_to_the_current_seat() {
  local now
  now=$(now_epoch)
  make_primary alice@example.com
  add_seat bob@example.com
  usage_fixture alice@example.com 11 $((now + 7200)) 22 $((now + 86400))
  usage_fixture bob@example.com 33 $((now + 7200)) 44 $((now + 86400))
  cs_ok use bob
  cs_ok usage
  assert_contains "$OUT" "33%"
  assert_contains "$OUT" "44%"
  assert_not_contains "$OUT" "11%"
}

test_usage_json() {
  local now
  now=$(now_epoch)
  make_primary alice@example.com
  usage_fixture alice@example.com 12 $((now + 7200)) 79 $((now + 3 * 86400))
  cs_ok usage alice --json
  no_ansi "$OUT"
  assert_json "$OUT" 'type == "object" or type == "array"' "valid JSON"
  assert_json "$OUT" '[.. | numbers] | index(12) != null' "5-hour percent"
  assert_json "$OUT" '[.. | numbers] | index(79) != null' "weekly percent"
  assert_no_tokens
}

test_a_window_that_already_reset_reads_zero() {
  local now
  now=$(now_epoch)
  make_primary alice@example.com
  usage_fixture alice@example.com 88 $((now - 600)) 41 $((now + 86400))
  cs_ok usage alice
  assert_match "$OUT" '(^|[^0-9])0%' "the 5-hour window reads 0%"
  assert_not_contains "$OUT" "88%"
}

test_usage_is_cached() {
  local now tok
  now=$(now_epoch)
  make_primary alice@example.com
  tok=$(token_for alice@example.com)
  usage_fixture alice@example.com 12 $((now + 7200)) 79 $((now + 86400))
  cs_ok usage alice
  cs_ok usage alice
  assert_eq 1 "$(grep -c "^$tok$" "$STUB/curl.tokens")" "second call answered from the cache"
  cs_ok usage alice --refresh
  assert_eq 2 "$(grep -c "^$tok$" "$STUB/curl.tokens")" "--refresh fetches again"
}

test_cache_files_are_private_and_in_xdg_cache() {
  local now f
  now=$(now_epoch)
  export XDG_CACHE_HOME="$T/xdg-cache"
  make_primary alice@example.com
  usage_fixture alice@example.com 12 $((now + 7200)) 79 $((now + 86400))
  cs_ok usage alice
  f="$T/xdg-cache/ccseat/usage-alice.json"
  assert_file "$f"
  assert_mode "$f" 600
  assert_json "$(cat "$f")" '[.. | numbers] | index(12) != null'
  assert_not_contains "$(cat "$f")" "tok-" "no token in the cache"
}

test_tokens_go_to_curl_on_stdin() {
  local now tok
  now=$(now_epoch)
  make_primary alice@example.com
  add_seat bob@example.com
  tok=$(token_for bob@example.com)
  usage_fixture bob@example.com 12 $((now + 7200)) 79 $((now + 86400))
  cs_ok usage bob --refresh
  assert_contains "$(cat "$STUB/curl.tokens")" "$tok" "bob's token reached curl"
  assert_contains "$(cat "$STUB/curl.args")" "api/oauth/usage"
  assert_not_contains "$(cat "$STUB/curl.args")" "tok-" "a token was passed on the command line"
  assert_contains "$(cat "$STUB/curl.args")" "-K" "the header goes in a config read from stdin"
}

test_tokens_are_never_printed() {
  local now args
  now=$(now_epoch)
  make_primary alice@example.com
  add_seat bob@example.com
  usage_fixture alice@example.com 12 $((now + 7200)) 79 $((now + 86400))
  for args in "list" "list --json" "usage alice" "usage bob --json" "usage --refresh" "doctor" "current" "sync"; do
    # shellcheck disable=SC2086  # word splitting of the argument list is intended
    run ccseat $args
    assert_no_tokens
  done
}

test_logged_out_and_expired_seats_are_not_fetched() {
  make_primary alice@example.com
  add_seat bob@example.com
  add_seat carol@example.com
  rm -f "$(seat_dir bob)/.credentials.json"
  write_credentials "$(seat_dir carol)" carol@example.com expired
  : > "$STUB/curl.tokens"
  cs_ok list
  assert_not_contains "$(cat "$STUB/curl.tokens")" "$(token_for carol@example.com)" "expired token not sent"
  assert_match "$OUT" 'bob.*not logged in'
  assert_match "$OUT" 'carol.*idle'
}

test_seat_without_usage_data() {
  make_primary alice@example.com
  # No fixture: the API answers 401 for this token.
  cs_ok list
  assert_contains "$OUT" "alice"
  cs_ok usage alice
  assert_contains "$OUT$ERR" "alice"
}

test_keychain_credentials_are_used_on_macos() {
  local now dir svc
  [ "$(uname -s)" = Darwin ] || skip "Keychain is macOS only"
  now=$(now_epoch)
  mkdir -p "$HOME/.claude"
  write_credentials "$T/kc-primary" alice@example.com
  mv "$T/kc-primary/.credentials.json" "$STUB/keychain/Claude Code-credentials"
  set_email "$HOME/.claude.json" alice@example.com
  usage_fixture alice@example.com 12 $((now + 7200)) 79 $((now + 86400))
  cs_ok list
  assert_match "$OUT" 'alice.*12%.*79%' "the primary's Keychain login is found"
  # An extra dir: service name hashed from the dir path.
  dir="$T/kc-seat"
  mkdir -p "$dir"
  svc="Claude Code-credentials-$(sha8 "$dir")"
  write_credentials "$T/kc-tmp" bob@example.com
  mv "$T/kc-tmp/.credentials.json" "$STUB/keychain/$svc"
  set_email "$dir/.claude.json" bob@example.com
  usage_fixture bob@example.com 33 $((now + 7200)) 44 $((now + 86400))
  cs_ok add --dir "$dir"
  assert_not_contains "$(cat "$STUB/claude.log")" "auth login" "already logged in through the Keychain"
  cs_ok list
  assert_match "$OUT" 'bob.*33%.*44%'
  assert_not_contains "$(cat "$STUB/security.log")" "add-generic-password" "never writes to the Keychain"
  assert_not_contains "$(cat "$STUB/security.log")" "delete-generic-password" "never deletes from the Keychain"
}

test_usage_of_an_unknown_seat_fails() {
  make_primary alice@example.com
  cs usage nobody
  assert_failure
}

test_real_api_response_shape() {
  make_primary alice@example.com
  cp "$TESTS_DIR/fixtures/usage-response.json" "$STUB/usage/$(token_for alice@example.com).json"
  cs_ok usage alice
  assert_contains "$OUT" "37%"
  assert_contains "$OUT" "64%"
  cs_ok list --json
  assert_json "$OUT" '[.. | numbers] | index(37) != null'
}

test_usage_cache_keeps_only_the_usage() {
  local now f
  now=$(now_epoch)
  make_primary alice@example.com
  write_usage_json alice@example.com "$(jq -nc --arg r "$(iso $((now + 3600)))" '{
    five_hour: {utilization: 10, resets_at: $r}, seven_day: {utilization: 20, resets_at: $r},
    spend: {used: {amount_minor: 1234, currency: "USD"}, percent: 12},
    extra_usage: {is_enabled: false, user_disabled: true},
    limits: [{kind: "weekly_scoped", percent: 91, scope: {model: {display_name: "Fable"}}, resets_at: $r}]}')"
  cs_ok usage alice --refresh
  f="$(cache_dir)/usage-alice.json"
  assert_file "$f"
  assert_json "$(cat "$f")" 'has("spend") | not' "no spending details in the cache"
  assert_json "$(cat "$f")" 'has("extra_usage") | not'
  assert_json "$(cat "$f")" '.five_hour.utilization == 10 and (.limits | length) == 1'
}

test_weekly_limit_of_one_model_is_shown() {
  local now
  now=$(now_epoch)
  make_primary alice@example.com
  write_usage_json alice@example.com "$(jq -nc --arg r "$(iso $((now + 3 * 86400)))" '{
    five_hour: {utilization: 0, resets_at: null}, seven_day: {utilization: 100, resets_at: $r},
    limits: [{kind: "weekly", group: "weekly", percent: 100},
             {kind: "weekly_scoped", group: "weekly", percent: 91, severity: "critical",
              scope: {model: {display_name: "Fable"}}, resets_at: $r}]}')"
  cs_ok usage alice --refresh
  assert_match "$OUT" 'Fable weekly +[●○]{10} +91%' "a model's weekly limit gets its own bar"
  cs_ok list --json
  assert_json "$OUT" '.[0].weekly_by_model == [{model: "Fable", percent: 91, resets_at: .[0].weekly.resets_at}]'
}

test_a_refused_login_is_not_called_expired() {
  make_primary alice@example.com
  # No fixture: the API answers 401 although the token has hours left.
  cs_ok list
  assert_contains "$OUT" "usage unavailable"
  assert_not_contains "$OUT" "expired"
  cs_ok usage alice
  assert_contains "$OUT" "ccseat run alice"
}
