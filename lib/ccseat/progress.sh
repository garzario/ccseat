# shellcheck shell=bash
# ccseat progress: workflows and agents still running in a Claude Code session.
#
#   ccseat progress [session_id]            readable summary (every session when no id is known)
#   ccseat progress --line [session_id]     one compact line, nothing when idle
#   ccseat progress --tsv [session_id]      one row per running workflow: name, phase index,
#       phase count, phase title, agents finished, agents started, agents running, agents
#       failed, minutes since start, agents started in this phase, agents finished in this phase
#   ccseat progress --agents [session_id]   one row per running agent: kind (wf, bg or fg),
#       workflow name, label, agent type, tool calls, last tool, idle seconds, minutes alive
#
# session_id defaults to $CLAUDE_CODE_SESSION_ID, which Claude Code sets for its tools.
# Empty text fields print as "-". Read-only.
#
# Sources, under <config>/projects/<project>/<session>/ (a session spans several project
# dirs when its working folder changes, so every match is read):
#   subagents/workflows/<run>/journal.jsonl   one JSON line per agent event (started, result,
#                                             failed) with key, agentId, label and phase
#   workflows/<run>.json                      written when the run ends
#   workflows/scripts/<name>-<run>.js         the script; phase titles come from its meta block
#   subagents/agent-<id>.meta.json + .jsonl   agents started with the Agent tool
# <config> is $CLAUDE_CONFIG_DIR (or ~/.claude) plus ~/.claude. This is the internal layout of
# Claude Code 2.1; if it changes the output is simply empty.

_CCSEAT_PG_FRESH=21600          # a run whose journal is quiet for 6 hours is abandoned
_CCSEAT_PG_TEAMMATE_IDLE=120    # a teammate waiting for messages is not running
_CCSEAT_PG_SILENT=1800          # any other agent silent for 30 minutes has ended or died
_CCSEAT_PG_US=$'\037'

# One reduce over the journal. An agent is its key; each "started" with a new agentId is a
# retry that replaces the previous attempt, and only a result or failure of the latest
# attempt finishes it, so retries are neither double counted nor reported as done early.
# Line 1: started, finished, failed, current phase, first label, started in phase, finished
# in phase. Next lines: agentId and label of each running agent.
# shellcheck disable=SC2016 # a jq program, not shell
_CCSEAT_PG_JQ='def clean: tostring | gsub("[\t\n\r]"; " ") | gsub("[[:cntrl:]]"; "");
reduce (inputs | fromjson? | select(type == "object" and .key != null)) as $e
  ({order: [], k: {}, ph: "", first: ""};
   ($e.key | tostring) as $key
   | if $e.type == "started" then
       (if .k[$key] == null then .order += [$key] else . end)
       | .k[$key] = {id: ($e.agentId // "" | tostring), label: ($e.label // "" | clean),
                     phase: ($e.phase // "" | clean), st: "run"}
       | .ph = ($e.phase // "" | clean)
       | (if .first == "" and ($e.label // "") != "" then .first = ($e.label | clean) else . end)
     elif ($e.type == "result" or $e.type == "failed") and .k[$key] != null then
       (if ($e.agentId // "") == "" or ($e.agentId | tostring) == .k[$key].id
        then .k[$key].st = (if $e.type == "failed" then "fail" else "ok" end) else . end)
     else . end)
| . as $s
| [.order[] | $s.k[.]] as $a
| ($a | map(select(.phase == $s.ph))) as $p
| ([($a | length), ($a | map(select(.st != "run")) | length),
    ($a | map(select(.st == "fail")) | length), $s.ph, $s.first,
    ($p | length), ($p | map(select(.st != "run")) | length)] | map(tostring) | join("\u001f")),
  ($a[] | select(.st == "run") | "\(.id)\u001f\(.label)")'

# stat flavor, decided without spawning anything: BSD stat on macOS and the BSDs (called by
# its full path so GNU coreutils first on PATH cannot shadow it), GNU or BusyBox elsewhere.
case "${OSTYPE:-}" in
  darwin*|*bsd*|dragonfly*)
    _CCSEAT_PG_STAT=bsd
    if [ -x /usr/bin/stat ]; then _CCSEAT_PG_STATCMD=/usr/bin/stat; else _CCSEAT_PG_STATCMD=stat; fi ;;
  *) _CCSEAT_PG_STAT=gnu; _CCSEAT_PG_STATCMD=stat ;;
esac

# Sets the clock and the projects roots once, in the calling shell.
# $1 = current epoch seconds when the caller already has it.
# shellcheck disable=SC2120 # the arguments are optional
_ccseat_pg_init() {
  local r real seen=$'\n' a b
  _CCSEAT_PG_NOW=${1:-$(date +%s)}
  _CCSEAT_PG_ROOTS=()
  a="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; a="${a%/}/projects"
  b="$HOME/.claude/projects"
  for r in "$a" "$b"; do
    [ -d "$r" ] || continue
    if [ "$a" = "$b" ]; then real=$r
    else real=$(cd -P "$r" 2>/dev/null && pwd) || continue; fi
    case "$seen" in *$'\n'"$real"$'\n'*) continue ;; esac
    seen="$seen$real"$'\n'
    _CCSEAT_PG_ROOTS+=("$real")
  done
}

# Prints "mtime path" for each existing file argument (one stat call for all of them).
_ccseat_pg_mtimes() {
  [ $# -gt 0 ] || return 0
  if [ "$_CCSEAT_PG_STAT" = gnu ]; then "$_CCSEAT_PG_STATCMD" -c '%Y %n' "$@" 2>/dev/null
  else "$_CCSEAT_PG_STATCMD" -f '%m %N' "$@" 2>/dev/null; fi
  return 0
}

_ccseat_pg_mtime() {
  local m
  if [ "$_CCSEAT_PG_STAT" = gnu ]; then m=$("$_CCSEAT_PG_STATCMD" -c %Y "$1" 2>/dev/null)
  else m=$("$_CCSEAT_PG_STATCMD" -f %m "$1" 2>/dev/null); fi
  case "$m" in ''|*[!0-9]*) m=0 ;; esac
  printf '%s\n' "$m"
}

# Birth time, 0 when the filesystem does not record it.
_ccseat_pg_btime() {
  local m
  if [ "$_CCSEAT_PG_STAT" = gnu ]; then m=$("$_CCSEAT_PG_STATCMD" -c %W "$1" 2>/dev/null)
  else m=$("$_CCSEAT_PG_STATCMD" -f %B "$1" 2>/dev/null); fi
  case "$m" in ''|*[!0-9]*) m=0 ;; esac
  printf '%s\n' "$m"
}

# Every file matching <root>/*/<session>/<suffix> across the roots, one per line, in _PG_HITS
# (no subshell). The suffix may hold a glob; session and run ids are checked to be plain
# words before they get here.
_ccseat_pg_glob() {
  local sid=$1 suffix=$2 root f
  _PG_HITS=""
  for root in ${_CCSEAT_PG_ROOTS[@]+"${_CCSEAT_PG_ROOTS[@]}"}; do
    # shellcheck disable=SC2231 # the suffix is a glob on purpose
    for f in "$root"/*/"$sid"/$suffix; do
      [ -e "$f" ] && _PG_HITS="$_PG_HITS$f"$'\n'
    done
  done
  return 0
}

# Prints the journals of runs that may still be running (changed in the last 6 hours).
# $1 = session id, or empty for every session.
_ccseat_pg_journals() {
  local sid=${1:-*} root m p
  set --
  for root in ${_CCSEAT_PG_ROOTS[@]+"${_CCSEAT_PG_ROOTS[@]}"}; do
    # shellcheck disable=SC2231 # "*" matches every session
    for p in "$root"/*/$sid/subagents/workflows/wf_*/journal.jsonl; do
      [ -f "$p" ] && set -- "$@" "$p"
    done
  done
  [ $# -gt 0 ] || return 0
  _ccseat_pg_mtimes "$@" | while read -r m p; do
    case "$m" in ''|*[!0-9]*) continue ;; esac
    [ $(( _CCSEAT_PG_NOW - m )) -le "$_CCSEAT_PG_FRESH" ] && printf '%s\n' "$p"
  done
  return 0
}

# Phase titles from the meta block at the top of a workflow script, one per line.
_ccseat_pg_phases() {
  local line re="title[\"']?[[:space:]]*:[[:space:]]*[\"'\`]([^\"'\`]+)[\"'\`]"
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    while [[ $line =~ $re ]]; do
      printf '%s\n' "${BASH_REMATCH[1]//[[:cntrl:]]/}"
      line=${line#*"${BASH_REMATCH[0]}"}
    done
    case "$line" in "}"*) break ;; esac
  done < "$1"
  return 0
}

# Reads one run. $1 = journal, $2 = 1 to skip the start time (the status line does not show
# it). Returns 1 when the run already ended. Sets:
#   _pg_name _pg_k _pg_n _pg_phase _pg_done _pg_started _pg_running _pg_failed _pg_mins
#   _pg_ps _pg_pd _pg_pending (next phase titles, comma separated) _pg_rundir _pg_sid
#   _pg_live (agentId<US>label per running agent, one per line)
_ccseat_pg_run() {
  local j=$1 run sdir out head script t start first=""
  _pg_rundir=${j%/journal.jsonl}; run=${_pg_rundir##*/}
  sdir=${_pg_rundir%/subagents/workflows/*}; _pg_sid=${sdir##*/}
  case "$run$_pg_sid" in *[!A-Za-z0-9_-]*) return 1 ;; esac
  _ccseat_pg_glob "$_pg_sid" "workflows/$run.json"
  [ -n "$_PG_HITS" ] && return 1

  _pg_started=""; _pg_done=0; _pg_failed=0; _pg_phase=""; _pg_ps=0; _pg_pd=0; _pg_live=""
  out=$(jq -nrR "$_CCSEAT_PG_JQ" < "$j" 2>/dev/null)
  if [ -n "$out" ]; then
    head=${out%%$'\n'*}
    IFS=$_CCSEAT_PG_US read -r _pg_started _pg_done _pg_failed _pg_phase first _pg_ps _pg_pd <<EOF
$head
EOF
    case "$out" in *$'\n'*) _pg_live=${out#*$'\n'} ;; esac
  fi
  case "$_pg_started" in
    ''|*[!0-9]*)
      _pg_started=$(grep -c '"type":"started"' "$j" 2>/dev/null)
      _pg_done=$(grep -cE '"type":"(result|failed)"' "$j" 2>/dev/null)
      _pg_failed=$(grep -c '"type":"failed"' "$j" 2>/dev/null)
      _pg_phase=""; _pg_ps=0; _pg_pd=0; _pg_live="" ;;
  esac
  for t in _pg_started _pg_done _pg_failed _pg_ps _pg_pd; do
    case "${!t}" in ''|*[!0-9]*) eval "$t=0" ;; esac
  done
  _pg_running=$(( _pg_started - _pg_done )); [ "$_pg_running" -lt 0 ] && _pg_running=0

  _ccseat_pg_glob "$_pg_sid" "workflows/scripts/*-$run.js"
  script=${_PG_HITS%%$'\n'*}
  if [ -n "$script" ]; then
    _pg_name=${script##*/}; _pg_name=${_pg_name%-"$run".js}; _pg_name=${_pg_name//[[:cntrl:]]/}
  else
    _pg_name=${first:-workflow}
  fi
  _pg_k=0; _pg_n=0; _pg_pending=""
  if [ -n "$script" ]; then
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      _pg_n=$(( _pg_n + 1 ))
      if [ "$_pg_k" -gt 0 ]; then _pg_pending="${_pg_pending:+$_pg_pending, }$t"
      elif [ -n "$_pg_phase" ] && [ "$t" = "$_pg_phase" ]; then _pg_k=$_pg_n; fi
    done <<EOF
$(_ccseat_pg_phases "$script")
EOF
  fi

  _pg_mins=0
  [ "${2:-0}" = 1 ] && return 0
  start=$(_ccseat_pg_btime "$j")
  [ "$start" -gt 0 ] || { [ -n "$script" ] && start=$(_ccseat_pg_mtime "$script"); }
  [ "$start" -gt 0 ] || start=$_CCSEAT_PG_NOW
  _pg_mins=$(( (_CCSEAT_PG_NOW - start) / 60 )); [ "$_pg_mins" -lt 0 ] && _pg_mins=0
  return 0
}

# Tool calls, last tool and minutes alive of one agent transcript.
# $1 = transcript, $2 = meta file (start time fallback), $3 = its mtime.
# Sets _pg_calls _pg_last _pg_age.
_ccseat_pg_agent_stats() {
  local a=$1 m=$2 born
  born=$(_ccseat_pg_btime "$a")
  [ "$born" -gt 0 ] || born=$(_ccseat_pg_mtime "$m")
  [ "$born" -gt 0 ] || born=$3
  _pg_age=$(( (_CCSEAT_PG_NOW - born) / 60 )); [ "$_pg_age" -lt 0 ] && _pg_age=0
  _pg_calls=$(grep -c '"type":"tool_use"' "$a" 2>/dev/null)
  case "$_pg_calls" in ''|*[!0-9]*) _pg_calls=0 ;; esac
  _pg_last=$(tail -c 400000 "$a" 2>/dev/null \
    | grep -o '"type":"tool_use","id":"[^"]*","name":"[^"]*"' | tail -n 1 \
    | sed 's/.*"name":"//; s/"$//')
  [ -n "$_pg_last" ] || _pg_last="-"
  return 0
}

_ccseat_pg_meta() {
  jq -r '[.requestShape // "", .taskKind // "", .toolUseId // "", .description // "agent", .agentType // ""]
    | map(tostring | gsub("[\t\n\r]"; " ") | gsub("[[:cntrl:]]"; "")) | join("\u001f")' "$1" 2>/dev/null
}

_ccseat_pg_dash() { if [ -n "$1" ]; then printf '%s' "$1"; else printf -- '-'; fi; }

# Session transcripts (<root>/<project>/<session>.jsonl), where Claude Code records when an
# agent it started has finished.
_ccseat_pg_transcripts() {
  local root f
  for root in ${_CCSEAT_PG_ROOTS[@]+"${_CCSEAT_PG_ROOTS[@]}"}; do
    for f in "$root"/*/"$1".jsonl; do [ -f "$f" ] && printf '%s\n' "$f"; done
  done
  return 0
}

# Which of several fixed strings appear in the transcripts, one per line of output.
# $1 = transcripts (one per line), $2 = the strings (one per line), $3 = a second string the
# same line must hold ("" for none). Two or three processes whatever the number of agents.
_ccseat_pg_grep_all() {
  local t list=$1 pats=$2 also=$3
  set --
  while IFS= read -r t; do [ -f "$t" ] && set -- "$@" "$t"; done <<EOF
$list
EOF
  [ $# -gt 0 ] || return 0
  if [ -n "$also" ]; then
    printf '%s' "$pats" | grep -h -F -f /dev/stdin -- "$@" 2>/dev/null | grep -F -- "$also" \
      | grep -o -F -f <(printf '%s' "$pats") 2>/dev/null
  else
    printf '%s' "$pats" | grep -h -o -F -f /dev/stdin -- "$@" 2>/dev/null
  fi
  return 0
}

# Everything running in one session, in one pass over its files.
#   $1 session id ("" = every session, workflows only)
#   $2 what to print: w (workflow rows), a (agent rows) or wa (both)
#   $3 1 for the light version the status line uses: no start times, agent types or tool
#      counts ("-" and 0 instead), one stat call per folder
# Workflow rows start with "W<TAB>", agent rows with "A<TAB>", then the --tsv or --agents fields.
_ccseat_pg_collect() {
  local sid=$1 what=$2 light=${3:-0} j aid label a m typ p mt idle id shape tk tuid desc kind
  local transcripts name files lives recent metas bgpat fgpat finished
  while IFS= read -r j; do
    [ -n "$j" ] || continue
    _ccseat_pg_run "$j" "$light" || continue
    name=$(_ccseat_pg_dash "${_pg_name//$'\t'/ }")
    case "$what" in *w*)
      printf 'W\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" \
        "$_pg_k" "$_pg_n" "$(_ccseat_pg_dash "$_pg_phase")" "$_pg_done" "$_pg_started" \
        "$_pg_running" "$_pg_failed" "$_pg_mins" "$_pg_ps" "$_pg_pd" ;;
    esac
    case "$what" in *a*) ;; *) continue ;; esac
    [ -n "$_pg_live" ] || continue
    # Transcripts of the running agents, stat'ed together; label by agentId.
    set --; lives=$'\n'
    while IFS=$_CCSEAT_PG_US read -r aid label; do
      case "$aid" in ''|*[!A-Za-z0-9_-]*) continue ;; esac
      a="$_pg_rundir/agent-$aid.jsonl"
      [ -f "$a" ] || continue
      set -- "$@" "$a"; lives="$lives$aid$_CCSEAT_PG_US${label:-agent}"$'\n'
    done <<EOF
$_pg_live
EOF
    [ $# -gt 0 ] || continue
    while read -r mt a; do
      case "$mt" in ''|*[!0-9]*) continue ;; esac
      aid=${a##*/agent-}; aid=${aid%.jsonl}
      label=${lives#*$'\n'"$aid$_CCSEAT_PG_US"}; label=${label%%$'\n'*}
      idle=$(( _CCSEAT_PG_NOW - mt )); [ "$idle" -lt 0 ] && idle=0
      if [ "$light" = 1 ]; then
        typ=""; _pg_calls="-"; _pg_last="-"; _pg_age=0
      else
        m="${a%.jsonl}.meta.json"
        typ=$(jq -r '.agentType // "" | tostring | gsub("[\t\n\r]"; " ") | gsub("[[:cntrl:]]"; "")' "$m" 2>/dev/null)
        _ccseat_pg_agent_stats "$a" "$m" "$mt"
      fi
      printf 'A\twf\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$(_ccseat_pg_dash "$label")" \
        "$(_ccseat_pg_dash "$typ")" "$_pg_calls" "$_pg_last" "$idle" "$_pg_age"
    done <<EOF
$(_ccseat_pg_mtimes "$@")
EOF
  done <<EOF
$(_ccseat_pg_journals "$sid")
EOF

  case "$what" in *a*) ;; *) return 0 ;; esac
  [ -n "$sid" ] || return 0
  # Agents started with the Agent tool, outside workflows. Anything silent for 30 minutes is
  # dropped before its meta file is read; the rest are read with one jq call, and one grep per
  # kind tells which of them the session already reported as finished.
  _ccseat_pg_glob "$sid" "subagents"
  files=$_PG_HITS
  [ -n "$files" ] || return 0
  set --
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    for a in "$p"/agent-*.jsonl; do [ -f "$a" ] && set -- "$@" "$a"; done
  done <<EOF
$files
EOF
  [ $# -gt 0 ] || return 0
  recent=""
  while read -r mt a; do
    case "$mt" in ''|*[!0-9]*) continue ;; esac
    idle=$(( _CCSEAT_PG_NOW - mt )); [ "$idle" -lt 0 ] && idle=0
    [ "$idle" -gt "$_CCSEAT_PG_SILENT" ] && continue
    [ -f "${a%.jsonl}.meta.json" ] || continue
    recent="$recent$mt $a"$'\n'
  done <<EOF
$(_ccseat_pg_mtimes "$@")
EOF
  [ -n "$recent" ] || return 0
  set --
  while read -r mt a; do [ -n "$a" ] && set -- "$@" "${a%.jsonl}.meta.json"; done <<EOF
$recent
EOF
  metas=$(jq -r '[input_filename | tostring | gsub("[\t\n\r\u001f]"; " ")]
      + ([.requestShape // "", .taskKind // "", .toolUseId // "", .description // "agent", .agentType // ""]
         | map(tostring | gsub("[\t\n\r]"; " ") | gsub("[[:cntrl:]]"; "")))
    | join("\u001f")' "$@" 2>/dev/null)
  transcripts=$(_ccseat_pg_transcripts "$sid")
  bgpat=""; fgpat=""
  while IFS=$_CCSEAT_PG_US read -r m shape tk tuid desc typ; do
    [ -n "$m" ] || continue
    id=${m##*/agent-}; id=${id%.meta.json}
    case "$id" in ''|*[!A-Za-z0-9_-]*) continue ;; esac
    if [ "$shape" = background ]; then bgpat="$bgpat<task-id>$id</task-id>"$'\n'
    elif [ -n "$tuid" ]; then fgpat="$fgpat\"tool_use_id\":\"$tuid\""$'\n'; fi
  done <<EOF
$metas
EOF
  finished=$'\n'
  if [ -n "$transcripts" ] && [ -n "$bgpat" ]; then
    finished="$finished$(_ccseat_pg_grep_all "$transcripts" "$bgpat" "<status>")"$'\n'
  fi
  if [ -n "$transcripts" ] && [ -n "$fgpat" ]; then
    finished="$finished$(_ccseat_pg_grep_all "$transcripts" "$fgpat" "")"$'\n'
  fi
  while IFS=$_CCSEAT_PG_US read -r m shape tk tuid desc typ; do
    [ -n "$m" ] || continue
    id=${m##*/agent-}; id=${id%.meta.json}
    case "$id" in ''|*[!A-Za-z0-9_-]*) continue ;; esac
    a="${m%.meta.json}.jsonl"
    mt=${recent%% "$a"$'\n'*}; mt=${mt##*$'\n'}
    case "$mt" in ''|*[!0-9]*) continue ;; esac
    idle=$(( _CCSEAT_PG_NOW - mt )); [ "$idle" -lt 0 ] && idle=0
    # A teammate waits for messages between jobs: busy only while it wrote in the last 2 min.
    [ "$tk" = in_process_teammate ] && [ "$idle" -gt "$_CCSEAT_PG_TEAMMATE_IDLE" ] && continue
    if [ "$shape" = background ]; then
      case "$finished" in *$'\n'"<task-id>$id</task-id>"$'\n'*) continue ;; esac
      kind="bg"
    else
      if [ -n "$tuid" ]; then
        case "$finished" in *$'\n'"\"tool_use_id\":\"$tuid\""$'\n'*) continue ;; esac
      fi
      kind="fg"
    fi
    if [ "$light" = 1 ]; then _pg_calls="-"; _pg_last="-"; _pg_age=0
    else _ccseat_pg_agent_stats "$a" "$m" "$mt"; fi
    printf 'A\t%s\t-\t%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$(_ccseat_pg_dash "$desc")" \
      "$(_ccseat_pg_dash "$typ")" "$_pg_calls" "$_pg_last" "$idle" "$_pg_age"
  done <<EOF
$metas
EOF
  return 0
}

_ccseat_pg_plural() { if [ "$1" -eq 1 ]; then printf '%s %s' "$1" "$2"; else printf '%s %ss' "$1" "$2"; fi; }

_ccseat_pg_ago() {
  if [ "$1" -lt 5 ]; then printf 'active now'
  elif [ "$1" -lt 60 ]; then printf 'active %s s ago' "$1"
  elif [ "$1" -lt 300 ]; then printf 'active %s min ago' $(( $1 / 60 ))
  else printf 'quiet for %s min' $(( $1 / 60 )); fi
}

_ccseat_pg_usage() {
  cat <<'EOF'
Usage: ccseat progress [--line | --tsv | --agents] [session_id]

Shows the workflows and agents still running in a Claude Code session. The
session defaults to $CLAUDE_CODE_SESSION_ID (set inside Claude Code); without
one, the readable view covers every session.

  (no option)   readable summary
  --line        one compact line, nothing when idle
  --tsv         one tab-separated row per running workflow: name, phase index,
                phase count, phase title, agents finished, agents started,
                agents running, agents failed, minutes since start, agents
                started in this phase, agents finished in this phase
  --agents      one tab-separated row per running agent: kind (wf, bg or fg),
                workflow name, label, agent type, tool calls, last tool, idle
                seconds, minutes alive
EOF
}

ccseat_progress_main() {
  local mode=text sid="" row kind name k n phase fin running failed mins tab=$'\t'
  local lab typ calls last idle age line="" out any=0
  # Read-only reporting: a failed probe must never end it early.
  set +e
  while [ $# -gt 0 ]; do
    case "$1" in
      --line) mode=line ;;
      --tsv) mode=tsv ;;
      --agents) mode=agents ;;
      -h|--help|help) _ccseat_pg_usage; return 0 ;;
      -*) printf 'ccseat: unknown option for progress: %s\n' "$1" >&2
          printf 'Run "ccseat progress --help" for the options.\n' >&2; return 2 ;;
      *) [ -z "$sid" ] || { printf 'ccseat: progress takes one session id\n' >&2; return 2; }
         sid=$1 ;;
    esac
    shift
  done
  [ -n "$sid" ] || sid=${CLAUDE_CODE_SESSION_ID:-}
  case "$sid" in *[!A-Za-z0-9_-]*)
    printf 'ccseat: not a session id: %s\n' "$sid" >&2; return 2 ;;
  esac
  command -v jq >/dev/null 2>&1 || { printf 'ccseat: progress needs jq\n' >&2; return 1; }
  # The machine formats serve one session; without one there is nothing to report.
  [ "$mode" != text ] && [ -z "$sid" ] && return 0
  _ccseat_pg_init

  case "$mode" in
    tsv)
      _ccseat_pg_collect "$sid" w | while IFS= read -r row; do printf '%s\n' "${row#W"$tab"}"; done
      return 0 ;;
    agents)
      _ccseat_pg_collect "$sid" a | while IFS= read -r row; do printf '%s\n' "${row#A"$tab"}"; done
      return 0 ;;
    line)
      while IFS=$'\t' read -r kind name k n phase fin _ running failed mins _; do
        [ "$kind" = W ] || continue
        [ "$phase" = "-" ] && phase=""
        row=$name
        if [ -n "$phase" ]; then
          if [ "$k" -gt 0 ] && [ "$n" -gt 1 ]; then row="$row · phase $k of $n ($phase)"
          else row="$row · $phase"; fi
        fi
        row="$row · $fin done, $running running"
        [ "$failed" -gt 0 ] && row="$row, $failed failed"
        line="${line:+$line   }$row · $mins min"
      done <<EOF
$(_ccseat_pg_collect "$sid" w)
EOF
      [ -n "$line" ] && printf '%s\n' "$line"
      return 0 ;;
  esac

  # Readable view.
  while IFS= read -r j; do
    [ -n "$j" ] || continue
    _ccseat_pg_run "$j" || continue
    any=1
    out="$_pg_name: "
    if [ "$_pg_k" -gt 0 ] && [ "$_pg_n" -gt 1 ]; then out="${out}phase $_pg_k of $_pg_n ($_pg_phase), "
    elif [ -n "$_pg_phase" ]; then out="${out}phase $_pg_phase, "; fi
    out="${out}$_pg_done of $_pg_started agents done"
    [ "$_pg_failed" -gt 0 ] && out="$out ($_pg_failed failed)"
    out="$out, $_pg_running running, $(_ccseat_pg_plural "$_pg_mins" minute) since start"
    printf '%s\n' "$out"
    if [ -n "$_pg_live" ]; then
      out=""
      while IFS=$_CCSEAT_PG_US read -r _ lab; do out="${out:+$out, }${lab:-agent}"; done <<EOF
$_pg_live
EOF
      printf '  running: %s\n' "$out"
    fi
    [ -n "$_pg_pending" ] && printf '  next phases: %s\n' "$_pg_pending"
  done <<EOF
$(_ccseat_pg_journals "$sid")
EOF
  if [ -n "$sid" ]; then
    while IFS=$'\t' read -r _ kind name lab typ calls last idle age; do
      [ "$kind" = bg ] || [ "$kind" = fg ] || continue
      any=1
      out="agent $lab"
      [ "$typ" != "-" ] && out="$out ($typ)"
      out="$out: $(_ccseat_pg_plural "$calls" "tool call")"
      [ "$last" != "-" ] && out="$out, last $last"
      out="$out, $(_ccseat_pg_ago "$idle"), $(_ccseat_pg_plural "$age" minute) since start"
      [ "$kind" = bg ] && out="$out, in the background"
      printf '%s\n' "$out"
    done <<EOF
$(_ccseat_pg_collect "$sid" a)
EOF
  fi
  if [ "$any" -eq 0 ]; then
    if [ -n "$sid" ]; then printf 'Nothing is running in this session.\n'
    else printf 'No workflow is running.\n'; fi
  fi
  return 0
}
