# shellcheck shell=bash
# shellcheck disable=SC2016  # startup file lines are compared literally
# install.sh (from a clone and from a tarball), make install, and
# "ccseat uninstall".

install_sh() { run bash "$REPO_ROOT/install.sh" "$@"; }

marker_count() { grep -c '^# >>> ccseat >>>$' "$1" 2>/dev/null || true; }

need_program() {
  [ -f "$REPO_ROOT/bin/ccseat" ] || skip "bin/ccseat is not written yet"
}

# A git clone of ccseat in the sandbox, for tests that run "ccseat
# uninstall": it must never reach the program under test, and a checkout
# without a .git folder (a worktree, an unpacked release) would otherwise be
# moved to the Trash.
fake_clone() {
  mkdir -p "$T/clone/.git"
  cp -R "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$REPO_ROOT/install.sh" "$T/clone/" || fail "cannot copy the program"
}

# A tarball shaped like GitHub's archive of the repository.
make_tarball() {
  mkdir -p "$T/src/ccseat-main"
  cp -R "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$REPO_ROOT/install.sh" "$REPO_ROOT/LICENSE" "$T/src/ccseat-main/"
  tar -czf "$T/ccseat.tar.gz" -C "$T/src" ccseat-main
  printf 'file://%s' "$T/ccseat.tar.gz"
}

test_install_from_clone_zsh() {
  need_program
  export SHELL=/bin/zsh
  install_sh --yes
  assert_success "install.sh --yes"
  assert_symlink "$HOME/.local/bin/ccseat" "$REPO_ROOT/bin/ccseat"
  assert_file "$HOME/.zshrc"
  assert_eq 1 "$(marker_count "$HOME/.zshrc")" "one block"
  assert_contains "$(cat "$HOME/.zshrc")" 'eval "$(ccseat init zsh)"'
  assert_contains "$(cat "$HOME/.zshrc")" '$HOME/.local/bin' "PATH is added when missing"
  assert_contains "$OUT" "not on your PATH" "warns about PATH"
  assert_contains "$OUT" "ccseat add"
  assert_contains "$OUT" "ccseat statusline install"
  assert_no_path "$HOME/.local/share/ccseat/app" "a clone is linked, not copied"
  run "$HOME/.local/bin/ccseat" version
  assert_success "the linked command runs"
}

test_install_is_idempotent() {
  local before
  need_program
  export SHELL=/bin/zsh
  printf 'export EDITOR=vim\n' > "$HOME/.zshrc"
  install_sh --yes
  before=$(cat "$HOME/.zshrc")
  install_sh --yes
  assert_success
  assert_eq 1 "$(marker_count "$HOME/.zshrc")" "still one block"
  assert_eq "$before" "$(cat "$HOME/.zshrc")" "second run changes nothing"
  assert_contains "$OUT" "already"
  assert_eq "export EDITOR=vim" "$(head -n 1 "$HOME/.zshrc")" "existing lines kept"
}

test_install_block_passes_syntax_checks() {
  need_program
  export SHELL=/bin/bash
  install_sh --yes
  run bash -n "$(if [ "$(uname -s)" = Darwin ]; then echo "$HOME/.bash_profile"; else echo "$HOME/.bashrc"; fi)"
  assert_success "bash -n"
  if command -v zsh >/dev/null 2>&1; then
    install_sh --yes --shell zsh
    run zsh -n "$HOME/.zshrc"
    assert_success "zsh -n"
    run_i zsh -f -i -c "source '$HOME/.zshrc'; whence -w claude; ccseat version"
    assert_contains "$OUT" "function" "the zsh block defines the claude wrapper"
  fi
}

test_install_skips_path_line_when_on_path() {
  need_program
  export SHELL=/bin/zsh
  export PATH="$HOME/.local/bin:$PATH"
  install_sh --yes
  assert_success
  assert_not_contains "$(cat "$HOME/.zshrc")" "PATH" "no PATH line when the folder is already on PATH"
  assert_not_contains "$OUT" "not on your PATH"
}

test_install_bash_rc_file() {
  local rc
  need_program
  export SHELL=/bin/bash
  install_sh --yes
  assert_success
  if [ "$(uname -s)" = Darwin ]; then rc="$HOME/.bash_profile"; else rc="$HOME/.bashrc"; fi
  assert_eq 1 "$(marker_count "$rc")"
  assert_contains "$(cat "$rc")" 'eval "$(ccseat init bash)"'
}

test_install_fish_conf_d() {
  local f
  need_program
  export SHELL=/usr/bin/fish
  install_sh --yes
  assert_success
  f="$HOME/.config/fish/conf.d/ccseat.fish"
  assert_file "$f"
  assert_contains "$(cat "$f")" "ccseat init fish | source"
  if command -v fish >/dev/null 2>&1; then
    run fish -n "$f"
    assert_success "fish -n"
  fi
}

test_install_respects_zdotdir() {
  need_program
  export SHELL=/bin/zsh ZDOTDIR="$HOME/.config/zsh"
  install_sh --yes
  assert_success
  assert_eq 1 "$(marker_count "$ZDOTDIR/.zshrc")"
  assert_no_path "$HOME/.zshrc"
}

test_install_no_shell() {
  need_program
  export SHELL=/bin/zsh
  install_sh --no-shell
  assert_success
  assert_symlink "$HOME/.local/bin/ccseat"
  assert_no_path "$HOME/.zshrc" "--no-shell leaves startup files alone"
}

test_install_asks_on_the_terminal() {
  need_program
  export SHELL=/bin/zsh
  printf 'n\n' > "$T/answer"
  CCSEAT_INSTALL_TTY="$T/answer" run bash "$REPO_ROOT/install.sh"
  assert_success
  assert_contains "$OUT" "[Y/n]"
  assert_no_path "$HOME/.zshrc" "answering n changes nothing"
  printf '\n' > "$T/answer"
  CCSEAT_INSTALL_TTY="$T/answer" run bash "$REPO_ROOT/install.sh"
  assert_eq 1 "$(marker_count "$HOME/.zshrc")" "enter means yes"
}

test_install_without_a_terminal_does_not_edit() {
  need_program
  export SHELL=/bin/zsh
  CCSEAT_INSTALL_TTY="$T/no-such-tty" run bash "$REPO_ROOT/install.sh"
  assert_success
  assert_no_path "$HOME/.zshrc"
  assert_contains "$OUT" "ccseat setup" "says how to add it later"
  CCSEAT_YES=1 CCSEAT_INSTALL_TTY="$T/no-such-tty" run bash "$REPO_ROOT/install.sh"
  assert_eq 1 "$(marker_count "$HOME/.zshrc")" "CCSEAT_YES=1 works like --yes"
}

test_install_keeps_a_symlinked_rc_file() {
  need_program
  export SHELL=/bin/zsh
  mkdir -p "$HOME/dotfiles"
  printf 'alias ll="ls -l"\n' > "$HOME/dotfiles/zshrc"
  ln -s "$HOME/dotfiles/zshrc" "$HOME/.zshrc"
  install_sh --yes
  assert_symlink "$HOME/.zshrc" "$HOME/dotfiles/zshrc"
  assert_eq 1 "$(marker_count "$HOME/dotfiles/zshrc")"
  install_sh --uninstall
  assert_symlink "$HOME/.zshrc" "$HOME/dotfiles/zshrc"
  assert_eq 'alias ll="ls -l"' "$(cat "$HOME/dotfiles/zshrc")" "uninstall restores the file"
}

test_install_moves_an_existing_file_aside() {
  need_program
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\necho old\n' > "$HOME/.local/bin/ccseat"
  install_sh --yes --no-shell
  assert_success
  assert_symlink "$HOME/.local/bin/ccseat"
  exists_glob "$HOME/.local/bin"/ccseat.backup-* || fail "the old file is kept as a backup"
}

test_install_prefix() {
  need_program
  install_sh --yes --no-shell --prefix "$T/opt"
  assert_success
  assert_symlink "$T/opt/bin/ccseat" "$REPO_ROOT/bin/ccseat"
  assert_no_path "$HOME/.local/bin/ccseat"
}

test_install_reports_missing_dependencies() {
  need_program
  PATH="$(path_without jq claude)" run bash "$REPO_ROOT/install.sh" --yes --no-shell
  assert_success "installing still works; dependencies are reported"
  assert_contains "$OUT" "jq"
  assert_match "$OUT" '(brew|apt-get|dnf|yum|pacman|zypper|apk|port) (install|-S|add)' "exact install command for jq"
  assert_contains "$OUT" "https://claude.ai/install.sh" "how to install Claude Code"
}

test_install_help_and_bad_options() {
  install_sh --help
  assert_success
  assert_contains "$OUT" "--uninstall"
  assert_contains "$OUT" "--no-shell"
  install_sh --bogus
  assert_exit 2
  install_sh --ref 'bad ref'
  assert_exit 2
}

test_install_from_a_tarball() {
  local url
  need_program
  export SHELL=/bin/zsh
  url=$(make_tarball)
  run_in "$(cat "$REPO_ROOT/install.sh")" env CCSEAT_TARBALL_URL="$url" bash -s -- --yes
  assert_success "piped install from a tarball"
  assert_file "$HOME/.local/share/ccseat/app/bin/ccseat"
  assert_symlink "$HOME/.local/bin/ccseat" "$HOME/.local/share/ccseat/app/bin/ccseat"
  run "$HOME/.local/bin/ccseat" version
  assert_success
  # An update replaces the copy cleanly.
  run_in "$(cat "$REPO_ROOT/install.sh")" env CCSEAT_TARBALL_URL="$url" bash -s -- --yes
  assert_success
  assert_eq "app" "$(ls "$HOME/.local/share/ccseat")" "no leftovers next to the app"
  assert_eq 1 "$(marker_count "$HOME/.zshrc")"
}

test_install_tarball_urls() {
  install_sh --download --no-shell
  assert_failure "no network in tests"
  assert_contains "$(cat "$STUB/curl.args")" "https://github.com/garzario/ccseat/releases/latest" "the latest release by default"
  install_sh --download --no-shell --ref main
  assert_contains "$(cat "$STUB/curl.args")" "https://github.com/garzario/ccseat/archive/refs/heads/main.tar.gz"
  install_sh --download --no-shell --ref v0.1.0
  assert_contains "$(cat "$STUB/curl.args")" "https://github.com/garzario/ccseat/archive/refs/tags/v0.1.0.tar.gz"
  CCSEAT_REF=dev run bash "$REPO_ROOT/install.sh" --download --no-shell
  assert_contains "$(cat "$STUB/curl.args")" "archive/refs/heads/dev.tar.gz"
  install_sh --download --no-shell --ref 0123456789abcdef0123456789abcdef01234567
  assert_contains "$(cat "$STUB/curl.args")" "archive/0123456789abcdef0123456789abcdef01234567.tar.gz"
  assert_no_path "$HOME/.local/bin/ccseat" "a failed download installs nothing"
}

test_install_uninstall() {
  need_program
  export SHELL=/bin/zsh
  printf 'export EDITOR=vim\n' > "$HOME/.zshrc"
  install_sh --yes
  make_primary alice@example.com
  run "$HOME/.local/bin/ccseat" list
  install_sh --uninstall
  assert_success
  assert_no_path "$HOME/.local/bin/ccseat"
  assert_eq "export EDITOR=vim" "$(cat "$HOME/.zshrc")" "the block and its blank line are gone"
  assert_file "$(seats_file)" "seats are kept"
  assert_file "$REPO_ROOT/bin/ccseat" "the clone is never removed"
  install_sh --uninstall
  assert_success "uninstalling twice is fine"
}

test_install_uninstall_downloaded_copy() {
  local url
  need_program
  url=$(make_tarball)
  CCSEAT_TARBALL_URL="$url" run bash "$REPO_ROOT/install.sh" --download --yes --no-shell
  assert_success
  assert_dir "$HOME/.local/share/ccseat/app"
  install_sh --uninstall
  assert_no_path "$HOME/.local/share/ccseat/app"
  assert_no_path "$HOME/.local/bin/ccseat"
}

# ---------- make install ----------

test_make_install_and_uninstall() {
  need_program
  command -v make >/dev/null 2>&1 || skip "make is not installed"
  run make -C "$REPO_ROOT" install PREFIX="$T/prefix"
  assert_success "make install: $ERR"
  assert_file "$T/prefix/share/ccseat/bin/ccseat"
  assert_file "$T/prefix/share/ccseat/lib/ccseat/core.sh"
  run "$T/prefix/bin/ccseat" version
  assert_success "the installed command runs from its link"
  assert_match "$OUT" '[0-9]+\.[0-9]+\.[0-9]+'
  run make -C "$REPO_ROOT" uninstall PREFIX="$T/prefix"
  assert_success
  assert_no_path "$T/prefix/bin/ccseat"
  assert_no_path "$T/prefix/share/ccseat"
}

test_make_install_destdir() {
  need_program
  command -v make >/dev/null 2>&1 || skip "make is not installed"
  run make -C "$REPO_ROOT" install PREFIX=/usr/local DESTDIR="$T/stage"
  assert_success
  assert_file "$T/stage/usr/local/share/ccseat/bin/ccseat"
  assert_eq "/usr/local/share/ccseat/bin/ccseat" "$(readlink "$T/stage/usr/local/bin/ccseat")" "the link points at the final location"
}

# ---------- ccseat uninstall ----------

test_ccseat_uninstall_keeps_seats() {
  need_program
  export SHELL=/bin/zsh
  printf 'export EDITOR=vim\n' > "$HOME/.zshrc"
  fake_clone
  run bash "$T/clone/install.sh" --yes
  make_primary alice@example.com
  add_seat bob@example.com
  run "$HOME/.local/bin/ccseat" uninstall -y
  assert_success "ccseat uninstall: $ERR"
  assert_no_path "$HOME/.local/bin/ccseat"
  assert_eq 0 "$(marker_count "$HOME/.zshrc")" "the shell block is gone"
  assert_contains "$(cat "$HOME/.zshrc")" "export EDITOR=vim"
  assert_dir "$(seat_dir bob)" "seats are kept without --purge"
  assert_file "$(seats_file)"
  assert_file "$T/clone/bin/ccseat" "the clone is never removed"
}

test_ccseat_uninstall_purge() {
  local bob
  need_program
  export SHELL=/bin/zsh
  fake_clone
  run bash "$T/clone/install.sh" --yes
  make_primary alice@example.com
  add_seat bob@example.com
  bob=$(seat_dir bob)
  run "$HOME/.local/bin/ccseat" uninstall --purge -y
  assert_success "ccseat uninstall --purge: $ERR"
  assert_no_path "$bob" "seat folders leave with --purge"
  assert_no_path "$(ccseat_home)" "the ccseat config leaves with --purge"
  in_trash "$(basename "$bob")" || fail "purged seat folders go to the Trash"
  assert_file "$HOME/.claude/.credentials.json" "the primary ~/.claude is never removed"
  assert_file "$HOME/.claude/settings.json"
}

test_ccseat_uninstall_leaves_a_worktree_in_place() {
  need_program
  export SHELL=/bin/zsh
  fake_clone
  # In a git worktree or a submodule, .git is a file.
  rmdir "$T/clone/.git"
  printf 'gitdir: %s/main/.git/worktrees/clone\n' "$T" > "$T/clone/.git"
  run bash "$T/clone/install.sh" --yes
  assert_success "install.sh from a worktree: $ERR"
  run "$HOME/.local/bin/ccseat" uninstall -y
  assert_success "ccseat uninstall: $ERR"
  assert_contains "$OUT" "Left the source folder"
  assert_file "$T/clone/bin/ccseat" "a worktree is never moved to the Trash"
  assert_file "$T/clone/lib/ccseat/core.sh"
  assert_no_path "$HOME/.local/bin/ccseat"
}

test_setup_and_installer_share_one_block() {
  need_program
  export SHELL=/bin/zsh
  printf 'export EDITOR=vim\n' > "$HOME/.zshrc"
  cs_ok setup --yes --no-statusline
  assert_eq 1 "$(marker_count "$HOME/.zshrc")" "ccseat setup adds one block"
  install_sh --yes
  assert_success
  assert_eq 1 "$(marker_count "$HOME/.zshrc")" "the installer reuses the block from ccseat setup"
  cs_ok setup --yes --no-statusline
  assert_eq 1 "$(marker_count "$HOME/.zshrc")" "ccseat setup reuses the installer's block"
  install_sh --uninstall
  assert_eq "export EDITOR=vim" "$(cat "$HOME/.zshrc")"
}

test_install_keeps_lines_after_a_lone_marker() {
  need_program
  export SHELL=/bin/zsh
  printf 'export EDITOR=vim\n# >>> ccseat >>>\neval "$(ccseat init zsh)"\nalias gs="git status"\nsource ~/.work-secrets.zsh\n' > "$HOME/.zshrc"
  CCSEAT_YES=1 run bash "$REPO_ROOT/install.sh" --shell zsh
  assert_success
  assert_contains "$(cat "$HOME/.zshrc")" 'alias gs="git status"'
  assert_contains "$(cat "$HOME/.zshrc")" 'source ~/.work-secrets.zsh'
  bash "$REPO_ROOT/install.sh" --uninstall >/dev/null 2>&1
  assert_contains "$(cat "$HOME/.zshrc")" 'alias gs="git status"'
  assert_contains "$(cat "$HOME/.zshrc")" 'source ~/.work-secrets.zsh'
}

test_install_uninstall_puts_the_status_line_back() {
  need_program
  make_primary alice@example.com
  jq '.statusLine = {type: "command", command: "bash ~/old-line.sh"}' "$HOME/.claude/settings.json" > "$T/s" \
    && mv "$T/s" "$HOME/.claude/settings.json"
  install_sh --yes --no-shell
  assert_success
  PATH="$HOME/.local/bin:$PATH" run ccseat statusline install
  assert_success
  assert_json "$(cat "$HOME/.claude/settings.json")" '.statusLine.command | test("statusline")'
  install_sh --uninstall
  assert_success
  assert_json "$(cat "$HOME/.claude/settings.json")" '.statusLine.command == "bash ~/old-line.sh"' \
    "the previous status line is back, so Claude Code never runs a removed program"
}

test_install_says_it_is_not_ready_without_dependencies() {
  need_program
  PATH="$(path_without jq claude)" run bash "$REPO_ROOT/install.sh" --yes --no-shell
  assert_success
  assert_not_contains "$OUT" "is ready." "the box does not claim ccseat works without jq"
  assert_contains "$OUT" "is installed"
}

test_install_output_fits_80_columns() {
  local w
  need_program
  export SHELL=/bin/zsh
  CCSEAT_INSTALL_TTY="$T/no-such-tty" run bash "$REPO_ROOT/install.sh"
  # Lines that show the checkout's own path grow with it, so they are not
  # measured.
  w=$(widest_line "$(printf '%s\n' "$OUT" | grep -vF "$REPO_ROOT")")
  [ "$w" -le 80 ] || fail "an installer line is $w characters wide"
  [ "$(printf '%s\n' "$OUT" | awk 'prev == "" && $0 == "" { n++ } { prev = $0 } END { print n + 0 }')" -eq 0 ] \
    || fail "the installer prints two blank lines in a row"
}
