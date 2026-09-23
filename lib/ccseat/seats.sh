# shellcheck shell=bash
# shellcheck disable=SC2016 # jq programs use $ for their own variables
# ccseat seats: first run, add, remove, rename, list, use, current, run,
# sync, the shared links and the "claude" wrapper.

# Items that can hold a seat's own additions worth keeping when a folder with
# real content is adopted: their new entries are copied into the primary.
CCSEAT_MERGEABLE="skills agents commands rules hooks output-styles projects file-history plans todos"

# ---------- first run ----------

# With no seats registered, the user's existing login (~/.claude) becomes the
# primary seat. Prints a one-time notice on stderr unless $1=quiet.
ccseat_first_run() {
  local mode="${1:-}" e n first others
  ccseat__registry_ensure
  [ "$CCSEAT_N" -gt 0 ] && return 0
  command -v jq >/dev/null 2>&1 || return 1
  ccseat_auth_check "$CCSEAT_PRIMARY_DIR"
  [ "$CCSEAT_AUTH" = none ] && return 1
  e=$(ccseat_email "$CCSEAT_PRIMARY_DIR" 2>/dev/null) || e=$(ccseat_email_live "$CCSEAT_PRIMARY_DIR" 2>/dev/null) || e=""
  if [ -n "$e" ]; then n=$(ccseat_name_from_email "$e"); else n=main; fi
  n=$(ccseat_unique_name "$n")
  ccseat_registry_add "$n" "$CCSEAT_PRIMARY_DIR" || return 1
  n=$CCSEAT_REG_NAME
  [ -f "$CCSEAT_CURRENT_FILE" ] || ccseat_current_set "$n"
  [ "$mode" = quiet ] && return 0
  if [ -n "$e" ]; then
    first="your Claude Code login ($e) is now a seat"
    [ "$n" = "$(ccseat_name_from_email "$e")" ] || first="$first, $n"
  else
    first="your Claude Code login is now the seat $n"
  fi
  others=$(ccseat_find_other_dirs 2>/dev/null)
  if [ -z "$others" ]; then
    ccseat_note "$first" "Add another account with: ccseat add"
    return 0
  fi
  ccseat_note "$first"
  ccseat__other_dirs_hint "$others" "$CCSEAT__E_DIM" "$CCSEAT__E_R" >&2
  CCSEAT__OTHERS_SHOWN=1
  return 0
}

# "Found 2 more logins..." with one "ccseat add --dir" line per folder.
# $2 and $3 are the color and reset codes to use.
ccseat__other_dirs_hint() {
  local others="$1" c="${2:-}" r="${3:-}" count d
  count=$(printf '%s\n' "$others" | grep -c .)
  if [ "$count" -eq 1 ]; then
    printf '  %sFound 1 more login. Add it without signing in again:%s\n' "$c" "$r"
  else
    printf '  %sFound %s more logins. Add them without signing in again:%s\n' "$c" "$count" "$r"
  fi
  printf '%s\n' "$others" | while IFS= read -r d; do
    [ -n "$d" ] && printf '    %sccseat add --dir %s%s\n' "$c" "$(ccseat_tilde "$d")" "$r"
  done
  return 0
}

# What to say when there are no seats at all.
ccseat_no_seats_hint() {
  local others
  printf 'No seats yet.\n'
  if [ -d "$CCSEAT_PRIMARY_DIR" ]; then
    printf '  Your Claude Code folder (~/.claude) is not logged in yet.\n'
    printf '  Add your first account with: ccseat add\n'
  else
    printf '  Add your first account with: ccseat add\n'
  fi
  others=$(ccseat_find_other_dirs)
  if [ -n "$others" ]; then
    printf '\n  Other Claude Code folders on this computer can become seats too:\n'
    printf '%s\n' "$others" | while IFS= read -r d; do
      [ -n "$d" ] && printf '    ccseat add --dir %s\n' "$(ccseat_tilde "$d")"
    done
  fi
}

# Config folders like ~/.claude-work that are logged in but not registered.
ccseat_find_other_dirs() {
  local d
  ccseat__registry_ensure
  for d in "$CCSEAT_USER_HOME"/.claude-* "$CCSEAT_USER_HOME"/.claude_*; do
    if ! [ -d "$d" ] || [ -L "$d" ]; then continue; fi
    ccseat__index_of_dir "$d" >/dev/null && continue
    [ -f "$d/.claude.json" ] || [ -f "$d/.config.json" ] || [ -f "$d/.credentials.json" ] || continue
    ccseat_auth_check "$d"
    [ "$CCSEAT_AUTH" = none ] && continue
    printf '%s\n' "$d"
  done
}

# ---------- shared links ----------

ccseat__is_file_item() {
  case "$1" in
    *.json|*.jsonl|*.md|*.sh|*.txt|*.toml|*.yaml|*.yml|*.py|*.js) return 0 ;;
  esac
  return 1
}

# Creates a missing shared target in the primary, so every link is valid.
ccseat__ensure_target() {
  local item="$1" t="$CCSEAT_PRIMARY_DIR/$1"
  [ -e "$t" ] && return 0
  [ -L "$t" ] && return 1
  mkdir -p "$CCSEAT_PRIMARY_DIR" 2>/dev/null || return 1
  if ccseat__is_file_item "$item"; then
    if [ "$item" = settings.json ]; then printf '{}\n' > "$t"; else : > "$t"; fi
  else
    mkdir -p "$t"
  fi
}

# Copies entries of src that dst lacks, recursing into folders both have.
# Never overwrites. Adds the number of copied entries to CCSEAT__MERGED.
ccseat__merge_into() {
  local src="$1" dst="$2" entry b
  for entry in "$src"/* "$src"/.[!.]* "$src"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    b=${entry##*/}
    if ! [ -e "$dst/$b" ] && ! [ -L "$dst/$b" ]; then
      cp -Rp "$entry" "$dst/$b" 2>/dev/null && CCSEAT__MERGED=$((CCSEAT__MERGED + 1))
    elif [ -d "$entry" ] && ! [ -L "$entry" ] && [ -d "$dst/$b" ] && ! [ -L "$dst/$b" ]; then
      ccseat__merge_into "$entry" "$dst/$b"
    fi
  done
}

ccseat__is_empty_dir() {
  local entry
  for entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] && return 1
  done
  return 0
}

ccseat__has_content() {
  if [ -L "$1" ]; then return 1; fi
  if [ -f "$1" ]; then [ -s "$1" ]; return; fi
  [ -d "$1" ] && ! ccseat__is_empty_dir "$1"
}

# A seat has its own file or folder where a shared link goes. Empty or
# identical ones are dropped; anything else is kept in the seat's
# .ccseat-backup folder (folders' new entries are also copied into the
# primary, so conversations and skills stay available).
ccseat__retire_item() {
  local dir="$1" item="$2" p="$1/$2" t="$CCSEAT_PRIMARY_DIR/$2" dest
  # The primary's own file or folder, reached another way (a linked parent
  # folder, a hard link): never delete or move it.
  if [ -e "$t" ] && [ "$p" -ef "$t" ]; then return 1; fi
  if [ -d "$p" ] && ccseat__is_empty_dir "$p"; then
    rmdir "$p" 2>/dev/null && return 0
  fi
  if [ -f "$p" ]; then
    if ! [ -s "$p" ] || cmp -s "$p" "$t"; then
      rm -f "$p" && return 0
    fi
  fi
  if [ -d "$p" ]; then
    case " $CCSEAT_MERGEABLE " in
      *" $item "*)
        CCSEAT__MERGED=0
        ccseat__merge_into "$p" "$t"
        [ "$CCSEAT__MERGED" -gt 0 ] && CCSEAT__NOTE_COPIED="$CCSEAT__NOTE_COPIED $item:$CCSEAT__MERGED" ;;
    esac
  fi
  [ -n "${CCSEAT__BACKUP_STAMP:-}" ] || CCSEAT__BACKUP_STAMP=$(LC_ALL=C date +%Y%m%d-%H%M%S)
  dest="$dir/.ccseat-backup/$CCSEAT__BACKUP_STAMP"
  mkdir -p "$dest" 2>/dev/null || return 1
  mv "$p" "$dest/$item" || return 1
  CCSEAT__NOTE_KEPT="$CCSEAT__NOTE_KEPT $item"
  CCSEAT__NOTE_BACKUP=$dest
  return 0
}

# Links every shared item of a seat into the primary. Items that already
# point there are left alone; a link the user pointed elsewhere is kept.
# When the primary lacks an item the seat really has, the seat's copy moves
# into the primary and becomes the shared one.
# Sets CCSEAT_LINK_NOTES, CCSEAT_LINK_OK, CCSEAT_LINK_CUSTOM, CCSEAT_LINK_NEW.
ccseat_links_ensure() {
  local dir="$1" item target link items
  CCSEAT_LINK_NOTES="" CCSEAT_LINK_OK=0 CCSEAT_LINK_CUSTOM="" CCSEAT_LINK_NEW=""
  CCSEAT__NOTE_KEPT="" CCSEAT__NOTE_MOVED="" CCSEAT__NOTE_COPIED="" CCSEAT__NOTE_BACKUP=""
  # ~/.claude itself, even through a symlink, never gets links.
  ccseat_is_primary_place "$dir" && return 0
  [ -d "$dir" ] || return 1
  items=$(ccseat_share_items)
  for item in $items; do
    ccseat_never_shared "$item" && continue
    target="$CCSEAT_PRIMARY_DIR/$item"
    link="$dir/$item"
    if [ -e "$link" ] && [ -e "$target" ] && [ "$link" -ef "$target" ]; then
      CCSEAT_LINK_OK=$((CCSEAT_LINK_OK + 1))
      continue
    fi
    if ! [ -e "$target" ] && ! [ -L "$target" ] && ccseat__has_content "$link"; then
      if mkdir -p "$CCSEAT_PRIMARY_DIR" 2>/dev/null && mv "$link" "$target" 2>/dev/null; then
        CCSEAT__NOTE_MOVED="$CCSEAT__NOTE_MOVED $item"
      fi
    fi
    ccseat__ensure_target "$item" || continue
    if [ -L "$link" ]; then
      if [ -e "$link" ]; then
        CCSEAT_LINK_CUSTOM="$CCSEAT_LINK_CUSTOM $item"
        continue
      fi
      rm -f "$link" 2>/dev/null
    elif [ -e "$link" ]; then
      ccseat__retire_item "$dir" "$item" || continue
    fi
    if ln -s "$target" "$link" 2>/dev/null; then
      CCSEAT_LINK_OK=$((CCSEAT_LINK_OK + 1))
      CCSEAT_LINK_NEW="$CCSEAT_LINK_NEW $item"
    fi
  done
  ccseat__link_notes
  return 0
}

# Nouns for "Copied 3 skills and 1 project that ~/.claude did not have."
ccseat__entry_noun() {
  local one many
  case "$1" in
    skills) one=skill many=skills ;;
    agents) one=agent many=agents ;;
    commands) one=command many=commands ;;
    rules) one=rule many=rules ;;
    hooks) one=hook many=hooks ;;
    output-styles) one="output style" many="output styles" ;;
    projects) one=project many=projects ;;
    plans) one=plan many=plans ;;
    todos) one="todo list" many="todo lists" ;;
    file-history) one="file history entry" many="file history entries" ;;
    *) one="entry of $1" many="entries of $1" ;;
  esac
  if [ "$2" = 1 ]; then printf '1 %s' "$one"; else printf '%s %s' "$2" "$many"; fi
}

# "a", "a and b", "a, b and c".
ccseat__join_and() {
  local out="" n=$# i=0 w
  for w in "$@"; do
    i=$((i + 1))
    if [ "$i" -eq 1 ]; then out=$w
    elif [ "$i" -eq "$n" ]; then out="$out and $w"
    else out="$out, $w"; fi
  done
  printf '%s' "$out"
}

# Word-wraps text to a width, one output line per row.
ccseat__wrap() {
  local width="$1" text="$2" line="" w
  set -f
  # shellcheck disable=SC2086 # split into words, never globbed
  set -- $text
  set +f
  for w in "$@"; do
    if [ -z "$line" ]; then line=$w
    elif [ $(( ${#line} + 1 + ${#w} )) -le "$width" ]; then line="$line $w"
    else printf '%s\n' "$line"; line=$w; fi
  done
  [ -n "$line" ] && printf '%s\n' "$line"
  return 0
}

# Turns what ccseat_links_ensure did to a seat's own files into a few short
# sentences in CCSEAT_LINK_NOTES (one line each, already wrapped).
ccseat__link_notes() {
  local s="" words="" entry item n
  if [ -n "$CCSEAT__NOTE_KEPT" ]; then
    # shellcheck disable=SC2086 # one word per item
    s="It now shares $(ccseat__join_and $CCSEAT__NOTE_KEPT) with ~/.claude."
    s="$s Its own copies were moved to $(ccseat_tilde "$CCSEAT__NOTE_BACKUP")"
  fi
  if [ -n "$CCSEAT__NOTE_MOVED" ]; then
    # shellcheck disable=SC2086 # one word per item
    s="$s${s:+$CCSEAT_NL}Moved its $(ccseat__join_and $CCSEAT__NOTE_MOVED) to ~/.claude, which had none, so every seat shares it now."
  fi
  if [ -n "$CCSEAT__NOTE_COPIED" ]; then
    set --
    for entry in $CCSEAT__NOTE_COPIED; do
      item=${entry%%:*}
      n=${entry##*:}
      set -- "$@" "$(ccseat__entry_noun "$item" "$n")"
    done
    s="$s${s:+$CCSEAT_NL}Copied $(ccseat__join_and "$@") that ~/.claude did not have."
  fi
  [ -n "$s" ] || return 0
  while IFS= read -r words; do
    [ -n "$words" ] || continue
    CCSEAT_LINK_NOTES="$CCSEAT_LINK_NOTES$CCSEAT_NL$(ccseat__wrap 76 "$words")"
  done <<EOF
$s
EOF
  return 0
}

# Per-seat state kept by ccseat: which MCP servers and links it added.
ccseat__state_file() { printf '%s/.ccseat.json' "$1"; }

ccseat__state_get() {
  local f
  f=$(ccseat__state_file "$1")
  [ -f "$f" ] || return 0
  jq -r --arg k "$2" '(.[$k] // []) | map(tostring) | join(" ")' "$f" 2>/dev/null
}

ccseat__state_set() {
  local dir="$1" key="$2" f cur out
  shift 2
  f=$(ccseat__state_file "$dir")
  cur='{}'
  [ -f "$f" ] && cur=$(cat "$f" 2>/dev/null)
  out=$(printf '%s' "$cur" | jq --arg k "$key" --arg v "$*" \
    '(if type == "object" then . else {} end) | .[$k] = ($v | split(" ") | map(select(. != "")) | unique)' 2>/dev/null) \
    || out=$(jq -n --arg k "$key" --arg v "$*" '{} | .[$k] = ($v | split(" ") | map(select(. != "")) | unique)')
  printf '%s\n' "$out" | ccseat_write_file "$f"
}

# Removes links ccseat made for items that are no longer shared.
ccseat__links_prune() {
  local dir="$1" item prev keep="" share
  ccseat_is_primary_place "$dir" && return 0
  share=" $(ccseat_share_items) "
  prev=$(ccseat__state_get "$dir" links)
  for item in $prev; do
    case "$share" in
      *" $item "*) keep="$keep $item" ;;
      *)
        if [ -L "$dir/$item" ] && [ "$dir/$item" -ef "$CCSEAT_PRIMARY_DIR/$item" ]; then
          rm -f "$dir/$item" && CCSEAT_LINK_NOTES="$CCSEAT_LINK_NOTES${CCSEAT_NL}Stopped sharing $item."
        fi ;;
    esac
  done
  for item in $CCSEAT_LINK_NEW; do keep="$keep $item"; done
  # shellcheck disable=SC2086 # one word per item
  ccseat__state_set "$dir" links $keep
}

# ---------- MCP servers, trusted folders and onboarding ----------

CCSEAT_JQ_SYNC='
(($src[0] // {}) | if type == "object" then . else {} end) as $s
| ((($st[0] // {}) | if type == "object" then .mcp else null end) // []) as $prev
| . as $orig
| (if (($s.mcpServers // null) | type) == "object" then
     $s.mcpServers as $sm
     | .mcpServers = ((((.mcpServers // {}) | if type == "object" then . else {} end)
         | with_entries(select(.key as $k | ($sm | has($k))
             or (($prev | map(select(. == $k)) | length) == 0))))
         + $sm)
   elif ($prev | length) > 0 and ((.mcpServers | type) == "object") then
     .mcpServers |= with_entries(select(.key as $k | ($prev | map(select(. == $k)) | length) == 0))
   else . end)
| reduce (($s.projects // {}) | if type == "object" then to_entries[] else empty end
          | select((.value | type) == "object" and .value.hasTrustDialogAccepted == true) | .key) as $k
    (.; .projects[$k].hasTrustDialogAccepted = true)
| .hasCompletedOnboarding = true
| (if .theme == null and $s.theme != null then .theme = $s.theme else . end)
| (if .lastOnboardingVersion == null and $s.lastOnboardingVersion != null
   then .lastOnboardingVersion = $s.lastOnboardingVersion else . end)
| if . == $orig then "SAME" else . end'

# Copies MCP servers, trusted folders and the onboarding flag from the
# primary into a seat's global config. Servers the seat added itself stay;
# servers ccseat copied earlier and the primary dropped are removed.
# Sets CCSEAT_SYNC_MCP and CCSEAT_SYNC_TRUST (counts) and CCSEAT_SYNC_NOTE.
ccseat_sync_json() {
  local dir="$1" verbose="${2:-0}" src target state out srcfile=/dev/null stfile=/dev/null names info lock
  CCSEAT_SYNC_MCP=0 CCSEAT_SYNC_TRUST=0 CCSEAT_SYNC_NOTE=""
  ccseat_is_primary_place "$dir" && return 0
  command -v jq >/dev/null 2>&1 || { CCSEAT_SYNC_NOTE="jq is missing"; return 1; }
  [ -d "$dir" ] || return 1
  src=$(ccseat_global_config "$CCSEAT_PRIMARY_DIR")
  target=$(ccseat_global_config "$dir")
  state=$(ccseat__state_file "$dir")
  if [ -L "$target" ]; then
    CCSEAT_SYNC_NOTE="$(ccseat_tilde "$target") is a symlink, left alone"
    return 1
  fi
  [ -f "$src" ] && srcfile=$src
  [ -f "$state" ] && stfile=$state
  if ! [ -f "$target" ]; then
    printf '{}\n' | ccseat_write_file "$target" || return 1
  fi
  # Claude Code is writing this file right now: try again next time.
  lock="$target.lock"
  if [ -d "$lock" ] && [ "$(ccseat_file_age "$lock")" -lt 10 ]; then
    CCSEAT_SYNC_NOTE="busy"
    return 0
  fi
  if ! out=$(jq --slurpfile src "$srcfile" --slurpfile st "$stfile" "$CCSEAT_JQ_SYNC" "$target" 2>/dev/null); then
    # A damaged primary config or state file: sync what can be synced.
    srcfile=/dev/null stfile=/dev/null
    if ! out=$(jq --slurpfile src /dev/null --slurpfile st /dev/null "$CCSEAT_JQ_SYNC" "$target" 2>/dev/null); then
      CCSEAT_SYNC_NOTE="$(ccseat_tilde "$target") is not valid JSON, left alone"
      return 1
    fi
    CCSEAT_SYNC_NOTE="could not read $(ccseat_tilde "$src"), so only the onboarding flag was copied"
  fi
  if [ -n "$out" ] && [ "$out" != '"SAME"' ]; then
    printf '%s\n' "$out" | ccseat_write_file "$target" || return 1
  fi
  if [ "$srcfile" != /dev/null ] && { [ "$out" != '"SAME"' ] || [ "$stfile" = /dev/null ]; }; then
    names=$(jq -r '(.mcpServers // {}) | if type == "object" then keys | join(" ") else "" end' "$srcfile" 2>/dev/null)
    # shellcheck disable=SC2086 # server names are one word each
    ccseat__state_set "$dir" mcp $names
  fi
  if [ "$verbose" = 1 ] && [ "$srcfile" != /dev/null ]; then
    info=$(jq -r '[((.mcpServers // {}) | if type == "object" then length else 0 end),
      ([(.projects // {}) | if type == "object" then to_entries[] else empty end
        | select((.value | type) == "object" and .value.hasTrustDialogAccepted == true)] | length)]
      | map(tostring) | join(" ")' "$srcfile" 2>/dev/null)
    read -r CCSEAT_SYNC_MCP CCSEAT_SYNC_TRUST <<< "$info"
  fi
  return 0
}

# Everything a seat needs before Claude Code opens with it. Silent.
ccseat_prepare_seat() {
  local dir="$1"
  ccseat_is_primary_place "$dir" && return 0
  [ -d "$dir" ] || return 1
  ccseat_links_ensure "$dir" >/dev/null 2>&1
  ccseat_sync_json "$dir" >/dev/null 2>&1
  return 0
}

# ---------- add ----------

ccseat__add_discard() {
  local dir="$1"
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  if ccseat__is_empty_dir "$dir"; then
    rmdir "$dir" 2>/dev/null
  else
    ccseat_trash "$dir" >/dev/null 2>&1
  fi
}

ccseat__add_abort() {
  trap - INT TERM
  ccseat__add_discard "${CCSEAT__ADD_DIR:-}"
  printf '\n' >&2
  ccseat_err "cancelled, nothing was added"
  exit 130
}

# Refuses folders that must never become a seat, and folders with content
# that does not look like a Claude Code config folder (links would land in
# them). Places are compared with symlinks resolved, so a link to the home
# folder or into ~/.claude is refused like the folder itself.
ccseat__check_adopt_dir() {
  local d="$1" f x own="Use a folder of its own, for example: ccseat add --dir ~/.claude-work"
  ccseat_is_primary_dir "$d" && return 0
  case "$d" in
    /|"$CCSEAT_USER_HOME"|"$CCSEAT_HOME"|"$CCSEAT_DATA_DIR"|"$CCSEAT_SEATS_DIR"|"$CCSEAT_CACHE_DIR")
      ccseat_die "$(ccseat_tilde "$d") cannot be a seat folder" "$own" ;;
  esac
  if ccseat_path_within "$CCSEAT_USER_HOME" "$d"; then
    ccseat_die "$(ccseat_tilde "$d") holds your home folder, so it cannot be a seat folder" "$own"
  fi
  if ccseat_path_within "$CCSEAT_PRIMARY_DIR" "$d"; then
    ccseat_die "$(ccseat_tilde "$d") holds ~/.claude, so it cannot be a seat folder" "$own"
  fi
  if ccseat_path_within "$d" "$CCSEAT_PRIMARY_DIR"; then
    ccseat_die "$(ccseat_tilde "$d") is inside ~/.claude, so it cannot be a seat folder" "$own"
  fi
  for x in "$CCSEAT_HOME" "$CCSEAT_DATA_DIR" "$CCSEAT_SEATS_DIR" "$CCSEAT_CACHE_DIR"; do
    ccseat_path_within "$x" "$d" && ccseat_die "$(ccseat_tilde "$d") holds ccseat's own files, so it cannot be a seat folder" "$own"
  done
  # Inside ccseat's own folders only a seat folder (for example one kept by
  # "ccseat remove --keep-files") can come back.
  if ccseat_path_within "$d" "$CCSEAT_HOME" || ccseat_path_within "$d" "$CCSEAT_CACHE_DIR" \
    || { ccseat_path_within "$d" "$CCSEAT_DATA_DIR" && ! ccseat_path_within "$d" "$CCSEAT_SEATS_DIR"; }; then
    ccseat_die "$(ccseat_tilde "$d") is one of ccseat's own folders, so it cannot be a seat folder" "$own"
  fi
  [ -d "$d" ] || return 0
  ccseat__is_empty_dir "$d" && return 0
  for f in .claude.json .config.json .credentials.json settings.json projects sessions statsig CLAUDE.md shell-snapshots; do
    [ -e "$d/$f" ] && return 0
  done
  ccseat_auth_check "$d"
  [ "$CCSEAT_AUTH" != none ] && return 0
  ccseat_die "$(ccseat_tilde "$d") does not look like a Claude Code config folder" \
    "Pass the folder you use as CLAUDE_CONFIG_DIR, an empty folder, or leave --dir out for a new one."
}

ccseat_cmd_add() {
  local email="" name="" dir_arg="" dir created=0 e n i other lower shown need_login=0 signed=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --email) [ $# -ge 2 ] || ccseat_die_usage "--email needs an address" add; email=$2; shift ;;
      --email=*) email=${1#--email=} ;;
      --name) [ $# -ge 2 ] || ccseat_die_usage "--name needs a name" add; name=$2; shift ;;
      --name=*) name=${1#--name=} ;;
      --dir) [ $# -ge 2 ] || ccseat_die_usage "--dir needs a folder" add; dir_arg=$2; shift ;;
      --dir=*) dir_arg=${1#--dir=} ;;
      -h|--help) ccseat_help add; return 0 ;;
      -*) ccseat_die_usage "unknown option for add: $1" add ;;
      *@*) [ -z "$email" ] || ccseat_die_usage "add takes one email" add; email=$1 ;;
      *) [ -z "$name" ] || ccseat_die_usage "add takes one name" add; name=$1 ;;
    esac
    shift
  done
  ccseat_need_jq
  ccseat_need_claude
  ccseat__registry_ensure

  if [ -n "$name" ]; then
    name=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
    ccseat_valid_name "$name" || ccseat_die_usage "$(ccseat_name_problem "$name")" add
    if ccseat__index_of_name "$name" >/dev/null; then
      ccseat_die "there is already a seat called $name" "Pick another name with --name, or rename it: ccseat rename $name <new>"
    fi
  fi

  if [ -n "$dir_arg" ]; then
    dir=$(ccseat_abspath "$dir_arg") || ccseat_die "cannot use the folder $dir_arg"
    shown=$(ccseat_tilde "$dir")
    # ~/.claude reached through a symlink is ~/.claude: it becomes the
    # primary seat, never a seat with links into itself.
    if ! ccseat_is_primary_dir "$dir" && ccseat_is_primary_place "$dir"; then
      dir=$CCSEAT_PRIMARY_DIR
      shown="$shown (a link to ~/.claude)"
    fi
    if other=$(ccseat_seat_for_dir "$dir"); then
      ccseat_die "$shown is already the seat $other" "Open it with: ccseat run $other"
    fi
    if [ -d "$dir" ]; then
      i=0
      while [ "$i" -lt "$CCSEAT_N" ]; do
        if [ -d "${CCSEAT_DIRS[i]}" ] && [ "$dir" -ef "${CCSEAT_DIRS[i]}" ]; then
          ccseat_die "$shown is the folder of the seat ${CCSEAT_NAMES[i]}" "Open it with: ccseat run ${CCSEAT_NAMES[i]}"
        fi
        i=$((i + 1))
      done
    fi
    if [ -e "$dir" ] && ! [ -d "$dir" ]; then
      ccseat_die "$shown is not a folder"
    fi
    ccseat__check_adopt_dir "$dir"
    if ! [ -d "$dir" ]; then
      ccseat_mkdir_private "$dir" || ccseat_die "cannot create $shown"
      created=1
    fi
  elif [ "$CCSEAT_N" -eq 0 ] && ! ccseat_is_logged_in "$CCSEAT_PRIMARY_DIR"; then
    # The first account signs in to ~/.claude itself, so plain claude (and
    # editors that start it directly) use it too.
    dir=$CCSEAT_PRIMARY_DIR
    if ! [ -d "$dir" ]; then
      ccseat_mkdir_private "$dir" || ccseat_die "cannot create ~/.claude"
      created=1
    fi
  else
    if [ -n "$name" ]; then n=$name
    elif [ -n "$email" ]; then n=$(ccseat_name_from_email "$email")
    else n=seat; fi
    if ! ccseat_mkdir_private "$CCSEAT_DATA_DIR" || ! ccseat_mkdir_private "$CCSEAT_SEATS_DIR"; then
      ccseat_die "cannot create $(ccseat_tilde "$CCSEAT_SEATS_DIR")"
    fi
    dir="$CCSEAT_SEATS_DIR/$n"
    i=2
    while [ -e "$dir" ] || [ -L "$dir" ]; do
      dir="$CCSEAT_SEATS_DIR/$n-$i"
      i=$((i + 1))
    done
    ccseat_mkdir_private "$dir" || ccseat_die "cannot create $(ccseat_tilde "$dir")"
    chmod 700 "$dir" 2>/dev/null
    created=1
  fi

  ccseat_auth_check "$dir"
  [ "$CCSEAT_AUTH" = none ] && need_login=1
  # A folder ccseat just made can still have a login in the Keychain left by
  # an earlier seat at the same path, so it always signs in fresh.
  [ "$created" = 1 ] && need_login=1
  if [ "$need_login" = 1 ]; then
    if [ "$created" = 1 ]; then
      CCSEAT__ADD_DIR=$dir
      trap ccseat__add_abort INT TERM
    fi
    printf 'Signing in to Claude Code for the new seat%s.\n' "${email:+ ($email)}"
    if [ "$CCSEAT_N" -gt 0 ]; then
      printf 'Your browser opens. If it is signed in to a Claude account you already\n'
      printf 'added, switch accounts there first, or open the link Claude Code prints\n'
      printf 'in a private window.\n'
    else
      printf 'Your browser opens; sign in with the account you want to use.\n'
    fi
    printf '\n'
    if ! ccseat_login "$dir" "$email"; then
      trap - INT TERM
      [ "$created" = 1 ] && ccseat__add_discard "$dir"
      ccseat_die "the login did not finish, so nothing was added" "Try again with: ccseat add"
    fi
    trap - INT TERM
    ccseat_auth_check "$dir"
    if [ "$CCSEAT_AUTH" = none ]; then
      [ "$created" = 1 ] && ccseat__add_discard "$dir"
      ccseat_die "Claude Code did not save a login, so nothing was added" "Try again with: ccseat add"
    fi
    signed=1
    printf '\n'
  fi

  e=$(ccseat_email "$dir" 2>/dev/null) || e=$(ccseat_email_live "$dir" 2>/dev/null) || e=""
  if [ -n "$e" ]; then
    lower=$(printf '%s' "$e" | tr '[:upper:]' '[:lower:]')
    i=0
    while [ "$i" -lt "$CCSEAT_N" ]; do
      other=$(ccseat_email "${CCSEAT_DIRS[i]}" 2>/dev/null | tr '[:upper:]' '[:lower:]')
      if [ -n "$other" ] && [ "$other" = "$lower" ] && [ "${CCSEAT_DIRS[i]}" != "$dir" ]; then
        # Undo this command's login, so the folder is left as it was.
        if [ "$signed" = 1 ] && ! ccseat_is_primary_place "$dir"; then
          ccseat_claude_in "$dir" auth logout </dev/null >/dev/null 2>&1
        fi
        [ "$created" = 1 ] && ccseat__add_discard "$dir"
        if [ "$signed" = 1 ]; then
          ccseat_err "the browser signed in as $e," \
            "which is already the seat ${CCSEAT_NAMES[i]}. Nothing was added." \
            "Sign out of claude.ai in the browser (or use a private window)," \
            "then run: ccseat add"
        else
          ccseat_err "$(ccseat_tilde "$dir") is signed in as $e," \
            "which is already the seat ${CCSEAT_NAMES[i]}. Nothing was added:" \
            "two seats with one account would share one usage limit."
        fi
        exit 1
      fi
      i=$((i + 1))
    done
  fi

  if [ -z "$name" ]; then
    if [ -n "$e" ]; then n=$(ccseat_name_from_email "$e")
    elif ccseat_is_primary_dir "$dir"; then n=main
    else n=$(ccseat_name_from_email "$(basename "$dir" | sed 's/^\.claude[-_]*//; s/^\.//')"); fi
    name=$(ccseat_unique_name "$n")
  fi

  ccseat_registry_add "$name" "$dir" || ccseat_die "could not save the seat list in $(ccseat_tilde "$CCSEAT_HOME")"
  name=$CCSEAT_REG_NAME
  ccseat_links_ensure "$dir"
  ccseat__links_prune "$dir"
  ccseat_sync_json "$dir"
  [ -f "$CCSEAT_CURRENT_FILE" ] || ccseat_current_set "$(ccseat_current_get)"

  ccseat_colors_init 1
  if [ -n "$e" ]; then
    printf 'Added %s (%s).\n' "$name" "$e"
  else
    printf 'Added %s.\n' "$name"
  fi
  if [ -n "$CCSEAT_LINK_NOTES" ]; then
    printf '%s\n' "${CCSEAT_LINK_NOTES#"$CCSEAT_NL"}" | while IFS= read -r n; do
      printf '  %s%s%s\n' "$CCSEAT_C_MID" "$n" "$CCSEAT_C_RESET"
    done
  fi
  # The picker opens the new seat right away, so it needs no hint.
  [ "${CCSEAT__ADD_OPENS:-0}" = 1 ] && return 0
  printf 'Open it with: ccseat run %s\n' "$name"
  if [ -z "${CCSEAT_SHELL:-}" ] && [ -t 1 ]; then
    printf '%sTip: run ccseat setup once so the claude command switches seats for you.%s\n' "$CCSEAT_C_FAINT" "$CCSEAT_C_RESET"
  fi
  return 0
}

# ---------- remove ----------

ccseat_cmd_remove() {
  local ref="" keep=0 yes=0 name dir cur q rc email who shared=0 existed=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --keep-files|-k) keep=1 ;;
      -y|--yes) yes=1 ;;
      -h|--help) ccseat_help remove; return 0 ;;
      -*) ccseat_die_usage "unknown option for remove: $1" remove ;;
      *) [ -z "$ref" ] || ccseat_die_usage "remove takes one seat" remove; ref=$1 ;;
    esac
    shift
  done
  [ -n "$ref" ] || ccseat_die_usage "which seat? Usage: ccseat remove <seat>" remove
  # Without jq a login looks absent, and the seat would not be signed out.
  ccseat_need_jq
  ccseat_resolve_seat "$ref" || exit 1
  name=$CCSEAT_R_NAME
  dir=$CCSEAT_R_DIR
  if ccseat_is_primary_dir "$dir"; then
    ccseat_die "$name is the primary seat (~/.claude); ccseat never removes it" \
      "To use another seat by default: ccseat use <seat>"
  fi
  # A folder that leads to ~/.claude or holds the home folder: only the seat
  # entry goes; the folder and its login stay.
  if ccseat_is_primary_place "$dir" || ccseat_path_within "$CCSEAT_USER_HOME" "$dir" \
    || ccseat_path_within "$CCSEAT_PRIMARY_DIR" "$dir" || ccseat_path_within "$dir" "$CCSEAT_PRIMARY_DIR"; then
    shared=1
    keep=1
  fi
  email=$(ccseat_email "$dir" 2>/dev/null)
  who=$name
  [ -n "$email" ] && who="$name ($email)"
  if [ "$yes" != 1 ]; then
    if [ "$keep" = 1 ]; then
      q="Remove $who? Its folder and login stay where they are."
    else
      q="Remove $who? It is signed out and its folder goes to the Trash."
    fi
    ccseat_confirm "$q"
    rc=$?
    case "$rc" in
      0) ;;
      2) ccseat_die "not removing $name without a confirmation" "Run it in a terminal, or add -y: ccseat remove $name -y" ;;
      *) printf 'Nothing was removed.\n'; exit 130 ;;
    esac
  fi
  if [ "$keep" != 1 ]; then
    [ -d "$dir" ] && existed=1
    # Sign out even when the folder is already gone: on macOS the login is
    # in the Keychain, and a later seat at the same path must not find it.
    ccseat_auth_check "$dir"
    if [ "$CCSEAT_AUTH" != none ] && ccseat_claude_bin >/dev/null; then
      ccseat_claude_in "$dir" auth logout </dev/null >/dev/null 2>&1
    fi
    if [ -d "$dir" ]; then
      ccseat_trash "$dir" || ccseat_die "could not move $(ccseat_tilde "$dir") to the Trash, so $name is still a seat"
    fi
  fi
  cur=$(ccseat_current_get)
  ccseat_registry_remove "$name" || ccseat_die "could not save the seat list"
  rm -f "$(ccseat_usage_cache_path "$name")" "$(ccseat__usage_err_path "$name")" 2>/dev/null
  if [ "$cur" = "$name" ] && [ -f "$CCSEAT_CURRENT_FILE" ]; then
    if cur=$(ccseat_current_get); then ccseat_current_set "$cur"; else rm -f "$CCSEAT_CURRENT_FILE"; fi
  fi
  if [ "$shared" = 1 ]; then
    printf 'Removed %s. Its folder (%s) stays where it is.\n' "$name" "$(ccseat_tilde "$dir")"
  elif [ "$keep" = 1 ]; then
    printf 'Removed %s. Its folder stays at %s\n' "$name" "$(ccseat_tilde "$dir")"
    printf 'Add it back with: ccseat add --dir %s\n' "$(ccseat_tilde "$dir")"
  elif [ "$existed" = 1 ] && [ -n "${CCSEAT_TRASHED_TO:-}" ]; then
    printf 'Removed %s. Its folder is in %s.\n' "$name" "$CCSEAT_TRASHED_TO"
  else
    printf 'Removed %s.\n' "$name"
  fi
  return 0
}

# ---------- rename ----------

ccseat_cmd_rename() {
  local ref="" new="" old cur rc
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) ccseat_help rename; return 0 ;;
      -*) ccseat_die_usage "unknown option for rename: $1" rename ;;
      *)
        if [ -z "$ref" ]; then ref=$1
        elif [ -z "$new" ]; then new=$1
        else ccseat_die_usage "rename takes a seat and a new name" rename; fi ;;
    esac
    shift
  done
  [ -n "$ref" ] && [ -n "$new" ] || ccseat_die_usage "usage: ccseat rename <seat> <new name>" rename
  ccseat_need_jq
  ccseat_resolve_seat "$ref" || exit 1
  old=$CCSEAT_R_NAME
  new=$(printf '%s' "$new" | tr '[:upper:]' '[:lower:]')
  ccseat_valid_name "$new" || ccseat_die "$(ccseat_name_problem "$new")"
  if [ "$new" = "$old" ]; then
    printf '%s is already called %s.\n' "$old" "$new"
    return 0
  fi
  if ccseat__index_of_name "$new" >/dev/null; then
    ccseat_die "there is already a seat called $new"
  fi
  cur=$(ccseat_current_get)
  ccseat_registry_rename "$old" "$new"
  rc=$?
  case "$rc" in
    0) ;;
    2) ccseat_die "there is already a seat called $new" ;;
    *) ccseat_die "could not save the seat list" ;;
  esac
  [ -f "$(ccseat_usage_cache_path "$old")" ] && mv -f "$(ccseat_usage_cache_path "$old")" "$(ccseat_usage_cache_path "$new")" 2>/dev/null
  [ -f "$(ccseat__usage_err_path "$old")" ] && mv -f "$(ccseat__usage_err_path "$old")" "$(ccseat__usage_err_path "$new")" 2>/dev/null
  [ "$cur" = "$old" ] && ccseat_current_set "$new"
  printf 'Renamed %s to %s. Its login is unchanged.\n' "$old" "$new"
}

# ---------- use / current ----------

ccseat_cmd_use() {
  local ref=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) ccseat_help use; return 0 ;;
      -*) ccseat_die_usage "unknown option for use: $1" use ;;
      *) [ -z "$ref" ] || ccseat_die_usage "use takes one seat" use; ref=$1 ;;
    esac
    shift
  done
  [ -n "$ref" ] || ccseat_die_usage "which seat? Usage: ccseat use <seat>" use
  ccseat_need_jq
  ccseat_resolve_seat "$ref" || exit 1
  ccseat_current_set "$CCSEAT_R_NAME" || ccseat_die "could not save the current seat in $(ccseat_tilde "$CCSEAT_HOME")"
  if [ -n "${CCSEAT_SHELL:-}" ]; then
    printf 'Current seat: %s. The claude command opens it from now on.\n' "$CCSEAT_R_NAME"
  else
    printf 'Current seat: %s. Open it with: ccseat run %s\n' "$CCSEAT_R_NAME" "$CCSEAT_R_NAME"
  fi
  ccseat_auth_check "$CCSEAT_R_DIR"
  if [ "$CCSEAT_AUTH" = none ]; then
    printf '%s is not logged in yet: Claude Code asks you to sign in when it opens.\n' "$CCSEAT_R_NAME"
  fi
}

ccseat_cmd_current() {
  local c d
  case "${1:-}" in
    -h|--help) ccseat_help current; return 0 ;;
    --dir)
      c=$(ccseat_current_get) || ccseat_die "there are no seats yet" "Add one with: ccseat add"
      d=$(ccseat_seat_dir "$c")
      printf '%s\n' "$d"
      return 0 ;;
    "") ;;
    *) ccseat_die_usage "current takes no arguments (or --dir)" current ;;
  esac
  if c=$(ccseat_current_get); then
    printf '%s\n' "$c"
    return 0
  fi
  ccseat_die "there are no seats yet" "Add one with: ccseat add"
}

# ---------- list ----------

ccseat_cmd_list() {
  local json=0 i n cur w_idx w_name w_r5 w_r7 w_st total cols compact=0 s f5 f7 p5 p7 mark nc
  local pc5 pc7 st head avail others w_short short=0
  local -a F5 F7 ST
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1 ;;
      -h|--help) ccseat_help list; return 0 ;;
      *) ccseat_die_usage "unknown option for list: $1" list ;;
    esac
    shift
  done
  ccseat_need_jq
  ccseat__registry_ensure
  if [ "$CCSEAT_N" -eq 0 ]; then
    if [ "$json" = 1 ]; then printf '[]\n'; return 0; fi
    ccseat_no_seats_hint
    return 0
  fi
  # shellcheck disable=SC2046 # seat names never contain spaces
  ccseat_usage_refresh_wait 60 "$CCSEAT_USAGE_TTL" $(ccseat_fetchable_seats)
  if [ "$json" = 1 ]; then
    ccseat_rows_load 1
    ccseat__rows_json ""
    return 0
  fi
  ccseat_rows_load 0
  ccseat_colors_init 1
  cur=$(ccseat_current_get)

  w_idx=${#CCSEAT_N}
  w_name=4 w_r5=6 w_r7=6 w_st=6 w_short=6
  i=0
  while [ "$i" -lt "$CCSEAT_N" ]; do
    F5[i]=$(ccseat_fmt_reset "${CCSEAT_ROW_R5[i]}")
    F7[i]=$(ccseat_fmt_reset "${CCSEAT_ROW_R7[i]}")
    ST[i]=$(ccseat__row_status "$i")
    n=${CCSEAT_NAMES[i]}
    [ "${#n}" -gt "$w_name" ] && w_name=${#n}
    [ "${#F5[i]}" -gt "$w_r5" ] && w_r5=${#F5[i]}
    [ "${#F7[i]}" -gt "$w_r7" ] && w_r7=${#F7[i]}
    s=${ST[i]}
    [ "${#s}" -gt "$w_st" ] && w_st=${#s}
    s=$(ccseat__row_status "$i" short)
    [ "${#s}" -gt "$w_short" ] && w_short=${#s}
    i=$((i + 1))
  done
  total=$(( 2 + w_idx + 2 + w_name + 2 + 6 + 2 + w_r5 + 2 + 6 + 2 + w_r7 + 2 + w_st ))
  cols=80
  if [ -t 1 ]; then
    cols=$(ccseat_term_cols)
    if [ "$total" -gt "$cols" ]; then
      # "weekly limit" instead of "at its weekly limit" when that is what it
      # takes to keep the table; else one small block per seat.
      if [ $(( total - w_st + w_short )) -le "$cols" ]; then short=1; else compact=1; fi
    fi
  fi
  if [ "$short" = 1 ]; then
    i=0
    while [ "$i" -lt "$CCSEAT_N" ]; do
      ST[i]=$(ccseat__row_status "$i" short)
      i=$((i + 1))
    done
  fi

  if [ "$compact" = 0 ]; then
    printf '%s%s  %s  %s  %s  %s  %s  %s%s\n' "$CCSEAT_C_MID" "  $(ccseat_rpad '#' "$w_idx")" \
      "$(ccseat_pad seat "$w_name")" "5-hour" "$(ccseat_pad resets "$w_r5")" "weekly" \
      "$(ccseat_pad resets "$w_r7")" "status" "$CCSEAT_C_RESET"
  fi
  i=0
  while [ "$i" -lt "$CCSEAT_N" ]; do
    n=${CCSEAT_NAMES[i]}
    nc=$(ccseat__seat_color_at "$i")
    if [ "$n" = "$cur" ]; then mark="${CCSEAT_C_ORANGE}❯${CCSEAT_C_RESET} "; else mark="  "; fi
    p5=${CCSEAT_ROW_P5[i]} p7=${CCSEAT_ROW_P7[i]}
    f5=${F5[i]} f7=${F7[i]}
    if [ "${CCSEAT_ROW_AUTH[i]}" = none ]; then p5=- p7=- f5=- f7=-; fi
    pc5=$(ccseat_pct_color "$p5" "$(ccseat_config_get limit_5h)")
    pc7=$(ccseat_pct_color "$p7" "$(ccseat_config_get limit_weekly)")
    [ "$p5" != - ] && p5="$p5%"
    [ "$p7" != - ] && p7="$p7%"
    st=${ST[i]}
    if [ "$compact" = 0 ]; then
      printf '%s%s  %s%s%s  %s%s%s  %s  %s%s%s  %s  %s%s%s\n' "$mark" "$(ccseat_rpad $((i + 1)) "$w_idx")" \
        "$nc" "$(ccseat_pad "$n" "$w_name")" "$CCSEAT_C_RESET" \
        "$pc5" "$(ccseat_rpad "$p5" 6)" "$CCSEAT_C_RESET" \
        "$(ccseat_pad "$f5" "$w_r5")" \
        "$pc7" "$(ccseat_rpad "$p7" 6)" "$CCSEAT_C_RESET" \
        "$(ccseat_pad "$f7" "$w_r7")" "$(ccseat__row_status_color "$i")" "$st" "$CCSEAT_C_RESET"
      i=$((i + 1))
      continue
    fi
    # Stacked: the name and status, then one line per window.
    head=$((i + 1))
    head=$(( 2 + ${#head} + 2 ))
    avail=$(( cols - head - 2 - ${#st} ))
    [ "$avail" -lt 8 ] && avail=8
    n=$(ccseat_trunc "$n" "$avail")
    avail=$(( cols - head - ${#n} - 2 ))
    [ "$avail" -lt 4 ] && avail=4
    printf '%s%s  %s%s%s  %s%s%s\n' "$mark" "$((i + 1))" "$nc" "$n" "$CCSEAT_C_RESET" \
      "$(ccseat__row_status_color "$i")" "$(ccseat_trunc "$st" "$avail")" "$CCSEAT_C_RESET"
    if [ "$p5" != - ] || [ "$p7" != - ]; then
      ccseat__list_stacked_line 5-hour "$p5" "$pc5" "$f5" "$cols"
      ccseat__list_stacked_line weekly "$p7" "$pc7" "$f7" "$cols"
    fi
    i=$((i + 1))
  done
  if [ -t 1 ] && [ -z "${CCSEAT__OTHERS_SHOWN:-}" ]; then
    others=$(ccseat_find_other_dirs 2>/dev/null)
    if [ -n "$others" ]; then
      printf '\n'
      ccseat__other_dirs_hint "$others" "$CCSEAT_C_FAINT" "$CCSEAT_C_RESET"
    elif [ "$CCSEAT_N" -eq 1 ]; then
      printf '\n%sAdd another account with: ccseat add%s\n' "$CCSEAT_C_FAINT" "$CCSEAT_C_RESET"
    fi
  fi
  return 0
}

# "   5-hour   96%  resets 5:47 PM", fitted to the width.
ccseat__list_stacked_line() {
  local label="$1" p="$2" pc="$3" f="$4" cols="$5" avail
  avail=$(( cols - 17 ))
  [ "$f" != - ] && f="resets $f"
  if [ "${#f}" -gt "$avail" ]; then f=${f#resets }; fi
  [ "$avail" -lt 1 ] && avail=1
  printf '   %s%s%s  %s%s%s  %s%s%s\n' "$CCSEAT_C_MID" "$label" "$CCSEAT_C_RESET" "$pc" "$(ccseat_rpad "$p" 4)" \
    "$CCSEAT_C_RESET" "$CCSEAT_C_FAINT" "$(ccseat_trunc "$f" "$avail")" "$CCSEAT_C_RESET"
}

# What the status column says: the limit a seat is at comes first ("weekly
# limit" with $2=short, for a tight table).
ccseat__row_status() {
  local i="$1" s lim
  s=${CCSEAT_ROW_STATUS[i]}
  if [ -n "${CCSEAT_ROW_LIMIT[i]}" ]; then
    if [ "${2:-}" = short ]; then lim="${CCSEAT_ROW_LIMIT[i]} limit"
    else lim="at its ${CCSEAT_ROW_LIMIT[i]} limit"; fi
    if [ "$s" = live ]; then s=$lim; else s="$lim, $s"; fi
  fi
  printf '%s' "$s"
}

# Color only where it means something: limits and missing logins in orange,
# trouble fetching in kraft, the rest faint.
ccseat__row_status_color() {
  local i="$1"
  if [ -n "${CCSEAT_ROW_LIMIT[i]}" ]; then printf '%s' "$CCSEAT_C_ORANGE"; return; fi
  case "${CCSEAT_ROW_STATUS[i]}" in
    "not logged in") printf '%s' "$CCSEAT_C_ORANGE" ;;
    offline|"usage unavailable") printf '%s' "$CCSEAT_C_KRAFT" ;;
    *) printf '%s' "$CCSEAT_C_FAINT" ;;
  esac
}

# ---------- run / launch ----------

# Replaces this process with Claude Code opened in a seat.
ccseat_exec_seat() {
  local name="$1" dir="$2" bin
  shift 2
  bin=$(ccseat_claude_bin) || ccseat_need_claude
  if ! ccseat_is_primary_dir "$dir" && ! [ -d "$dir" ]; then
    ccseat_die "the folder of $name is missing ($(ccseat_tilde "$dir"))" \
      "Put the folder back, or remove the seat with: ccseat remove $name"
  fi
  ccseat_prepare_seat "$dir"
  export CCSEAT_SEAT="$name"
  if ccseat_is_primary_dir "$dir"; then
    unset CLAUDE_CONFIG_DIR
  else
    export CLAUDE_CONFIG_DIR="$dir"
  fi
  exec "$bin" "$@"
}

# Signs a seat in first when it has no login and we are on a terminal.
ccseat__login_if_needed() {
  local name="$1" dir="$2"
  [ -t 0 ] && [ -t 1 ] || return 0
  ccseat_auth_check "$dir"
  [ "$CCSEAT_AUTH" = none ] || return 0
  printf '%s is not logged in yet. Signing in first; your browser opens.\n\n' "$name"
  ccseat_login "$dir" || ccseat_die "the login did not finish" "Try again with: ccseat run $name"
  printf '\n'
}

ccseat_cmd_run() {
  local ref=""
  case "${1:-}" in
    -h|--help) ccseat_help run; return 0 ;;
    "") ccseat_die_usage "which seat? Usage: ccseat run <seat> [claude arguments]" run ;;
  esac
  ref=$1
  shift
  [ "${1:-}" = "--" ] && shift
  # Without jq a login looks absent, and run would start a needless sign-in.
  ccseat_need_jq
  ccseat_resolve_seat "$ref" || exit 1
  ccseat__login_if_needed "$CCSEAT_R_NAME" "$CCSEAT_R_DIR"
  ccseat_exec_seat "$CCSEAT_R_NAME" "$CCSEAT_R_DIR" "$@"
}

# Claude Code subcommands that do not start a session: no auto-switch, no
# network, straight to the current seat.
ccseat__is_claude_subcommand() {
  case "${1:-}" in
    auth|mcp|config|doctor|update|upgrade|install|migrate-installer|setup-token|plugin|plugins|agents|api-key|-v|--version|-h|--help)
      return 0 ;;
  esac
  return 1
}

# True when "claude mcp ..." arguments ask for the user scope.
ccseat__mcp_user_scope() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -s|--scope) [ "${2:-}" = user ] && return 0; shift ;;
      --scope=user|-s=user|-suser) return 0 ;;
    esac
    shift
  done
  return 1
}

# True for "claude mcp remove NAME" without a scope, when NAME is a server
# ccseat copied into the seat from ~/.claude (removing only the copy would
# not last: the next sync brings it back).
ccseat__mcp_remove_synced() {
  local dir="$1" server="" synced
  shift 3
  while [ $# -gt 0 ]; do
    case "$1" in
      -s|--scope) return 1 ;;
      --scope=*|-s=*) return 1 ;;
      -*) ;;
      *) [ -z "$server" ] && server=$1 ;;
    esac
    shift
  done
  [ -n "$server" ] || return 1
  synced=" $(ccseat__state_get "$dir" mcp) "
  case "$synced" in *" $server "*) return 0 ;; esac
  return 1
}

# Management commands through the claude wrapper. MCP servers at user scope
# belong in ~/.claude, which every seat copies, so those changes go there and
# every seat is synced right after. A sign-in or sign-out says which seat it
# changes. Returns when the command should simply run in the seat.
ccseat__claude_manage() {
  local name="$1" dir="$2" bin="$3" rc i
  shift 3
  case "${1:-} ${2:-}" in
    "mcp add"|"mcp add-json"|"mcp add-from-claude-desktop"|"mcp remove")
      ccseat_is_primary_place "$dir" && return 0
      if ccseat__mcp_user_scope "$@" || { [ "$2" = remove ] && ccseat__mcp_remove_synced "$dir" "$@"; }; then
        env -u CLAUDE_CONFIG_DIR "$bin" "$@"
        rc=$?
        i=0
        while [ "$i" -lt "$CCSEAT_N" ]; do
          ccseat_sync_json "${CCSEAT_DIRS[i]}" >/dev/null 2>&1
          i=$((i + 1))
        done
        [ "$rc" -eq 0 ] && ccseat_note "changed in ~/.claude and copied to every seat"
        exit "$rc"
      fi ;;
    "auth login")
      ccseat_note "signing in again in the seat $name" "To add another account instead: ccseat add" ;;
    "auth logout")
      ccseat_note "signing out the seat $name" ;;
  esac
  return 0
}

# The "claude" shell function lands here. It must never get in the way:
# without seats, or on any trouble, it runs plain Claude Code. A
# CLAUDE_CONFIG_DIR set on purpose (CLAUDE_CONFIG_DIR=~/.claude-work claude,
# or an alias doing that, or a claude started inside a seat's session) is
# respected: a registered folder opens that seat, any other opens as asked.
ccseat_cmd_claude() {
  local bin cur ci bi dir name msg soonest want
  bin=$(ccseat_claude_bin) || ccseat_need_claude
  want=${CLAUDE_CONFIG_DIR:-}
  if ! command -v jq >/dev/null 2>&1; then
    exec "$bin" "$@"
  fi
  ccseat_first_run
  ccseat__registry_ensure
  if [ -n "$want" ]; then
    cur=$(ccseat_seat_for_dir "$want") || exec "$bin" "$@"
  elif [ "$CCSEAT_N" -eq 0 ] || ! cur=$(ccseat_current_get); then
    exec "$bin" "$@"
  fi
  ci=$(ccseat_seat_index "$cur") || exec "$bin" "$@"
  name=$cur
  dir=${CCSEAT_DIRS[ci]}

  if ccseat__is_claude_subcommand "${1:-}"; then
    ccseat__claude_manage "$name" "$dir" "$bin" "$@"
  else
    ccseat__claude_refresh "$ci"
    # Only a seat at its limit needs the others' numbers.
    ccseat_usage_load "$name" "$dir"
    if [ "$(ccseat_config_get auto_switch)" = on ] && [ "$CCSEAT_N" -gt 1 ] && ccseat_usage_at_limit; then
      ccseat_rows_load 0
      if [ -n "${CCSEAT_ROW_LIMIT[ci]}" ]; then
        if bi=$(ccseat_rows_freest "$ci") && [ "${CCSEAT_ROW_SCORE[bi]}" -lt 1000 ]; then
          name=${CCSEAT_NAMES[bi]}
          dir=${CCSEAT_DIRS[bi]}
          msg="ccseat: $cur is at its ${CCSEAT_ROW_LIMIT[ci]} limit"
          [ "${CCSEAT_ROW_UNTIL[ci]}" != - ] && msg="$msg until $(ccseat_fmt_reset "${CCSEAT_ROW_UNTIL[ci]}")"
          printf '%s, using %s\n' "$msg" "$name" >&2
        else
          # Every seat is at a limit: the one that frees up first.
          soonest=$ci
          if bi=$(ccseat_rows_freest) && [ "${CCSEAT_ROW_SCORE[bi]}" -lt "${CCSEAT_ROW_SCORE[ci]}" ]; then
            soonest=$bi
          fi
          if [ "$soonest" != "$ci" ]; then
            name=${CCSEAT_NAMES[soonest]}
            dir=${CCSEAT_DIRS[soonest]}
            msg="ccseat: every seat is at its limit; using $name, the first to reset"
            [ "${CCSEAT_ROW_UNTIL[soonest]}" != - ] && msg="$msg ($(ccseat_fmt_reset "${CCSEAT_ROW_UNTIL[soonest]}"))"
          else
            msg="ccseat: every seat is at its limit; staying on $cur, the first to reset"
            [ "${CCSEAT_ROW_UNTIL[ci]}" != - ] && msg="$msg ($(ccseat_fmt_reset "${CCSEAT_ROW_UNTIL[ci]}"))"
          fi
          printf '%s\n' "$msg" >&2
        fi
      fi
    fi
  fi
  if ! ccseat_is_primary_dir "$dir" && ! [ -d "$dir" ]; then
    [ -n "$want" ] && exec "$bin" "$@"
    printf 'ccseat: the folder of %s is missing (%s), so Claude Code opens with ~/.claude\n' \
      "$name" "$(ccseat_tilde "$dir")" >&2
    unset CLAUDE_CONFIG_DIR
    exec "$bin" "$@"
  fi
  ccseat__is_claude_subcommand "${1:-}" || ccseat__login_if_needed "$name" "$dir"
  ccseat_exec_seat "$name" "$dir" "$@"
}

# Usage data for the wrapper without making the user wait: the current seat
# is fetched in the foreground (at most 1.5 s) only when its data is old or
# close to a limit; everything else refreshes in the background.
ccseat__claude_refresh() {
  local ci="$1" name age others="" i score l5 l7
  name=${CCSEAT_NAMES[ci]}
  ccseat_auth_check "${CCSEAT_DIRS[ci]}"
  if [ "$CCSEAT_AUTH" = ok ]; then
    age=$(ccseat_file_age "$(ccseat_usage_cache_path "$name")")
    if [ "$age" -ge "$CCSEAT_USAGE_TTL" ]; then
      ccseat_usage_load "$name" "${CCSEAT_DIRS[ci]}"
      score=0
      [ "$CCSEAT_U_P5" != - ] && score=$CCSEAT_U_P5
      l5=$(ccseat_config_get limit_5h)
      l7=$(ccseat_config_get limit_weekly)
      if [ "$age" -ge 900 ] || [ "$CCSEAT_U_SRC" = none ] || [ "$score" -ge $((l5 - 15)) ] \
        || { [ "$CCSEAT_U_P7" != - ] && [ "$CCSEAT_U_P7" -ge $((l7 - 10)) ]; }; then
        ccseat_usage_fetch_bounded "$name" 15
      else
        ccseat_usage_refresh_detached "$CCSEAT_USAGE_TTL" "$name"
      fi
    fi
  fi
  # The other seats refresh in the background; the fetch itself skips seats
  # without a usable login.
  i=0
  while [ "$i" -lt "$CCSEAT_N" ]; do
    [ "$i" != "$ci" ] && others="$others ${CCSEAT_NAMES[i]}"
    i=$((i + 1))
  done
  # shellcheck disable=SC2086 # seat names never contain spaces
  [ -n "$others" ] && ccseat_usage_refresh_detached "$CCSEAT_USAGE_TTL" $others
  return 0
}

# ---------- sync ----------

ccseat_cmd_sync() {
  local ref="" i name dir did=0 note line
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) ccseat_help sync; return 0 ;;
      -*) ccseat_die_usage "unknown option for sync: $1" sync ;;
      *) [ -z "$ref" ] || ccseat_die_usage "sync takes one seat" sync; ref=$1 ;;
    esac
    shift
  done
  ccseat_need_jq
  ccseat__registry_ensure
  if [ "$CCSEAT_N" -eq 0 ]; then
    ccseat_no_seats_hint
    return 0
  fi
  ccseat_colors_init 1
  if [ -n "$ref" ]; then
    ccseat_resolve_seat "$ref" || exit 1
    if ccseat_is_primary_dir "$CCSEAT_R_DIR"; then
      printf '%s is the primary seat: the other seats copy from it.\n' "$CCSEAT_R_NAME"
      return 0
    fi
  fi
  i=0
  while [ "$i" -lt "$CCSEAT_N" ]; do
    name=${CCSEAT_NAMES[i]}
    dir=${CCSEAT_DIRS[i]}
    i=$((i + 1))
    [ -n "$ref" ] && [ "$name" != "$CCSEAT_R_NAME" ] && continue
    ccseat_is_primary_place "$dir" && continue
    did=1
    if ! [ -d "$dir" ]; then
      printf '%s%s%s: folder missing (%s). Remove the seat with: ccseat remove %s\n' \
        "$(ccseat__seat_color_at $((i - 1)))" "$name" "$CCSEAT_C_RESET" "$(ccseat_tilde "$dir")" "$name"
      continue
    fi
    ccseat_links_ensure "$dir"
    ccseat__links_prune "$dir"
    note=$CCSEAT_LINK_NOTES
    ccseat_sync_json "$dir" 1
    printf '%s%s%s: %s, %s, %s shared\n' "$(ccseat__seat_color_at $((i - 1)))" "$name" "$CCSEAT_C_RESET" \
      "$(ccseat__plural "$CCSEAT_SYNC_MCP" "MCP server")" "$(ccseat__plural "$CCSEAT_SYNC_TRUST" "trusted folder")" \
      "$(ccseat__plural "$CCSEAT_LINK_OK" item)"
    if [ -n "$CCSEAT_SYNC_NOTE" ] && [ "$CCSEAT_SYNC_NOTE" != busy ]; then
      printf '  %s%s%s\n' "$CCSEAT_C_KRAFT" "$CCSEAT_SYNC_NOTE" "$CCSEAT_C_RESET"
    fi
    if [ -n "$CCSEAT_LINK_CUSTOM" ]; then
      printf '  %skept links that point elsewhere:%s%s\n' "$CCSEAT_C_MID" "$CCSEAT_LINK_CUSTOM" "$CCSEAT_C_RESET"
    fi
    if [ -n "$note" ]; then
      printf '%s\n' "${note#"$CCSEAT_NL"}" | while IFS= read -r line; do
        printf '  %s%s%s\n' "$CCSEAT_C_MID" "$line" "$CCSEAT_C_RESET"
      done
    fi
  done
  if [ "$did" = 0 ]; then
    printf 'Nothing to sync: the primary is the only seat. Add another with: ccseat add\n'
  fi
  return 0
}

ccseat__plural() {
  if [ "$1" = 1 ]; then printf '1 %s' "$2"; else printf '%s %ss' "$1" "$2"; fi
}
