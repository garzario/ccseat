#!/usr/bin/env bash
# ccseat installer: curl -fsSL https://raw.githubusercontent.com/garzario/ccseat/main/install.sh | bash
#
# Downloads ccseat into ${XDG_DATA_HOME:-~/.local/share}/ccseat/app, links
# ~/.local/bin/ccseat and, after asking, adds one marked block to the shell
# startup file so "claude" opens the right seat. From a clone (./install.sh)
# it links the clone instead of downloading. It never uses sudo and never
# installs dependencies: missing ones are listed with the exact command.
# Run with --help for the options.

set -u
# An exported CDPATH would make cd print folders and send it elsewhere.
unset CDPATH

REPO="garzario/ccseat"
MARK_BEGIN="# >>> ccseat >>>"
MARK_END="# <<< ccseat <<<"

assume_yes=0
[ "${CCSEAT_YES:-0}" = 1 ] && assume_yes=1
no_shell=0
want_shell=""
prefix=""
ref="${CCSEAT_REF:-main}"
force_download=0
action=install

# ---------- output ----------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  c_accent=$'\033[38;2;217;119;87m' c_warn=$'\033[38;2;212;162;127m' c_ok=$'\033[38;2;120;140;93m'
  c_dim=$'\033[38;2;176;174;165m' c_bold=$'\033[1m' c_r=$'\033[0m'
else
  c_accent="" c_warn="" c_ok="" c_dim="" c_bold="" c_r=""
fi

say() { printf '%s\n' "$*"; }
step() { printf '%s%s%s\n' "$c_ok" "$*" "$c_r"; }
warn() { printf '%s%s%s\n' "$c_warn" "$*" "$c_r"; }
die() { printf '%serror:%s %s\n' "$c_accent" "$c_r" "$*" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF_USAGE'
Install ccseat, the seat switcher for Claude Code accounts.

Usage:
  curl -fsSL https://raw.githubusercontent.com/garzario/ccseat/main/install.sh | bash
  curl -fsSL https://raw.githubusercontent.com/garzario/ccseat/main/install.sh | bash -s -- [options]
  ./install.sh [options]          from a clone: links the clone

Options:
  -y, --yes        do not ask before editing the shell startup file (or CCSEAT_YES=1)
  --no-shell       do not touch any shell startup file
  --shell NAME     set up zsh, bash or fish instead of the shell in $SHELL
  --prefix DIR     link the command into DIR/bin (default ~/.local)
  --ref REF        branch, tag or commit to download (default main, or CCSEAT_REF)
  --download       download even when run from a clone
  --uninstall      remove the command, the downloaded copy and the shell block;
                   seats and settings stay ("ccseat uninstall --purge" removes them)
  -h, --help       show this help
EOF_USAGE
}

# Shows a path with ~ for the home folder.
tilde() {
  case "$1" in
    "$HOME") printf '~' ;;
    "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# ---------- arguments ----------

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes) assume_yes=1 ;;
    --no-shell) no_shell=1 ;;
    --shell) [ $# -ge 2 ] || die "--shell needs a name (zsh, bash or fish)" 2; want_shell="$2"; shift ;;
    --shell=*) want_shell="${1#--shell=}" ;;
    --prefix) [ $# -ge 2 ] || die "--prefix needs a folder" 2; prefix="$2"; shift ;;
    --prefix=*) prefix="${1#--prefix=}" ;;
    --ref) [ $# -ge 2 ] || die "--ref needs a branch, tag or commit" 2; ref="$2"; shift ;;
    --ref=*) ref="${1#--ref=}" ;;
    --download) force_download=1 ;;
    --uninstall) action=uninstall ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" 2 ;;
  esac
  shift
done

if [ -z "${HOME:-}" ] || [ ! -d "$HOME" ]; then die "HOME is not set to a folder"; fi
case "$ref" in ''|*[!A-Za-z0-9._/-]*|-*) die "not a valid ref: $ref" 2 ;; esac

default_prefix=0
if [ -z "$prefix" ]; then prefix="$HOME/.local"; default_prefix=1; fi
case "$prefix" in /*) ;; *) prefix="$(pwd)/$prefix" ;; esac
while [ "${#prefix}" -gt 1 ] && [ "${prefix%/}" != "$prefix" ]; do prefix="${prefix%/}"; done
bin_dir="$prefix/bin"
link="$bin_dir/ccseat"
if [ "$default_prefix" -eq 1 ]; then
  app_dir="${XDG_DATA_HOME:-$HOME/.local/share}/ccseat/app"
else
  app_dir="$prefix/share/ccseat/app"
fi

os=$(uname -s 2>/dev/null)

# ---------- platform hints ----------

pkg_install_cmd() {
  # Prints the command that installs the given packages, or nothing.
  if [ "$os" = Darwin ]; then
    if command -v brew >/dev/null 2>&1; then printf 'brew install %s' "$*"
    elif command -v port >/dev/null 2>&1; then printf 'sudo port install %s' "$*"
    else printf 'brew install %s   (Homebrew: https://brew.sh)' "$*"; fi
    return
  fi
  if command -v apt-get >/dev/null 2>&1; then printf 'sudo apt-get install -y %s' "$*"
  elif command -v dnf >/dev/null 2>&1; then printf 'sudo dnf install -y %s' "$*"
  elif command -v yum >/dev/null 2>&1; then printf 'sudo yum install -y %s' "$*"
  elif command -v pacman >/dev/null 2>&1; then printf 'sudo pacman -S --needed %s' "$*"
  elif command -v zypper >/dev/null 2>&1; then printf 'sudo zypper install -y %s' "$*"
  elif command -v apk >/dev/null 2>&1; then printf 'sudo apk add %s' "$*"
  elif command -v brew >/dev/null 2>&1; then printf 'brew install %s' "$*"
  fi
}

# Prints missing dependencies with the commands that install them; returns 1
# (and sets deps_ok=0) when something is missing.
deps_ok=1
deps_missing=""
check_deps() {
  local missing="" cmd n
  command -v jq >/dev/null 2>&1 || missing="$missing jq"
  command -v curl >/dev/null 2>&1 || missing="$missing curl"
  missing="${missing# }"
  if [ -n "$missing" ] || ! command -v claude >/dev/null 2>&1; then say ""; fi
  if [ -n "$missing" ]; then
    warn "ccseat needs $(printf '%s' "$missing" | sed 's/ / and /'), which $(if [ "${missing#* }" = "$missing" ]; then echo is; else echo are; fi) not installed."
    cmd=$(pkg_install_cmd "$missing")
    if [ -n "$cmd" ]; then say "  Install with:  $cmd"
    else say "  Install $missing with your package manager."; fi
  fi
  if ! command -v claude >/dev/null 2>&1; then
    warn "Claude Code (the claude command) is not installed or not on your PATH."
    say "  Install with:  curl -fsSL https://claude.ai/install.sh | bash"
    say "  or:            npm install -g @anthropic-ai/claude-code"
    missing="$missing claude"
  fi
  [ -z "$missing" ] && return 0
  deps_ok=0
  # "jq and Claude Code", for the box at the end.
  # shellcheck disable=SC2086 # one word per tool
  set -- $missing
  n=0
  for cmd in "$@"; do
    n=$((n + 1))
    [ "$cmd" = claude ] && cmd="Claude Code"
    if [ "$n" -eq 1 ]; then deps_missing=$cmd
    elif [ "$n" -eq $# ]; then deps_missing="$deps_missing and $cmd"
    else deps_missing="$deps_missing, $cmd"; fi
  done
  return 1
}

# ---------- shell integration ----------

detect_shell() {
  local s="${want_shell:-${SHELL:-}}"
  s="${s##*/}"
  case "$s" in
    zsh|bash|fish) printf '%s' "$s" ;;
    *) printf '' ;;
  esac
}

rc_file_for() {
  case "$1" in
    zsh) printf '%s/.zshrc' "${ZDOTDIR:-$HOME}" ;;
    bash)
      if [ "$os" = Darwin ]; then printf '%s/.bash_profile' "$HOME"
      else printf '%s/.bashrc' "$HOME"; fi ;;
    fish) printf '%s/fish/conf.d/ccseat.fish' "${XDG_CONFIG_HOME:-$HOME/.config}" ;;
  esac
}

on_path() {
  case ":${PATH:-}:" in *":$1:"*) return 0 ;; esac
  return 1
}

# The folder as a shell word that survives a moved home: $HOME/... when it is
# under the home folder.
# shellcheck disable=SC2016  # $HOME is written to the startup file as is
path_word() {
  case "$1" in
    "$HOME"/*) printf '$HOME%s' "${1#"$HOME"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# The lines written to the startup file, between the markers.
# shellcheck disable=SC2016  # $PATH and $(...) are for the startup file, not for now
block_for() {
  local sh="$1" add_path="$2" pw
  pw=$(path_word "$bin_dir")
  printf '%s\n' "$MARK_BEGIN"
  case "$sh" in
    fish)
      if [ "$add_path" -eq 1 ]; then
        printf 'if not contains -- "%s" $PATH\n    set -gx PATH "%s" $PATH\nend\n' "$pw" "$pw"
      fi
      printf 'if type -q ccseat\n    ccseat init fish | source\nend\n' ;;
    *)
      if [ "$add_path" -eq 1 ]; then
        printf 'case ":$PATH:" in\n  *":%s:"*) ;;\n  *) export PATH="%s:$PATH" ;;\nesac\n' "$pw" "$pw"
      fi
      printf 'if command -v ccseat >/dev/null 2>&1; then eval "$(ccseat init %s)"; fi\n' "$sh" ;;
  esac
  printf '%s\n' "$MARK_END"
}

# Copies a startup file into ccseat's backups folder before it is edited.
backup_rc() {
  local f="$1" dir name
  dir="${CCSEAT_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/ccseat}/backups"
  (umask 077 && mkdir -p "$dir") 2>/dev/null || return 1
  name=$(basename "$f")
  cp -p "$f" "$dir/${name#.}.$(date +%Y%m%d-%H%M%S)" 2>/dev/null
}

# Removes our block (and the blank line we put before it) from a file,
# writing in place so a symlinked dotfile stays a symlink. A begin marker
# without its end marker is left alone with everything after it.
strip_block() {
  local f="$1" tmp
  [ -f "$f" ] || return 0
  grep -qF "$MARK_BEGIN" "$f" 2>/dev/null || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/ccseat-rc.XXXXXX") || return 1
  backup_rc "$f"
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    !skip && $0 == b { skip = 1; dropped = held; held = 0; n = 0; buf[++n] = $0; next }
    skip && $0 == e { skip = 0; next }
    skip { buf[++n] = $0; next }
    { if (held) print ""; held = 0 }
    $0 == "" { held = 1; next }
    { print }
    END {
      if (skip) { if (dropped) print ""; for (i = 1; i <= n; i++) print buf[i] }
      else if (held) print ""
    }
  ' "$f" > "$tmp" && cat "$tmp" > "$f"
  rm -f "$tmp"
}

# True when a startup file has a whole ccseat block (both markers).
has_block() {
  [ -f "$1" ] && grep -qxF "$MARK_BEGIN" "$1" 2>/dev/null && grep -qxF "$MARK_END" "$1" 2>/dev/null
}

ask() {
  # ask QUESTION : 0 yes, 1 no, 2 no terminal to ask on.
  local tty="${CCSEAT_INSTALL_TTY:-/dev/tty}" ans=""
  [ "$assume_yes" -eq 1 ] && return 0
  { : < "$tty"; } 2>/dev/null || return 2
  printf '%s [Y/n] ' "$1"
  IFS= read -r ans < "$tty" || ans=""
  case "$ans" in ""|y|Y|yes|Yes|YES) return 0 ;; esac
  return 1
}

setup_shell() {
  local sh rc add_path=0 block current rc_shown
  sh=$(detect_shell)
  if [ -z "$sh" ]; then
    say ""
    warn "Could not tell which shell you use (\$SHELL is ${SHELL:-unset})."
    say "  Add this to your shell startup file:  eval \"\$(ccseat init zsh)\""
    say "  (or init bash; for fish: ccseat init fish | source)"
    return 0
  fi
  rc=$(rc_file_for "$sh")
  rc_shown=$(tilde "$rc")
  on_path "$bin_dir" || add_path=1
  block=$(block_for "$sh" "$add_path")

  if has_block "$rc"; then
    current=$(awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0 == b {on = 1} on {print} $0 == e {on = 0}' "$rc")
    # Keep a PATH line an earlier install needed, even if this shell has it now.
    if [ "$add_path" -eq 0 ] && printf '%s' "$current" | grep -q 'PATH'; then
      block=$(block_for "$sh" 1)
    fi
    if [ "$current" = "$block" ]; then
      step "Shell integration is already in $rc_shown."
      return 0
    fi
  elif [ -f "$rc" ] && grep -Eq 'ccseat[[:space:]]+init' "$rc"; then
    step "Shell integration is already in $rc_shown (added by hand)."
    return 0
  fi

  say ""
  say "ccseat adds a small block to $rc_shown so that \"claude\" opens"
  say "your current seat (and switches when it hits a limit), and \"cs\" is"
  say "short for \"ccseat\":"
  printf '%s%s%s\n' "$c_dim" "$(printf '%s\n' "$block" | sed 's/^/    /')" "$c_r"
  ask "Add it now?"
  case $? in
    0) ;;
    1) say "Skipped. Add it later with: $(setup_word) setup"; return 0 ;;
    *) say "Nothing was changed (no terminal to ask on)."
       say "Add it later with: $(setup_word) setup"; return 0 ;;
  esac

  mkdir -p "$(dirname "$rc")" || die "cannot create $(dirname "$rc")"
  if has_block "$rc"; then strip_block "$rc"; fi
  if [ -s "$rc" ] && [ -n "$(tail -c 1 "$rc")" ]; then printf '\n' >> "$rc"; fi
  if [ -s "$rc" ] && [ -n "$(tail -n 1 "$rc")" ]; then printf '\n' >> "$rc"; fi
  printf '%s\n' "$block" >> "$rc" || die "cannot write $rc_shown"
  step "Added the shell integration to $rc_shown."
  RELOAD_HINT="$sh"
}

# How to run ccseat from the user's next command: by name when it is on
# PATH, else by its full path.
setup_word() {
  if on_path "$bin_dir"; then printf 'ccseat'; else tilde "$link"; fi
}

# ---------- install ----------

# Folder of this script when it runs from a clone, else nothing.
local_source() {
  local src="${BASH_SOURCE[0]:-}" d
  [ -n "$src" ] && [ -f "$src" ] || return 0
  d=$(cd "$(dirname "$src")" 2>/dev/null && pwd -P) || return 0
  [ -f "$d/bin/ccseat" ] && [ -d "$d/lib/ccseat" ] && printf '%s' "$d"
}

tarball_url() {
  if [ -n "${CCSEAT_TARBALL_URL:-}" ]; then printf '%s' "$CCSEAT_TARBALL_URL"; return; fi
  case "$ref" in
    v[0-9]*) printf 'https://github.com/%s/archive/refs/tags/%s.tar.gz' "$REPO" "$ref" ;;
    *)
      if printf '%s' "$ref" | grep -Eq '^[0-9a-f]{40}$'; then
        printf 'https://github.com/%s/archive/%s.tar.gz' "$REPO" "$ref"
      else
        printf 'https://github.com/%s/archive/refs/heads/%s.tar.gz' "$REPO" "$ref"
      fi ;;
  esac
}

# A folder we may replace: it holds our program and nothing that looks like
# user data.
is_our_app() {
  [ -d "$1" ] && [ -f "$1/bin/ccseat" ] && [ -d "$1/lib/ccseat" ]
}

download() {
  local url tmp top stage old
  command -v curl >/dev/null 2>&1 || die "curl is needed to download ccseat. Install with: $(pkg_install_cmd curl)"
  command -v tar >/dev/null 2>&1 || die "tar is needed to unpack ccseat. Install with: $(pkg_install_cmd tar)"
  url=$(tarball_url)
  say "Downloading ccseat ($ref)..."
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/ccseat-install.XXXXXX") || die "cannot create a temporary folder"
  # shellcheck disable=SC2064  # expand now: the folder is fixed
  trap "rm -rf '$tmp'" EXIT
  curl -fsSL --retry 2 -o "$tmp/ccseat.tar.gz" "$url" || die "could not download $url"
  mkdir "$tmp/src" || die "cannot create a temporary folder"
  tar -xzf "$tmp/ccseat.tar.gz" -C "$tmp/src" 2>/dev/null || die "the download is not a valid archive: $url"
  top=$(find "$tmp/src" -mindepth 1 -maxdepth 1 -type d | head -n 1)
  is_our_app "$top" || die "the archive does not contain ccseat: $url"
  mkdir -p "$(dirname "$app_dir")" || die "cannot create $(dirname "$app_dir")"
  stage="$app_dir.new.$$"
  old="$app_dir.old.$$"
  cp -R "$top" "$stage" || die "cannot write $(dirname "$app_dir")"
  chmod +x "$stage/bin/ccseat" 2>/dev/null
  if [ -e "$app_dir" ]; then
    is_our_app "$app_dir" || { rm -rf "$stage"; die "$app_dir exists and is not a ccseat install; move it away and try again"; }
    mv "$app_dir" "$old" || die "cannot replace $app_dir"
  fi
  if ! mv "$stage" "$app_dir"; then
    if [ -e "$old" ]; then mv "$old" "$app_dir"; fi
    die "cannot install into $app_dir"
  fi
  if [ -e "$old" ]; then rm -rf "$old"; fi
  step "Installed ccseat into $(tilde "$app_dir")."
  SOURCE_DIR="$app_dir"
}

link_binary() {
  local target="$1/bin/ccseat" backup
  mkdir -p "$bin_dir" || die "cannot create $bin_dir"
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    backup="$link.backup-$(date +%Y%m%d-%H%M%S)"
    mv "$link" "$backup" || die "cannot move the existing $link out of the way"
    warn "Moved the existing $(tilde "$link") to $(tilde "$backup")."
  fi
  ln -sfn "$target" "$link" || die "cannot link $link"
  step "Linked $(tilde "$link") -> $(tilde "$target")"
}

next_steps() {
  local version="" lines line w=0 n pad title
  version=$("$link" --version 2>/dev/null | head -n 1)
  if [ "$deps_ok" -eq 1 ]; then
    title="${version:-ccseat} is ready."
  else
    title="${version:-ccseat} is installed. Install $deps_missing (above), then:"
  fi
  lines="$title

  ccseat add                   add a seat (logs in to another account)
  ccseat                       pick a seat and open Claude Code
  ccseat statusline install    show the seat and usage under the prompt"
  while IFS= read -r line; do
    n=$(printf '%s' "$line" | wc -m | tr -d ' ')
    [ "$n" -gt "$w" ] && w=$n
  done <<EOF
$lines
EOF
  say ""
  printf '%s╭%s╮%s\n' "$c_dim" "$(printf '%*s' $((w + 2)) '' | sed 's/ /─/g')" "$c_r"
  while IFS= read -r line; do
    n=$(printf '%s' "$line" | wc -m | tr -d ' ')
    pad=$(printf '%*s' $((w - n)) '')
    case "$line" in
      "$title") printf '%s│%s %s%s%s%s %s│%s\n' "$c_dim" "$c_r" "$c_bold" "$line" "$c_r" "$pad" "$c_dim" "$c_r" ;;
      *) printf '%s│%s %s%s %s│%s\n' "$c_dim" "$c_r" "$line" "$pad" "$c_dim" "$c_r" ;;
    esac
  done <<EOF
$lines
EOF
  printf '%s╰%s╯%s\n' "$c_dim" "$(printf '%*s' $((w + 2)) '' | sed 's/ /─/g')" "$c_r"
  if [ -n "${RELOAD_HINT:-}" ]; then
    say "Open a new terminal, or run: exec $RELOAD_HINT"
  elif ! on_path "$bin_dir"; then
    warn "Add $(tilde "$bin_dir") to your PATH, or run $(tilde "$link")"
  fi
}

do_install() {
  local src
  RELOAD_HINT=""
  SOURCE_DIR=""
  src=$(local_source)
  if [ -n "$src" ] && [ "$force_download" -eq 0 ]; then
    say "Installing ccseat from $(tilde "$src")"
    chmod +x "$src/bin/ccseat" 2>/dev/null
    SOURCE_DIR="$src"
  else
    download
  fi
  link_binary "$SOURCE_DIR"
  if ! on_path "$bin_dir"; then
    if [ "$no_shell" -eq 1 ]; then
      warn "$(tilde "$bin_dir") is not on your PATH. Add it to your shell startup file to run ccseat by name."
    else
      warn "$(tilde "$bin_dir") is not on your PATH; the shell integration below adds it."
    fi
  fi
  check_deps || true
  if [ "$no_shell" -eq 0 ]; then setup_shell; fi
  next_steps
}

# ---------- uninstall ----------

# True when ~/.claude/settings.json runs this install's ccseat for its status
# line (Claude Code would fail to run it once the program is gone).
statusline_is_ours() {
  local f="$HOME/.claude/settings.json" cmd
  [ -f "$f" ] && command -v jq >/dev/null 2>&1 || return 1
  cmd=$(jq -r '.statusLine.command // empty' "$f" 2>/dev/null)
  case "$cmd" in
    *"$link"*statusline*|*"$app_dir"*statusline*) return 0 ;;
  esac
  return 1
}

do_uninstall() {
  local rc t removed=0
  # The status line first, while the program can still put back the one
  # the user had before.
  if statusline_is_ours; then
    if [ -x "$link" ]; then "$link" statusline uninstall -q </dev/null >/dev/null 2>&1; fi
    if statusline_is_ours; then
      warn "$(tilde "$HOME/.claude/settings.json") still runs ccseat for its status line."
      say "  Remove its statusLine entry so Claude Code stops running it."
    else
      step "Removed the ccseat status line from $(tilde "$HOME/.claude/settings.json")." && removed=1
    fi
  fi
  if [ -L "$link" ]; then
    t=$(readlink "$link")
    case "$t" in
      */bin/ccseat) rm -f "$link" && step "Removed $(tilde "$link")." && removed=1 ;;
      *) warn "$(tilde "$link") points to $t, which is not ccseat; left alone." ;;
    esac
  elif [ -e "$link" ]; then
    warn "$(tilde "$link") is not a link made by this installer; left alone."
  fi
  if is_our_app "$app_dir"; then
    rm -rf "$app_dir" && step "Removed $(tilde "$app_dir")." && removed=1
    rmdir "$(dirname "$app_dir")" 2>/dev/null
  fi
  for rc in "${ZDOTDIR:-$HOME}/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
    if has_block "$rc"; then
      strip_block "$rc" && step "Removed the shell integration from $(tilde "$rc")." && removed=1
    fi
  done
  rc=$(rc_file_for fish)
  if has_block "$rc"; then
    strip_block "$rc"
    if ! grep -q '[^[:space:]]' "$rc"; then rm -f "$rc"; fi
    step "Removed the shell integration from $(tilde "$rc")." && removed=1
  fi
  [ "$removed" -eq 1 ] || say "ccseat was not installed here; nothing to remove."
  say "Your seats and settings were kept."
  say "To remove them too, reinstall and run: ccseat uninstall --purge"
}

case "$action" in
  install) do_install ;;
  uninstall) do_uninstall ;;
esac
