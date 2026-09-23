# shellcheck shell=bash
# Repository rules: shellcheck, portability to bash 3.2, safety and style.

# Every shell script in the repository (program, installer, tests, stubs).
scripts() {
  local f
  for f in "$REPO_ROOT/bin/ccseat" "$REPO_ROOT"/lib/ccseat/*.sh "$REPO_ROOT/install.sh" \
    "$REPO_ROOT/tests/run.sh" "$REPO_ROOT/tests/lib.sh" "$REPO_ROOT"/tests/test_*.sh "$REPO_ROOT"/tests/stubs/*; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
}

# Program files only (what users run).
program_files() {
  local f
  for f in "$REPO_ROOT/bin/ccseat" "$REPO_ROOT"/lib/ccseat/*.sh "$REPO_ROOT/install.sh"; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
}

# Text files tracked by the project (everything but .git and .tmp).
text_files() {
  find "$REPO_ROOT" \( -name .git -o -name .tmp \) -prune -o -type f -print \
    | grep -Ev '\.(png|jpg|jpeg|gif|ico|webp|mp4|mov|pdf)$'
}

test_shellcheck_is_clean() {
  local files
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck is not installed"
  files=$(scripts | tr '\n' ' ')
  # shellcheck disable=SC2086  # one argument per file
  run shellcheck $files
  assert_success "shellcheck reports problems"
}

test_scripts_parse_with_this_bash() {
  local f
  while IFS= read -r f; do
    run bash -n "$f"
    [ "$RC" -eq 0 ] || fail "bash -n $f: $ERR"
  done <<EOF
$(scripts)
EOF
}

test_no_bash4_only_features() {
  local hits
  hits=$(program_files | xargs grep -nE \
    'declare -[a-zA-Z]*A|local -[a-zA-Z]*A|typeset -A|mapfile|readarray|\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^|,|\^)\}|\$\{[A-Za-z_][A-Za-z0-9_]*@[QEPAa]\}|&>>|\|&|coproc |wait -n|declare -n|local -n|EPOCHSECONDS|EPOCHREALTIME|read [^#]*-t *[0-9]*\.[0-9]' \
    2>/dev/null | grep -v '^[^:]*:[0-9]*: *#')
  [ -z "$hits" ] || fail "bash 4 only features (macOS ships bash 3.2):"$'\n'"$hits"
}

# bash 3.2 in a UTF-8 locale reads the first byte of a non-ASCII character
# right after a variable name as part of the name, so a dollar sign, a name
# and then a dot symbol fails with "unbound variable". Braces fix it.
test_no_variable_touching_multibyte_text() {
  local hits
  # shellcheck disable=SC2016  # an awk program
  hits=$(scripts | LC_ALL=C xargs awk '/^[ \t]*#/ { next } /\$[A-Za-z_][A-Za-z0-9_]*[\200-\377]/ { print FILENAME ":" FNR ": " $0 }')
  [ -z "$hits" ] || fail "put braces around variables followed by non-ASCII text (bash 3.2 misreads them):"$'\n'"$hits"
}

test_programs_use_env_bash() {
  local f first
  for f in "$REPO_ROOT/bin/ccseat" "$REPO_ROOT/install.sh" "$REPO_ROOT/tests/run.sh"; do
    [ -f "$f" ] || continue
    first=$(head -n 1 "$f")
    assert_eq '#!/usr/bin/env bash' "$first" "shebang of $f"
    [ -x "$f" ] || fail "$f is not executable"
  done
  for f in "$REPO_ROOT"/tests/stubs/*; do
    [ -x "$f" ] || fail "$f is not executable"
  done
}

test_no_em_dashes() {
  local hits
  hits=$(text_files | xargs grep -ln $'\xe2\x80\x94' 2>/dev/null)
  [ -z "$hits" ] || fail "em dashes found in:"$'\n'"$hits"
}

test_no_ai_traces() {
  local hits
  [ ! -e "$REPO_ROOT/.claude" ] || fail "a .claude folder is in the repository"
  hits=$(find "$REPO_ROOT" \( -name .git -o -name .tmp \) -prune -o -name CLAUDE.md -print)
  [ -z "$hits" ] || fail "CLAUDE.md files in the repository: $hits"
  hits=$(text_files | grep -v '/tests/test_hygiene\.sh$' \
    | xargs grep -liE 'generated with|co-authored-by|written by (an )?ai|ai assistant|chatgpt|copilot' 2>/dev/null)
  [ -z "$hits" ] || fail "AI traces found in:"$'\n'"$hits"
}

test_tokens_never_on_a_command_line() {
  local hits
  hits=$(program_files | xargs grep -nE 'Bearer' 2>/dev/null | grep -E '(-H|--header)[ =]' )
  [ -z "$hits" ] || fail "an Authorization header is passed as a curl argument (use -K - on stdin):"$'\n'"$hits"
}

test_system_tools_are_called_by_name() {
  local hits
  # A command position: line start, after ; & | ( $( or a keyword.
  hits=$(program_files | xargs grep -nE \
    '(^[^:]*:[0-9]+:|[;&|(]|\$\(|then|do|else)[[:space:]]*(command |exec |env )?/(usr/)?(local/)?s?bin/(security|curl|trash|osascript|claude)([[:space:]]|$)' \
    2>/dev/null)
  [ -z "$hits" ] || fail "call these tools by name so PATH (and the test stubs) decide:"$'\n'"$hits"
}

test_no_rm_rf_on_user_data() {
  local hits
  hits=$(program_files | grep -v '/install.sh$' | xargs grep -nE 'rm +-[a-zA-Z]*r[a-zA-Z]*f|rm +-[a-zA-Z]*f[a-zA-Z]*r|rm +-r' 2>/dev/null | grep -v '^[^:]*:[0-9]*: *#')
  [ -z "$hits" ] || fail "recursive rm in the program (seat folders go to the Trash):"$'\n'"$hits"
}

test_packaging_files_exist() {
  local f
  for f in LICENSE CHANGELOG.md Makefile install.sh Formula/ccseat.rb .github/workflows/ci.yml .gitignore; do
    assert_file "$REPO_ROOT/$f"
  done
  assert_contains "$(cat "$REPO_ROOT/LICENSE")" "Copyright (c) 2026 Patricio Garza"
  assert_contains "$(cat "$REPO_ROOT/.gitignore")" ".tmp/"
}

test_version_matches_changelog_and_formula() {
  local v
  [ -f "$REPO_ROOT/bin/ccseat" ] || skip "bin/ccseat is not written yet"
  run ccseat --version
  v=$(printf '%s' "$OUT" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
  [ -n "$v" ] || fail "no version printed"
  assert_contains "$(cat "$REPO_ROOT/CHANGELOG.md")" "## [$v]" "CHANGELOG has an entry for $v"
  assert_contains "$(cat "$REPO_ROOT/Formula/ccseat.rb")" "v$v.tar.gz" "the formula points at v$v"
}

# bash 3.2 backs a here-string with a temporary file, so a token must never
# go through one (or through a here-document).
test_tokens_never_go_through_temporary_files() {
  local hits
  hits=$(grep -nE '<<<|<<[A-Za-z_-]' "$REPO_ROOT/lib/ccseat/auth.sh" | grep -v '^[0-9]*: *#')
  [ -z "$hits" ] || fail "here-strings or here-documents in auth.sh, where tokens live:"$'\n'"$hits"
  hits=$(program_files | xargs grep -nE '<<<.*TOKEN' 2>/dev/null)
  [ -z "$hits" ] || fail "a token goes through a here-string:"$'\n'"$hits"
}
