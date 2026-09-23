# shellcheck shell=bash
# Seat registry: first run, add, adopt, naming, use, rename, remove, sync and
# the shared links.

# ---------- first run ----------

test_first_run_registers_the_logged_in_primary() {
  make_primary Alice@Example.com
  cs_ok list
  assert_contains "$OUT" "alice"
  assert_file "$(seats_file)"
  assert_eq alice "$(seat_names | head -1)" "the primary is the first seat, named by its email"
  same_dir "$(seat_dir alice)" "$HOME/.claude" || fail "the primary seat points at ~/.claude (got $(seat_dir alice))"
}

test_first_run_without_login_registers_nothing() {
  mkdir -p "$HOME/.claude"
  cs list
  assert_success
  assert_eq "" "$(seat_names)" "no seat without a login"
  assert_contains "$OUT$ERR" "ccseat add" "tells the user how to add a seat"
}

test_primary_is_registered_once() {
  make_primary alice@example.com
  cs_ok list
  cs_ok list
  cs_ok current
  assert_eq 1 "$(seat_names | grep -c '^alice$')" "alice appears once"
}

# ---------- add ----------

test_add_creates_a_logged_in_seat() {
  local dir
  make_primary alice@example.com
  add_seat bob@example.com
  assert_contains "$OUT" "Added bob (bob@example.com)."
  assert_contains "$OUT" "Open it with: ccseat run bob"
  dir=$(seat_dir bob)
  [ -n "$dir" ] || fail "bob is registered"
  assert_dir "$dir"
  case "$(physical "$dir")" in
    "$(physical "$(data_seats_dir)")"/*) ;;
    *) fail "new seat dirs live under $(data_seats_dir) (got $dir)" ;;
  esac
  assert_mode "$dir" 700
  assert_file "$dir/.credentials.json"
  assert_contains "$(cat "$STUB/claude.log")" "auth login"
  assert_no_tokens
}

test_add_passes_the_email_to_login() {
  make_primary alice@example.com
  run ccseat add --email Carol.Diaz@Example.com
  assert_success "add --email"
  assert_contains "$(grep 'auth login' "$STUB/claude.log")" "--email Carol.Diaz@Example.com"
  [ -n "$(seat_dir carol.diaz)" ] || fail "the seat is named by the lowercased local part (seats: $(seat_names | tr '\n' ' '))"
  assert_contains "$OUT" "Added carol.diaz (Carol.Diaz@Example.com)"
}

test_add_names_by_the_account_that_actually_logged_in() {
  make_primary alice@example.com
  # The user asked for dave@ but signed in as erin@ in the browser.
  CCSEAT_STUB_LOGIN_EMAIL=erin@example.com run ccseat add --email dave@example.com
  assert_success
  [ -n "$(seat_dir erin)" ] || fail "seat named after the logged-in account (seats: $(seat_names | tr '\n' ' '))"
  [ -z "$(seat_dir dave)" ] || fail "no seat named after the requested email"
}

test_add_with_a_name() {
  make_primary alice@example.com
  add_seat bob@example.com --name work
  [ -n "$(seat_dir work)" ] || fail "seat named work (seats: $(seat_names | tr '\n' ' '))"
  [ -z "$(seat_dir bob)" ] || fail "no seat named bob"
}

test_add_name_collisions_get_a_suffix() {
  make_primary alice@example.com
  add_seat alice@work.example
  add_seat ALICE@school.example
  assert_eq "alice alice-2 alice-3" "$(seat_names | tr '\n' ' ' | sed 's/ $//')"
}

test_add_several_accounts() {
  local e
  make_primary alice@example.com
  for e in bob@example.com carol@example.com dave@example.com eve@example.com frank@example.com; do
    add_seat "$e"
  done
  assert_eq 6 "$(seat_names | grep -c .)" "six seats"
  cs_ok list
  for e in alice bob carol dave eve frank; do assert_contains "$OUT" "$e"; done
}

test_add_without_a_primary_login() {
  add_seat bob@example.com
  assert_eq bob "$(seat_names | tr '\n' ' ' | sed 's/ $//')" "only bob is registered"
}

test_add_skips_login_when_already_logged_in() {
  make_primary alice@example.com
  login_seat_dir "$T/existing" carol@example.com
  run ccseat add --dir "$T/existing"
  assert_success "adopting a logged-in dir"
  assert_not_contains "$(cat "$STUB/claude.log")" "auth login" "no second login"
  assert_contains "$OUT" "Added carol (carol@example.com)."
  assert_contains "$OUT" "Open it with: ccseat run carol"
  same_dir "$(seat_dir carol)" "$T/existing" || fail "the adopted dir is used in place"
  assert_file "$T/existing/.credentials.json"
}

test_add_adopts_a_dir_that_needs_login() {
  make_primary alice@example.com
  mkdir -p "$T/fresh"
  CCSEAT_STUB_LOGIN_EMAIL=dora@example.com run ccseat add --dir "$T/fresh"
  assert_success
  assert_contains "$(cat "$STUB/claude.log")" "auth login"
  same_dir "$(seat_dir dora)" "$T/fresh" || fail "dora uses the adopted dir"
}

test_add_adopting_the_same_dir_twice_does_not_duplicate() {
  make_primary alice@example.com
  login_seat_dir "$T/existing" carol@example.com
  cs_ok add --dir "$T/existing"
  cs add --dir "$T/existing"
  assert_eq 1 "$(seat_names | grep -c '^carol')" "carol is registered once"
}

test_add_that_fails_to_log_in_registers_nothing() {
  make_primary alice@example.com
  CCSEAT_STUB_LOGIN_FAIL=1 run ccseat add
  assert_failure "a cancelled login fails the command"
  assert_eq alice "$(seat_names | tr '\n' ' ' | sed 's/ $//')" "nothing new registered"
}

test_add_sets_up_shared_links_and_sync() {
  local dir gc
  make_primary alice@example.com
  add_seat bob@example.com
  dir=$(seat_dir bob)
  assert_symlink "$dir/settings.json" "$HOME/.claude/settings.json"
  gc=$(global_config "$dir")
  assert_file "$gc"
  assert_json "$(cat "$gc")" '.mcpServers.github.command == "gh-mcp"' "MCP servers copied at add"
  assert_json "$(cat "$gc")" '.hasCompletedOnboarding == true' "onboarding skipped"
}

test_add_respects_xdg_data_home() {
  export XDG_DATA_HOME="$T/xdg-data"
  make_primary alice@example.com
  add_seat bob@example.com
  case "$(physical "$(seat_dir bob)")" in
    "$(physical "$T/xdg-data")"/ccseat/seats/*) ;;
    *) fail "seat dir under XDG_DATA_HOME (got $(seat_dir bob))" ;;
  esac
}

# ---------- shared links ----------

test_shared_links_point_into_the_primary() {
  local dir item
  make_primary alice@example.com
  add_seat bob@example.com
  dir=$(seat_dir bob)
  for item in settings.json CLAUDE.md skills agents commands rules hooks output-styles plugins projects plans todos history.jsonl; do
    assert_symlink "$dir/$item" "$HOME/.claude/$item"
  done
  assert_file "$dir/skills/hello/SKILL.md"
  assert_contains "$(cat "$dir/CLAUDE.md")" "Be brief."
}

test_shared_links_create_missing_targets() {
  local dir item
  mkdir -p "$HOME/.claude"
  write_credentials "$HOME/.claude" alice@example.com
  set_email "$HOME/.claude.json" alice@example.com
  add_seat bob@example.com
  dir=$(seat_dir bob)
  for item in settings.json CLAUDE.md skills agents commands projects plans todos history.jsonl; do
    assert_symlink "$dir/$item"
    [ -e "$HOME/.claude/$item" ] || fail "missing target created in the primary: $item"
  done
}

test_private_files_are_never_shared() {
  local dir item
  make_primary alice@example.com
  mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/statsig" "$HOME/.claude/shell-snapshots" "$HOME/.claude/ide"
  add_seat bob@example.com
  dir=$(seat_dir bob)
  for item in .credentials.json .claude.json .config.json sessions session-env statsig telemetry state cache shell-snapshots ide daemon tasks teams; do
    assert_not_symlink "$dir/$item"
  done
  assert_ne "$(physical "$dir/.credentials.json")" "$(physical "$HOME/.claude/.credentials.json")" "own credentials"
}

test_projects_are_shared_both_ways() {
  local dir
  make_primary alice@example.com
  add_seat bob@example.com
  dir=$(seat_dir bob)
  mkdir -p "$dir/projects/-work-app"
  printf '{}\n' > "$dir/projects/-work-app/session.jsonl"
  assert_file "$HOME/.claude/projects/-work-app/session.jsonl" "a session saved by one seat can be resumed from another"
}

test_existing_file_in_adopted_dir_is_not_lost() {
  local dir found d
  make_primary alice@example.com
  login_seat_dir "$T/adopt" carol@example.com
  printf '{"model":"haiku"}\n' > "$T/adopt/settings.json"
  cs_ok add --dir "$T/adopt"
  dir=$(seat_dir carol)
  if [ -L "$dir/settings.json" ]; then
    # Replaced by the shared link: the old file must be kept somewhere.
    found=0
    for d in "$T/adopt" "$HOME/.Trash" "$(ccseat_home)"; do
      [ -d "$d" ] && grep -rlq '"haiku"' "$d" 2>/dev/null && found=1
    done
    [ "$found" -eq 1 ] || fail "the adopted dir's own settings.json was replaced without a backup"
  else
    assert_contains "$(cat "$dir/settings.json")" "haiku"
  fi
}

# ---------- list ----------

test_list_shows_usage_per_seat() {
  local now
  now=$(now_epoch)
  make_primary alice@example.com
  add_seat bob@example.com
  usage_fixture alice@example.com 12.0 $((now + 7200)) 79.0 $((now + 3 * 86400))
  usage_fixture bob@example.com 3.0 $((now + 3600)) 41.0 $((now + 2 * 86400))
  cs_ok list
  assert_contains "$OUT" "5-hour"
  assert_contains "$OUT" "weekly"
  assert_match "$OUT" 'alice.*12%.*79%'
  assert_match "$OUT" 'bob.*3%.*41%'
  assert_match "$OUT" 'alice.*live'
  assert_match "$OUT" '^[^a-z]*1[^0-9].*alice' "row numbers start at 1"
  assert_match "$OUT" '^[^a-z]*2[^0-9].*bob'
  no_ansi "$OUT" "no colors when stdout is not a terminal"
  assert_no_tokens
}

test_list_marks_the_current_seat() {
  local a b
  make_primary alice@example.com
  add_seat bob@example.com
  cs_ok use bob
  cs_ok list
  # Same data for both rows, so once the names and numbers are gone only the
  # current-seat marker can tell them apart.
  a=$(printf '%s\n' "$OUT" | grep 'alice' | head -1 | sed 's/alice//' | tr -d '0-9 ')
  b=$(printf '%s\n' "$OUT" | grep 'bob' | head -1 | sed 's/bob//' | tr -d '0-9 ')
  assert_ne "$a" "$b" "the current seat's row is marked"
}

test_list_statuses() {
  local now
  now=$(now_epoch)
  make_primary alice@example.com
  add_seat bob@example.com
  add_seat carol@example.com
  usage_fixture alice@example.com 10 $((now + 7200)) 20 $((now + 86400 * 3))
  # bob logged out, carol's token expired.
  rm -f "$(seat_dir bob)/.credentials.json"
  write_credentials "$(seat_dir carol)" carol@example.com expired
  cs_ok list
  assert_match "$OUT" 'alice.*live'
  assert_match "$OUT" 'bob.*not logged in'
  assert_match "$OUT" 'carol.*idle' "an expired token is the normal idle state"
  assert_not_contains "$OUT" "token expired"
}

test_list_uses_the_cache_when_the_api_fails() {
  local now f
  now=$(now_epoch)
  make_primary alice@example.com
  usage_fixture alice@example.com 33 $((now + 7200)) 44 $((now + 86400 * 3))
  cs_ok list
  assert_match "$OUT" 'alice.*33%.*44%.*live'
  for f in "$(cache_dir)"/*; do [ -f "$f" ] && set_age "$f" 185; done
  : > "$STUB/curl_fail"
  cs_ok list
  assert_match "$OUT" 'alice.*33%.*44%' "cached numbers are shown"
  assert_match "$OUT" 'alice.*3 min ago' "the status says how old the data is"
}

test_list_json() {
  local now
  now=$(now_epoch)
  make_primary alice@example.com
  add_seat bob@example.com
  usage_fixture alice@example.com 12 $((now + 7200)) 79 $((now + 3 * 86400))
  rm -f "$(seat_dir bob)/.credentials.json"
  cs_ok use alice
  cs_ok list --json
  no_ansi "$OUT"
  assert_json "$OUT" 'type == "array" and length == 2' "an array with two seats"
  assert_json "$OUT" '.[0] | .index == 1 and .name == "alice" and .email == "alice@example.com"'
  assert_json "$OUT" '.[0] | .primary == true and .current == true and .logged_in == true'
  assert_json "$OUT" '.[0].five_hour.percent == 12 and .[0].weekly.percent == 79'
  assert_json "$OUT" '.[0].five_hour.resets_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "reset as an ISO date"
  assert_json "$OUT" '.[0].status == "live"'
  assert_json "$OUT" '.[1] | .index == 2 and .name == "bob" and .logged_in == false and .current == false'
  assert_json "$OUT" '.[1].status == "not logged in"'
  assert_no_tokens
}

test_list_json_without_seats_is_valid() {
  cs_ok list --json
  assert_json "$OUT" 'type == "array" and length == 0'
}

test_bare_ccseat_without_a_terminal_lists() {
  make_primary alice@example.com
  cs_ok
  assert_contains "$OUT" "alice"
  assert_eq 0 "$(launch_count)" "nothing launched without a terminal"
}

# ---------- use / current ----------

test_use_and_current() {
  make_primary alice@example.com
  add_seat bob@example.com
  cs_ok use bob
  cs_ok current
  assert_eq bob "$OUT"
  assert_eq bob "$(cat "$(ccseat_home)/current")"
  assert_eq 0 "$(launch_count)" "use does not launch"
}

test_current_defaults_to_the_primary() {
  make_primary alice@example.com
  add_seat bob@example.com
  rm -f "$(ccseat_home)/current"
  cs_ok current
  assert_eq alice "$OUT"
}

test_seat_references_by_index_and_prefix() {
  make_primary alice@example.com
  add_seat bob@example.com
  add_seat carol@example.com
  cs_ok use 2
  cs_ok current
  assert_eq bob "$OUT" "index 2"
  cs_ok use car
  cs_ok current
  assert_eq carol "$OUT" "unique prefix"
}

test_bad_seat_references_fail() {
  make_primary alice@example.com
  add_seat alan@example.com
  cs use al
  assert_failure "ambiguous prefix"
  assert_contains "$ERR" "alice"
  assert_contains "$ERR" "alan"
  cs use zed
  assert_failure "unknown seat"
  assert_contains "$ERR" "zed"
  cs use 9
  assert_failure "index out of range"
  cs_ok current
  assert_eq alice "$OUT" "failed use keeps the current seat"
}

# ---------- rename ----------

test_rename_keeps_the_dir_and_current() {
  local dir
  make_primary alice@example.com
  add_seat bob@example.com
  dir=$(seat_dir bob)
  cs_ok use bob
  cs_ok rename bob robert
  assert_eq "$dir" "$(seat_dir robert)" "same config dir"
  [ -z "$(seat_dir bob)" ] || fail "old name gone"
  cs_ok current
  assert_eq robert "$OUT" "current follows the rename"
  assert_dir "$dir"
}

test_rename_the_primary() {
  make_primary alice@example.com
  cs_ok list
  cs_ok rename alice me
  same_dir "$(seat_dir me)" "$HOME/.claude" || fail "renamed primary keeps ~/.claude"
  run ccseat run me
  assert_contains "$OUT" "CLAUDE_CONFIG_DIR=<unset>"
}

test_rename_rejects_taken_and_invalid_names() {
  make_primary alice@example.com
  add_seat bob@example.com
  cs rename bob alice
  assert_failure "name taken"
  cs rename bob "has space"
  assert_failure "space in name"
  cs rename bob "a/b"
  assert_failure "slash in name"
  cs rename bob 7
  assert_failure "a number would clash with list indexes"
  [ -n "$(seat_dir bob)" ] || fail "bob is untouched"
}

# ---------- remove ----------

test_remove_moves_the_dir_to_the_trash() {
  local dir base
  make_primary alice@example.com
  add_seat bob@example.com
  dir=$(seat_dir bob)
  base=$(basename "$dir")
  cs_ok remove bob -y
  [ -z "$(seat_dir bob)" ] || fail "bob unregistered"
  assert_no_path "$dir" "the seat dir left its place"
  in_trash "$base" || fail "the seat dir is in the Trash ($(find "$HOME/.Trash" "$HOME/.local/share/Trash" -maxdepth 2 2>&1 | tr '\n' ' '))"
  assert_dir "$HOME/.claude" "the primary is untouched"
}

test_remove_keep_files() {
  local dir
  make_primary alice@example.com
  add_seat bob@example.com
  dir=$(seat_dir bob)
  cs_ok remove bob --keep-files -y
  [ -z "$(seat_dir bob)" ] || fail "bob unregistered"
  assert_dir "$dir"
  assert_file "$dir/.credentials.json"
}

test_remove_refuses_the_primary() {
  make_primary alice@example.com
  add_seat bob@example.com
  cs remove alice -y
  assert_failure "the primary cannot be removed"
  [ -n "$(seat_dir alice)" ] || fail "alice still registered"
  assert_file "$HOME/.claude/.credentials.json"
  assert_file "$HOME/.claude/settings.json"
}

test_remove_asks_before_deleting() {
  local dir
  make_primary alice@example.com
  add_seat bob@example.com
  dir=$(seat_dir bob)
  cs remove bob
  assert_failure "without -y and without a terminal nothing is removed"
  [ -n "$(seat_dir bob)" ] || fail "bob still registered"
  assert_dir "$dir"
}

test_remove_the_current_seat_falls_back() {
  make_primary alice@example.com
  add_seat bob@example.com
  cs_ok use bob
  cs_ok remove bob -y
  cs_ok current
  assert_eq alice "$OUT"
}

test_remove_never_touches_shared_targets() {
  make_primary alice@example.com
  add_seat bob@example.com
  cs_ok remove bob -y
  assert_file "$HOME/.claude/settings.json"
  assert_file "$HOME/.claude/CLAUDE.md"
  assert_file "$HOME/.claude/skills/hello/SKILL.md"
  assert_file "$HOME/.claude/history.jsonl"
}

# ---------- sync ----------

test_sync_copies_mcp_servers_trust_and_onboarding() {
  local dir gc
  make_primary alice@example.com
  add_seat bob@example.com
  dir=$(seat_dir bob)
  gc=$(global_config "$dir")
  # Primary changes after the seat was added.
  jq --arg c "$HOME/work/new" '.mcpServers.linear = {type: "http", url: "https://linear.example/mcp"}
     | .projects[$c] = {hasTrustDialogAccepted: true}' "$HOME/.claude.json" > "$T/p" && mv "$T/p" "$HOME/.claude.json"
  cs_ok sync
  assert_json "$(cat "$gc")" '.mcpServers | keys == ["docs", "github", "linear"]'
  assert_json "$(cat "$gc")" '.mcpServers.github.env.GITHUB_TOKEN == "secret-value"'
  assert_json "$(jq --arg a "$HOME/work/app" '.projects[$a].hasTrustDialogAccepted' "$gc")" '. == true' "trusted folder copied"
  assert_json "$(jq --arg a "$HOME/work/new" '.projects[$a].hasTrustDialogAccepted' "$gc")" '. == true' "new trusted folder copied"
  assert_json "$(jq --arg b "$HOME/work/untrusted" '.projects[$b].hasTrustDialogAccepted // false' "$gc")" '. == false' "untrusted folder stays untrusted"
  assert_json "$(cat "$gc")" '.hasCompletedOnboarding == true'
  assert_json "$(cat "$gc")" '.oauthAccount.emailAddress == "bob@example.com"' "the seat keeps its own account"
  assert_not_contains "$OUT$ERR" "secret-value" "server values are never printed"
}

test_sync_does_not_modify_the_primary() {
  local before
  make_primary alice@example.com
  add_seat bob@example.com
  before=$(cat "$HOME/.claude.json")
  cs_ok sync
  assert_eq "$before" "$(cat "$HOME/.claude.json")" "primary .claude.json unchanged"
}

test_sync_writes_the_legacy_config_json() {
  make_primary alice@example.com
  login_seat_dir "$T/legacy" carol@example.com
  mv "$T/legacy/.claude.json" "$T/legacy/.config.json"
  cs_ok add --dir "$T/legacy"
  cs_ok sync carol
  assert_json "$(cat "$T/legacy/.config.json")" '.mcpServers.github.command == "gh-mcp"' "sync writes .config.json when it exists"
  assert_no_path "$T/legacy/.claude.json" "no second global config created"
}

test_sync_one_seat() {
  make_primary alice@example.com
  add_seat bob@example.com
  add_seat carol@example.com
  jq '.mcpServers.extra = {type: "http", url: "https://x.example"}' "$HOME/.claude.json" > "$T/p" && mv "$T/p" "$HOME/.claude.json"
  cs_ok sync bob
  assert_json "$(cat "$(global_config "$(seat_dir bob)")")" '.mcpServers.extra != null'
  assert_json "$(cat "$(global_config "$(seat_dir carol)")")" '.mcpServers.extra == null' "only bob synced"
}

test_seat_config_files_stay_private() {
  make_primary alice@example.com
  add_seat bob@example.com
  cs_ok sync
  assert_mode "$(global_config "$(seat_dir bob)")" 600
}

# ---------- adopting folders safely ----------

test_add_dir_through_a_link_to_the_primary_changes_nothing() {
  local before
  make_primary alice@example.com
  cs_ok list
  ln -s "$HOME/.claude" "$HOME/.claude-alias"
  before=$(cd "$HOME/.claude" && ls -la)
  cs add --dir "$HOME/.claude-alias"
  assert_failure "a link to ~/.claude is ~/.claude, already the seat alice"
  assert_contains "$ERR" "alice"
  assert_eq "$before" "$(cd "$HOME/.claude" && ls -la)" "the primary folder is untouched"
  assert_not_symlink "$HOME/.claude/settings.json"
  assert_contains "$(cat "$HOME/.claude/settings.json")" '"model": "opus"'
  assert_contains "$(cat "$HOME/.claude/CLAUDE.md")" "Be brief."
  assert_file "$HOME/.claude/skills/hello/SKILL.md"
  assert_no_path "$HOME/.claude/.ccseat-backup"
  assert_eq alice "$(seat_names | tr '\n' ' ' | sed 's/ $//')"
}

test_add_dir_through_a_link_to_an_unregistered_primary() {
  mkdir -p "$HOME/.claude"
  printf '# Memory\n' > "$HOME/.claude/CLAUDE.md"
  login_seat_dir "$T/other" bob@example.com
  cs_ok add --dir "$T/other"
  ln -s "$HOME/.claude" "$HOME/.claude-main"
  CCSEAT_STUB_LOGIN_EMAIL=alice@example.com run ccseat add --dir "$HOME/.claude-main"
  assert_success "it becomes the primary seat"
  same_dir "$(seat_dir alice)" "$HOME/.claude" || fail "registered as ~/.claude itself (got $(seat_dir alice))"
  assert_eq "$HOME/.claude" "$(seat_dir alice)" "the plain path, so it launches with CLAUDE_CONFIG_DIR unset"
  assert_not_symlink "$HOME/.claude/CLAUDE.md"
}

test_add_dir_that_holds_home_or_the_primary_is_refused() {
  local before
  make_primary alice@example.com
  cs_ok list
  before=$(cat "$HOME/.claude.json")
  ln -s "$HOME" "$T/homelink"
  CCSEAT_STUB_LOGIN_EMAIL=bob@example.com run ccseat add --dir "$T/homelink"
  assert_failure "a link to the home folder"
  assert_eq "$before" "$(cat "$HOME/.claude.json")" "the primary login is untouched"
  mkdir -p "$HOME/.claude/inner"
  ln -s "$HOME/.claude/inner" "$T/innerlink"
  cs add --dir "$T/innerlink"
  assert_failure "a folder inside ~/.claude"
  assert_contains "$ERR" "inside ~/.claude"
  cs add --dir "$(ccseat_home)"
  assert_failure "ccseat's own folder"
  assert_not_contains "$(cat "$STUB/claude.log" 2>/dev/null)" "auth login" "no login was started"
}

test_add_dir_refuses_a_git_repository() {
  local d
  command -v git >/dev/null 2>&1 || skip "git is not installed"
  make_primary alice@example.com
  cs_ok list
  mkdir -p "$HOME/code/webapp/src" "$HOME/code/webapp/.claude/commands"
  printf '# Project memory\n' > "$HOME/code/webapp/CLAUDE.md"
  printf '{"model":"haiku"}\n' > "$HOME/code/webapp/.claude/settings.json"
  printf 'Deploy the app.\n' > "$HOME/code/webapp/.claude/commands/deploy.md"
  git -C "$HOME/code/webapp" init -q || fail "git init"
  for d in "$HOME/code/webapp" "$HOME/code/webapp/src" "$HOME/code/webapp/new-folder"; do
    CCSEAT_STUB_LOGIN_EMAIL=bob@example.com run ccseat add --dir "$d"
    assert_failure "adopting $d"
    assert_contains "$ERR" "git repository"
  done
  CCSEAT_STUB_LOGIN_EMAIL=bob@example.com run ccseat add --dir "$HOME/code/webapp/.claude"
  assert_failure "adopting a project's .claude folder"
  assert_contains "$ERR" ".claude folder"
  assert_no_path "$HOME/code/webapp/.claude.json"
  assert_no_path "$HOME/code/webapp/.claude/.claude.json"
  assert_no_path "$HOME/code/webapp/.ccseat-backup"
  assert_no_path "$HOME/code/webapp/new-folder"
  assert_not_symlink "$HOME/code/webapp/CLAUDE.md"
  assert_not_symlink "$HOME/code/webapp/.claude/settings.json"
  assert_file "$HOME/code/webapp/.claude/commands/deploy.md"
  assert_no_path "$HOME/.claude/commands/deploy.md" "the project's commands joined ~/.claude"
  assert_eq alice "$(seat_names | tr '\n' ' ' | sed 's/ $//')" "nothing was added"
  assert_not_contains "$(cat "$STUB/claude.log" 2>/dev/null)" "auth login" "no login was started"
}

test_add_dir_needs_more_than_project_files() {
  make_primary alice@example.com
  mkdir -p "$T/notes/projects"
  printf '# Notes\n' > "$T/notes/CLAUDE.md"
  printf '{}\n' > "$T/notes/settings.json"
  CCSEAT_STUB_LOGIN_EMAIL=bob@example.com run ccseat add --dir "$T/notes"
  assert_failure "CLAUDE.md, settings.json and projects are not proof of a config folder"
  assert_contains "$ERR" "does not look like a Claude Code config folder"
  assert_no_path "$T/notes/.claude.json"
  assert_not_symlink "$T/notes/CLAUDE.md"
}

test_add_dir_works_in_a_home_kept_in_git() {
  command -v git >/dev/null 2>&1 || skip "git is not installed"
  make_primary alice@example.com
  git -C "$HOME" init -q || fail "git init"
  login_seat_dir "$HOME/.claude-work" bob@example.com
  cs_ok add --dir "$HOME/.claude-work"
  assert_contains "$OUT" "Added bob"
}

test_adopt_moves_a_file_the_primary_lacks() {
  mkdir -p "$HOME/.claude"
  write_credentials "$HOME/.claude" alice@example.com
  set_email "$HOME/.claude.json" alice@example.com
  login_seat_dir "$HOME/.claude-work" bob@example.com
  printf '# Work memory\nAlways use pnpm.\n' > "$HOME/.claude-work/CLAUDE.md"
  cs_ok add --dir "$HOME/.claude-work"
  assert_symlink "$HOME/.claude-work/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
  assert_contains "$(cat "$HOME/.claude/CLAUDE.md")" "Always use pnpm." "the seat's memory became the shared one"
  assert_contains "$OUT" "CLAUDE.md"
}

test_adopt_notes_are_short_and_clear() {
  local w
  make_primary alice@example.com
  login_seat_dir "$HOME/.claude-work" carol@example.com
  printf '{"model":"haiku"}\n' > "$HOME/.claude-work/settings.json"
  mkdir -p "$HOME/.claude-work/skills/mine" "$HOME/.claude-work/projects/-work-app"
  printf 'x\n' > "$HOME/.claude-work/skills/mine/SKILL.md"
  printf '{}\n' > "$HOME/.claude-work/projects/-work-app/s.jsonl"
  cs_ok add --dir "$HOME/.claude-work"
  assert_contains "$OUT" "It now shares"
  assert_contains "$OUT" ".ccseat-backup"
  assert_contains "$OUT" "Copied 1 skill and 1 project that ~/.claude did not have."
  assert_not_contains "$OUT" "kept its own"
  w=$(widest_line "$OUT")
  [ "$w" -le 80 ] || fail "an add line is $w characters wide"
  assert_file "$HOME/.claude/skills/mine/SKILL.md"
}

test_file_history_is_shared() {
  make_primary alice@example.com
  add_seat bob@example.com
  assert_symlink "$(seat_dir bob)/file-history" "$HOME/.claude/file-history"
}

# ---------- logins ----------

test_first_add_signs_in_to_the_primary() {
  CCSEAT_STUB_LOGIN_EMAIL=alice@example.com run ccseat add
  assert_success
  assert_eq "$HOME/.claude" "$(seat_dir alice)" "the first account is ~/.claude itself"
  assert_contains "$(cat "$STUB/claude.log")" "auth login  dir=<unset>"
  add_seat bob@example.com
  case "$(physical "$(seat_dir bob)")" in
    "$(physical "$(data_seats_dir)")"/*) ;;
    *) fail "the next seats get folders of their own (got $(seat_dir bob))" ;;
  esac
}

test_add_says_why_the_same_account_came_back() {
  make_primary alice@example.com
  add_seat bob@example.com
  CCSEAT_STUB_LOGIN_EMAIL=bob@example.com run ccseat add
  assert_failure
  assert_contains "$ERR" "the browser signed in as bob@example.com"
  assert_contains "$ERR" "private window"
  assert_contains "$OUT" "switch accounts there first" "the hint comes before the login"
  assert_eq "alice bob" "$(seat_names | tr '\n' ' ' | sed 's/ $//')"
  [ "$(widest_line "$ERR")" -le 80 ] || fail "error lines fit in 80 columns"
}

test_first_run_points_at_other_logins() {
  make_primary alice@example.com
  login_seat_dir "$HOME/.claude-work" bob@example.com
  login_seat_dir "$HOME/.claude-personal" carol@example.com
  cs_ok list
  assert_contains "$ERR" "Found 2 more logins"
  assert_contains "$ERR" "ccseat add --dir ~/.claude-work"
  assert_contains "$ERR" "ccseat add --dir ~/.claude-personal"
  cs_ok add --dir "$HOME/.claude-work"
  assert_not_contains "$(cat "$STUB/claude.log" 2>/dev/null)" "auth login" "no second sign-in"
}

test_add_after_a_stale_keychain_login_signs_in_fresh() {
  local dir svc
  [ "$(uname -s)" = Darwin ] || skip "Keychain is macOS only"
  make_primary alice@example.com
  dir="$(data_seats_dir)/seat"
  svc="Claude Code-credentials-$(sha8 "$dir")"
  write_credentials "$T/kc-tmp" bob@example.com
  mv "$T/kc-tmp/.credentials.json" "$STUB/keychain/$svc"
  CCSEAT_STUB_LOGIN_EMAIL=dave@example.com run ccseat add
  assert_success
  assert_contains "$(cat "$STUB/claude.log")" "auth login" "a new folder always signs in"
  [ -n "$(seat_dir dave)" ] || fail "the new account is registered (seats: $(seat_names | tr '\n' ' '))"
}

test_remove_signs_out_even_when_the_folder_is_gone() {
  local dir svc
  [ "$(uname -s)" = Darwin ] || skip "Keychain is macOS only"
  make_primary alice@example.com
  dir="$T/kc-seat"
  mkdir -p "$dir"
  svc="Claude Code-credentials-$(sha8 "$dir")"
  write_credentials "$T/kc-tmp" bob@example.com
  mv "$T/kc-tmp/.credentials.json" "$STUB/keychain/$svc"
  set_email "$dir/.claude.json" bob@example.com
  cs_ok add --dir "$dir"
  mv "$dir" "$T/moved-away"
  cs_ok remove bob -y
  assert_contains "$(cat "$STUB/claude.log")" "auth logout" "the Keychain login is signed out"
  assert_no_path "$STUB/keychain/$svc"
}

test_commands_that_read_logins_need_jq() {
  make_primary alice@example.com
  add_seat bob@example.com
  : > "$STUB/claude.log"
  for args in "run bob" "use bob" "remove bob -y" "rename bob robert" "bob"; do
    # shellcheck disable=SC2086 # the argument list
    PATH="$(path_without jq)" run ccseat $args
    assert_failure "ccseat $args without jq"
    assert_contains "$ERR" "jq"
  done
  assert_eq "" "$(cat "$STUB/claude.log")" "no login, logout or launch without jq"
  [ -n "$(seat_dir bob)" ] || fail "bob is still a seat"
}

test_concurrent_adds_keep_every_seat() {
  make_primary alice@example.com
  cs_ok list
  CCSEAT_STUB_LOGIN_DELAY=2 CCSEAT_STUB_LOGIN_EMAIL=bob@example.com ccseat add </dev/null >"$T/a1" 2>&1 &
  sleep 0.5
  CCSEAT_STUB_LOGIN_DELAY=1 CCSEAT_STUB_LOGIN_EMAIL=carol@example.com ccseat add </dev/null >"$T/a2" 2>&1 &
  wait
  assert_eq "alice bob carol" "$(seat_names | sort | tr '\n' ' ' | sed 's/ $//')" "both logins are registered"
}

test_share_rejects_patterns() {
  make_primary alice@example.com
  add_seat bob@example.com
  mkdir -p "$T/work/src"
  touch "$T/work/Makefile" "$T/work/README.md"
  (cd "$T/work" && ccseat config share 'settings.json,CLAUDE.md,*') >"$T/.out" 2>"$T/.err"
  assert_ne 0 "$?" "a pattern is refused"
  assert_no_path "$HOME/.claude/Makefile"
  assert_no_path "$HOME/.claude/src"
  cs_ok config share
  assert_not_contains "$OUT" "Makefile"
}

test_rename_and_remove_messages_are_short() {
  make_primary alice@example.com
  add_seat bob@example.com
  cs_ok rename bob bobby
  assert_eq "Renamed bob to bobby. Its login is unchanged." "$OUT"
  cs remove alice -y
  assert_contains "$ERR" "alice is the primary seat (~/.claude); ccseat never removes it"
}
