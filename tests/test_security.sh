# shellcheck shell=bash
# shellcheck disable=SC2016  # shell code for inner shells, written as is
# Security regressions: tokens, curl, the shell integration, safe removals,
# links planted in folders, terminal output and the installer's downloads.

# A curl in front of the stub that keeps the config each call reads on
# stdin (the stub only looks for the token there).
record_curl() {
  cat > "$T/bin/curl" <<EOF
#!/usr/bin/env bash
f=\$(mktemp "$STUB/curl-stdin.XXXXXX") || exit 1
cat > "\$f"
exec "$STUBS_DIR/curl" "\$@" < "\$f"
EOF
  chmod +x "$T/bin/curl"
}

curl_configs() { cat "$STUB"/curl-stdin.* 2>/dev/null; }

bash_rc() { if [ "$(uname -s)" = Darwin ]; then printf '%s/.bash_profile' "$HOME"; else printf '%s/.bashrc' "$HOME"; fi; }

# ---------- tokens ----------

test_usage_curl_skips_curlrc_and_allows_only_https() {
  local now
  now=$(now_epoch)
  record_curl
  make_primary alice@example.com
  usage_fixture alice@example.com 10 $((now + 3600)) 20 $((now + 86400))
  cs_ok usage --refresh
  assert_contains "$(cat "$STUB/curl.tokens")" "$(token_for alice@example.com)" "the usage API was asked"
  assert_match "$(grep 'api/oauth/usage' "$STUB/curl.args" | head -n 1)" '^-q ' \
    "-q comes first, so a ~/.curlrc cannot add options to the request that carries the token"
  assert_contains "$(curl_configs)" 'proto = "=https"' "only https, also after a redirect"
  assert_not_contains "$(cat "$STUB/curl.args")" "tok-" "the token stays off the command line"
}

test_real_curl_never_reads_curlrc() {
  local real
  real=$(PATH="${CCSEAT_TEST_ORIG_PATH:-$PATH}" command -v curl) || skip "curl is not installed"
  unset CURL_HOME XDG_CONFIG_HOME
  make_primary alice@example.com
  cs_ok list
  # A ~/.curlrc that would write every request, headers included, to a file.
  printf 'trace-ascii = "%s"\n' "$T/curl-trace" > "$HOME/.curlrc"
  mkdir -p "$T/realcurl"
  ln -s "$real" "$T/realcurl/curl"
  # The request goes to a closed port on this machine, never to the network.
  PATH="$T/realcurl:$PATH" run bash -c '
    for f in core auth usage; do . "$1/lib/ccseat/$f.sh"; done
    ccseat_init_paths
    ccseat_config_load
    CCSEAT_USAGE_URL="https://127.0.0.1:9/api/oauth/usage"
    ccseat_usage_fetch alice 3
    exit 0' _ "$REPO_ROOT"
  assert_no_path "$T/curl-trace" "curl read ~/.curlrc while it held a token"
}

test_a_token_that_would_rewrite_the_curl_config_is_never_sent() {
  record_curl
  make_primary alice@example.com
  cs_ok list
  jq -n --arg t "$(printf 'x"\nurl = "file:///etc/hosts"\noutput = "%s/ran"\nuser-agent = "' "$T")" \
    '{claudeAiOauth: {accessToken: $t, expiresAt: 9999999999999}}' > "$HOME/.claude/.credentials.json"
  : > "$STUB/curl.args"
  cs usage --refresh
  cs doctor
  assert_not_contains "$(curl_configs)" "file:///etc/hosts" "the token added lines to curl's config"
  assert_not_contains "$(cat "$STUB/curl.args")" "api/oauth/usage" "curl never starts with a token it cannot quote"
  assert_no_path "$T/ran"
  assert_contains "$OUT" "usage API refused the login of alice" "doctor says the login cannot be used"
}

test_tokens_stay_out_of_a_bash_trace() {
  local now
  now=$(now_epoch)
  make_primary alice@example.com
  add_seat bob@example.com
  usage_fixture alice@example.com 10 $((now + 3600)) 20 $((now + 86400))
  run bash -x "$REPO_ROOT/bin/ccseat" doctor
  assert_contains "$(cat "$STUB/curl.tokens")" "$(token_for alice@example.com)" "doctor asked the usage API"
  assert_not_contains "$ERR" "tok-" "a token showed up in a bash -x trace"
  run bash -x "$REPO_ROOT/bin/ccseat" list
  assert_not_contains "$ERR" "tok-" "a token showed up in a bash -x trace"
  assert_contains "$OUT" "alice" "the command still works under bash -x"
}

test_usage_json_never_shows_what_a_cache_link_points_to() {
  make_primary alice@example.com
  cs_ok list
  mkdir -p "$(cache_dir)"
  rm -f "$(cache_dir)/usage-alice.json"
  ln -s "$HOME/.claude/.credentials.json" "$(cache_dir)/usage-alice.json"
  cs usage alice --json
  assert_no_tokens
  assert_json "$OUT" '.name == "alice"' "the seat is still reported"
}

# ---------- shell integration ----------

test_a_seat_name_from_a_hand_edited_list_cannot_run_code() {
  make_primary alice@example.com
  cs_ok list
  printf '%s\t%s\n' '$(touch${IFS}ran)' "$HOME/.claude-x" '../../evil' "$HOME/.claude-y" \
    'ok-name' 'relative/dir' >> "$(seats_file)"
  run_i bash --norc --noprofile -i -c 'eval "$(ccseat init bash)"
COMP_WORDS=(ccseat run ""); COMP_CWORD=2; _ccseat_complete; printf "%s\n" "${COMPREPLY[@]}"'
  assert_no_path "$T/ran" "a seat name ran as a command during tab completion"
  assert_contains "$OUT" "alice"
  cs_ok list
  assert_not_contains "$OUT" "touch" "a name that is not a seat name is skipped"
  assert_not_contains "$OUT" "evil"
  assert_not_contains "$OUT" "ok-name" "a seat folder must be an absolute path"
}

test_the_path_line_quotes_an_odd_install_folder() {
  local pfx rc
  export SHELL=/bin/bash
  pfx="$T/odd\$(touch\${IFS}ran)\`touch\${IFS}ran2\`\"dir"
  mkdir -p "$pfx"
  run bash "$REPO_ROOT/install.sh" --yes --prefix "$pfx" --shell bash
  assert_success "install.sh: $ERR"
  rc=$(bash_rc)
  assert_file "$rc"
  run bash --norc --noprofile -c '. "$1"; printf "%s\n" "$PATH"' _ "$rc"
  assert_success "the startup file still parses: $ERR"
  assert_no_path "$T/ran" "the folder name ran as a command in the startup file"
  assert_no_path "$T/ran2"
  assert_contains "$OUT" "$pfx/bin" "the folder is on PATH exactly as it is spelled"
}

test_setup_quotes_an_odd_program_folder() {
  local d rc
  export SHELL=/bin/bash
  d="$T/odd\$(touch\${IFS}ran)\"dir/bin"
  mkdir -p "$d"
  ln -s "$REPO_ROOT/bin/ccseat" "$d/ccseat"
  # Only this copy of ccseat, so setup writes its folder into the block.
  PATH="$T/bin:$T/stubbin:$(sandbox_base_path)" run "$d/ccseat" setup --yes --no-statusline
  assert_success "setup: $ERR"
  rc=$(bash_rc)
  run bash --norc --noprofile -c '. "$1"; printf "%s\n" "$PATH"' _ "$rc"
  assert_success "the startup file still parses: $ERR"
  assert_no_path "$T/ran" "the folder name ran as a command in the startup file"
  assert_contains "$OUT" "$d" "the folder is on PATH exactly as it is spelled"
}

test_fish_init_quotes_an_odd_program_folder() {
  local d
  command -v fish >/dev/null 2>&1 || skip "fish is not installed"
  # A space, a backslash and a quote in the folder of the program.
  d="$T/odd dir\\'x/bin"
  mkdir -p "$d"
  ln -s "$REPO_ROOT/bin/ccseat" "$d/ccseat"
  PATH="$T/bin:$T/stubbin:$(sandbox_base_path)" run "$d/ccseat" init fish
  assert_success
  printf '%s\n' "$OUT" > "$T/init.fish"
  run fish -n "$T/init.fish"
  assert_success "fish -n accepts the output: $ERR"
  PATH="$T/bin:$T/stubbin:$(sandbox_base_path)" run fish --no-config -i -c "source '$T/init.fish'; complete -C 'ccseat '"
  assert_contains "$OUT" "list" "completions still work from a folder with spaces and quotes"
}

# ---------- removals ----------

test_uninstall_leaves_a_shared_prefix_alone() {
  local pfx="$HOME/.local" bob
  make_primary alice@example.com
  add_seat bob@example.com
  bob=$(seat_dir bob)
  # ccseat copied by hand into a prefix that other programs use too.
  mkdir -p "$pfx/bin" "$pfx/lib"
  cp "$REPO_ROOT/bin/ccseat" "$pfx/bin/ccseat"
  cp -R "$REPO_ROOT/lib/ccseat" "$pfx/lib/ccseat"
  printf '#!/bin/sh\n' > "$pfx/bin/other-tool"
  run "$pfx/bin/ccseat" uninstall -y
  assert_success "uninstall: $ERR"
  assert_dir "$bob" "a seat under ~/.local/share went with the program"
  assert_file "$pfx/bin/other-tool" "another program in the same prefix went with ccseat"
  assert_no_path "$pfx/bin/ccseat" "the program itself leaves"
  assert_no_path "$pfx/lib/ccseat"
  assert_file "$(seats_file)"
}

test_uninstall_still_removes_a_folder_of_its_own() {
  mkdir -p "$T/ccseat-0.1.0"
  cp -R "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$REPO_ROOT/LICENSE" "$T/ccseat-0.1.0/"
  run "$T/ccseat-0.1.0/bin/ccseat" uninstall -y
  assert_success "uninstall: $ERR"
  assert_no_path "$T/ccseat-0.1.0" "an unpacked copy of ccseat is ccseat's own folder"
  in_trash ccseat-0.1.0 || fail "the unpacked copy went to the Trash"
}

test_purge_leaves_a_shared_ccseat_home_alone() {
  program_copy
  export CCSEAT_HOME="$HOME/.config"
  mkdir -p "$HOME/.config/otherapp"
  printf 'keep me\n' > "$HOME/.config/otherapp/settings"
  make_primary alice@example.com
  add_seat bob@example.com
  run ccseat uninstall --purge -y
  assert_success "uninstall --purge: $ERR"
  assert_file "$HOME/.config/otherapp/settings" "another program's settings went to the Trash"
  assert_contains "$OUT$ERR" "/.config in place" "says what it left in place"
}

test_the_trash_is_private_on_linux() {
  [ "$(uname -s)" = Darwin ] && skip "macOS keeps its own ~/.Trash"
  make_primary alice@example.com
  add_seat bob@example.com
  cs_ok remove bob -y
  assert_mode "$HOME/.local/share/Trash" 700
}

test_new_shared_files_in_the_primary_are_private() {
  mkdir -p "$HOME/.claude"
  write_credentials "$HOME/.claude" alice@example.com
  set_email "$HOME/.claude.json" alice@example.com
  add_seat bob@example.com
  assert_mode "$HOME/.claude/history.jsonl" 600
  assert_mode "$HOME/.claude/settings.json" 600
  assert_mode "$HOME/.claude/projects" 700
}

# ---------- links planted in folders ----------

test_adopting_never_writes_through_a_planted_backup_link() {
  local s now
  make_primary alice@example.com
  login_seat_dir "$HOME/.claude-work" bob@example.com
  printf '{"model":"from the adopted folder"}\n' > "$HOME/.claude-work/settings.json"
  mkdir -p "$HOME/.claude-work/.ccseat-backup" "$T/elsewhere"
  now=$(now_epoch)
  for s in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19; do
    ln -s "$HOME/.claude" "$HOME/.claude-work/.ccseat-backup/$(epoch_fmt $((now + s)) '%Y%m%d-%H%M%S')"
  done
  cs add --dir "$HOME/.claude-work"
  assert_contains "$(cat "$HOME/.claude/settings.json")" '"model": "opus"' \
    "the primary settings.json was replaced through a link in the adopted folder"
  rm -rf "$HOME/.claude-work/.ccseat-backup"
  ln -s "$T/elsewhere" "$HOME/.claude-work/.ccseat-backup"
  cs sync bob
  assert_eq "" "$(ls -A "$T/elsewhere")" "a backup went through a linked .ccseat-backup folder"
}

# ---------- terminal output ----------

test_statusline_strips_terminal_control_characters() {
  local d
  make_primary alice@example.com
  d="$HOME/work/a"$'\033]0;wintitle\a'"b"
  mkdir -p "$d"
  export NO_COLOR=1
  run_in "$(jq -nc --arg d "$d" '{model: {display_name: "Opus\u001b[2J"}, workspace: {current_dir: $d},
    context_window: {used_percentage: 5}}')" ccseat statusline
  assert_success
  no_ansi "$OUT" "a folder or model name put escape codes on the terminal"
  assert_not_contains "$OUT" $'\a'
  assert_contains "$OUT" "wintitle"
}

test_progress_strips_terminal_control_characters() {
  make_workflow_fixture sess-1 wf_abc ship
  printf '{"type":"started","key":"evil","agentId":"a3","label":"x\\u001b]0;wintitle\\u0007y","phase":"Build"}\n' >> "$WF_RUN_DIR/journal.jsonl"
  printf '{"agentType":"gen\\u001b]0;PWNED\\u0007\\u001b[2Jeral"}\n' > "$WF_RUN_DIR/agent-a3.meta.json"
  printf '{"type":"assistant"}\n' > "$WF_RUN_DIR/agent-a3.jsonl"
  run ccseat progress --agents sess-1
  assert_success
  no_ansi "$OUT" "an agent label or type put escape codes on the terminal"
  assert_not_contains "$OUT" $'\a'
  assert_contains "$OUT" "wintitle"
  run ccseat progress sess-1
  no_ansi "$OUT"
}

test_an_email_with_escape_codes_is_printed_plain() {
  make_primary alice@example.com
  set_email "$HOME/.claude.json" $'alice\033]0;wintitle\a@example.com'
  cs_ok usage
  no_ansi "$OUT" "an email put escape codes on the terminal"
  assert_not_contains "$OUT" $'\a'
}

# ---------- installer downloads ----------

# A stand-in for GitHub under $T/gh, served through the curl stub's file://
# support: releases/latest answers like GitHub (a redirect to the tag) and
# the tag's archive holds this repository. Sets GH to its base URL.
fake_github() {
  local tag="$1" base="$T/gh/garzario/ccseat" top="ccseat-${1#v}"
  mkdir -p "$base/releases/download/$tag" "$base/archive/refs/tags" "$T/gh-src/$top"
  printf 'HTTP/2 302\r\nlocation: https://github.com/garzario/ccseat/releases/tag/%s\r\ncontent-length: 0\r\n\r\n' \
    "$tag" > "$base/releases/latest"
  cp -R "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$REPO_ROOT/install.sh" "$REPO_ROOT/LICENSE" "$T/gh-src/$top/"
  tar -czf "$base/archive/refs/tags/$tag.tar.gz" -C "$T/gh-src" "$top"
  GH="file://$T/gh"
}

sha_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else sha256sum "$1" | cut -d' ' -f1; fi
}

# publish_sums TAG [SHA256] : a SHA256SUMS file for the tag's archive.
publish_sums() {
  local tag="$1" base="$T/gh/garzario/ccseat" sum
  sum=${2:-$(sha_file "$base/archive/refs/tags/$tag.tar.gz")}
  printf '%s  ccseat-%s.tar.gz\n' "$sum" "${tag#v}" > "$base/releases/download/$tag/SHA256SUMS"
}

# The installer piped into bash, as the one-line install runs it.
piped_install() {
  run_in "$(cat "$REPO_ROOT/install.sh")" env CCSEAT_GITHUB_URL="$GH" "$@" bash -s -- --yes --no-shell
}

test_installer_downloads_the_latest_release_by_default() {
  fake_github v9.8.7
  publish_sums v9.8.7
  piped_install
  assert_success "piped install of the latest release: $ERR"
  assert_contains "$OUT" "Downloading ccseat (v9.8.7)"
  assert_contains "$OUT" "Checked the download against the checksum published with v9.8.7."
  assert_contains "$(cat "$STUB/curl.args")" "$GH/garzario/ccseat/archive/refs/tags/v9.8.7.tar.gz"
  assert_not_contains "$(cat "$STUB/curl.args")" "refs/heads/main" "main is not the default"
  assert_file "$HOME/.local/share/ccseat/app/bin/ccseat"
  run "$HOME/.local/bin/ccseat" version
  assert_success
}

test_installer_stops_when_the_checksum_differs() {
  fake_github v9.8.7
  publish_sums v9.8.7 0000000000000000000000000000000000000000000000000000000000000000
  piped_install
  assert_failure "a checksum mismatch stops the install"
  assert_contains "$ERR" "does not match the checksum published with v9.8.7"
  assert_no_path "$HOME/.local/share/ccseat/app" "nothing was installed"
  assert_no_path "$HOME/.local/bin/ccseat"
  CCSEAT_GITHUB_URL="$GH" run bash "$REPO_ROOT/install.sh" --download --yes --no-shell --ref v9.8.7
  assert_failure "an explicit release tag is checked too"
  assert_contains "$ERR" "does not match the checksum published with v9.8.7"
  assert_no_path "$HOME/.local/bin/ccseat"
}

test_installer_without_published_checksums_says_so() {
  fake_github v9.8.7
  piped_install
  assert_success "$ERR"
  assert_contains "$OUT" "No checksum is published for v9.8.7"
  assert_file "$HOME/.local/share/ccseat/app/bin/ccseat"
}

test_installer_stops_when_the_checksums_cannot_be_read() {
  fake_github v9.8.7
  publish_sums v9.8.7
  printf '500\n' > "$T/gh/garzario/ccseat/releases/download/v9.8.7/SHA256SUMS.status"
  piped_install
  assert_failure "a server error on the checksum file must not skip the check"
  assert_contains "$ERR" "could not download the checksums published with v9.8.7"
  assert_no_path "$HOME/.local/share/ccseat/app" "nothing was installed"
  assert_no_path "$HOME/.local/bin/ccseat"
}

test_installer_still_installs_a_branch_on_request() {
  fake_github v9.8.7
  mkdir -p "$T/gh/garzario/ccseat/archive/refs/heads"
  cp "$T/gh/garzario/ccseat/archive/refs/tags/v9.8.7.tar.gz" "$T/gh/garzario/ccseat/archive/refs/heads/main.tar.gz"
  piped_install CCSEAT_REF=main
  assert_success "$ERR"
  assert_contains "$(cat "$STUB/curl.args")" "archive/refs/heads/main.tar.gz"
  assert_not_contains "$(cat "$STUB/curl.args")" "releases/latest" "no release lookup for a branch"
  assert_not_contains "$OUT" "checksum" "branches have no published checksum"
}

test_installer_refuses_a_ref_that_leaves_the_repository() {
  local ref
  for ref in ../../../../../evil/repo/archive/refs/heads/main main/../../x /main 'a//b' .hidden; do
    run bash "$REPO_ROOT/install.sh" --download --no-shell --ref "$ref"
    assert_exit 2 "--ref $ref"
  done
  assert_no_path "$STUB/curl.args" "nothing was downloaded"
}

test_installer_curl_skips_curlrc_and_allows_only_https() {
  local n
  record_curl
  fake_github v9.8.7
  publish_sums v9.8.7
  piped_install
  assert_success "$ERR"
  n=$(grep -c . "$STUB/curl.args")
  [ "$n" -ge 3 ] || fail "expected the release lookup, the archive and the checksum ($n calls)"
  assert_eq "$n" "$(grep -c '^-q ' "$STUB/curl.args")" "every download starts with -q"
  assert_eq "$n" "$(curl_configs | grep -c '^proto = "=https"$')" "every download allows https only"
}

test_installer_cleans_up_with_a_quote_in_tmpdir() {
  mkdir -p "$T/it's tmp"
  fake_github v9.8.7
  piped_install TMPDIR="$T/it's tmp"
  assert_success "$ERR"
  assert_eq "" "$(ls -A "$T/it's tmp")" "the temporary folder was left behind"
}

test_installer_never_deletes_a_clone_in_its_app_folder() {
  local app="$HOME/.local/share/ccseat/app"
  mkdir -p "$app/.git"
  cp -R "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$app/"
  printf 'my work\n' > "$app/notes.txt"
  run bash "$REPO_ROOT/install.sh" --uninstall
  assert_success
  assert_file "$app/notes.txt" "a git clone in the app folder was deleted"
}

test_installer_ignores_a_relative_xdg_data_home() {
  fake_github v9.8.7
  piped_install XDG_DATA_HOME=data
  assert_success "$ERR"
  assert_file "$HOME/.local/share/ccseat/app/bin/ccseat"
  assert_no_path "$T/data" "installed relative to the current folder"
}
