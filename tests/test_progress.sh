# shellcheck shell=bash
# "ccseat progress": workflows and agents running in a Claude Code session,
# read from fixture session files.

tsv_field() { printf '%s\n' "$OUT" | head -1 | cut -f"$1"; }

test_progress_tsv() {
  make_workflow_fixture sess-1 wf_abc ship
  cs_ok progress --tsv sess-1
  assert_eq 1 "$(printf '%s\n' "$OUT" | grep -c .)" "one running workflow"
  assert_eq ship "$(tsv_field 1)" "name from the script file"
  assert_eq 2 "$(tsv_field 2)" "phase index"
  assert_eq 3 "$(tsv_field 3)" "phase count"
  assert_eq Build "$(tsv_field 4)" "phase title"
  assert_eq 1 "$(tsv_field 5)" "agents finished"
  assert_eq 2 "$(tsv_field 6)" "agents started"
  assert_eq 1 "$(tsv_field 7)" "agents running"
  assert_eq 0 "$(tsv_field 8)" "agents failed"
  assert_match "$(tsv_field 9)" '^[0-9]+$' "minutes since start"
  assert_eq 2 "$(tsv_field 10)" "started in this phase"
  assert_eq 1 "$(tsv_field 11)" "finished in this phase"
}

test_progress_line() {
  make_workflow_fixture sess-1 wf_abc ship
  cs_ok progress --line sess-1
  assert_contains "$OUT" "ship"
  assert_contains "$OUT" "phase 2 of 3 (Build)"
  assert_contains "$OUT" "1 done, 1 running"
  assert_eq 1 "$(printf '%s\n' "$OUT" | grep -c .)" "one line"
}

test_progress_agents() {
  make_workflow_fixture sess-1 wf_abc ship
  make_background_agent "$WF_SESSION_DIR" bg1 "Research the API"
  cs_ok progress --agents sess-1
  assert_match "$OUT" $'^wf\tship\ttests\tgeneral-purpose\t' "the running workflow agent"
  assert_not_contains "$OUT" $'\tcore\t' "finished agents are not listed"
  assert_match "$OUT" $'^bg\t-\tResearch the API\tExplore\t' "the background agent"
}

test_progress_readable_summary() {
  make_workflow_fixture sess-1 wf_abc ship
  cs_ok progress sess-1
  assert_contains "$OUT" "ship"
  assert_contains "$OUT" "phase 2 of 3"
  assert_contains "$OUT" "tests"
}

test_progress_uses_the_session_env() {
  make_workflow_fixture sess-1 wf_abc ship
  CLAUDE_CODE_SESSION_ID=sess-1 run ccseat progress --tsv
  assert_success
  assert_eq ship "$(tsv_field 1)"
}

test_progress_ignores_finished_runs() {
  make_workflow_fixture sess-1 wf_abc ship
  printf '{"status":"completed"}\n' > "$WF_SESSION_DIR/workflows/wf_abc.json"
  cs_ok progress --tsv sess-1
  assert_eq "" "$OUT"
  cs_ok progress --line sess-1
  assert_eq "" "$OUT" "--line prints nothing when idle"
}

test_progress_ignores_abandoned_runs() {
  make_workflow_fixture sess-1 wf_abc ship
  set_age "$WF_RUN_DIR/journal.jsonl" $((7 * 3600))
  cs_ok progress --tsv sess-1
  assert_eq "" "$OUT" "a journal quiet for over 6 hours is abandoned"
}

test_progress_counts_failures() {
  make_workflow_fixture sess-1 wf_abc ship
  printf '{"type":"failed","key":"tests","agentId":"a2"}\n' >> "$WF_RUN_DIR/journal.jsonl"
  cs_ok progress --tsv sess-1
  assert_eq 2 "$(tsv_field 5)" "finished includes the failure"
  assert_eq 0 "$(tsv_field 7)" "nothing running"
  assert_eq 1 "$(tsv_field 8)" "one failed"
  cs_ok progress --line sess-1
  assert_contains "$OUT" "1 failed"
}

test_progress_retry_is_not_double_counted() {
  make_workflow_fixture sess-1 wf_abc ship
  # "tests" is retried with a new agent id; the old attempt's result does not finish it.
  printf '{"type":"started","key":"tests","agentId":"a3","label":"tests","phase":"Build"}\n' >> "$WF_RUN_DIR/journal.jsonl"
  printf '{"type":"result","key":"tests","agentId":"a2"}\n' >> "$WF_RUN_DIR/journal.jsonl"
  cs_ok progress --tsv sess-1
  assert_eq 2 "$(tsv_field 6)" "still two agents"
  assert_eq 1 "$(tsv_field 7)" "the retry is still running"
}

test_progress_finds_sessions_of_other_seats() {
  make_primary alice@example.com
  add_seat bob@example.com
  # projects/ is shared, so a session written through bob's dir lands in the primary.
  make_workflow_fixture sess-2 wf_def deploy "$(seat_dir bob)/projects"
  CLAUDE_CONFIG_DIR="$(seat_dir bob)" run ccseat progress --tsv sess-2
  assert_success
  assert_eq deploy "$(tsv_field 1)"
  run ccseat progress --tsv sess-2
  assert_eq deploy "$(tsv_field 1)" "found from the primary too"
}

test_progress_background_agent_finishes() {
  make_workflow_fixture sess-1 wf_abc ship
  make_background_agent "$WF_SESSION_DIR" bg1 "Research the API"
  printf '{"type":"user","message":{"content":"<task-notification><task-id>bg1</task-id><status>completed</status></task-notification>"}}\n' > "$(dirname "$WF_SESSION_DIR")/sess-1.jsonl"
  cs_ok progress --agents sess-1
  assert_not_contains "$OUT" "Research the API" "a finished background agent is gone"
}

test_progress_without_a_session_is_quiet() {
  cs_ok progress --tsv
  assert_eq "" "$OUT"
  cs_ok progress --line nosuch
  assert_eq "" "$OUT"
  cs_ok progress --agents nosuch
  assert_eq "" "$OUT"
}

test_progress_rejects_odd_session_ids() {
  make_workflow_fixture sess-1 wf_abc ship
  cs progress --tsv "../sess-1"
  assert_eq "" "$OUT" "path-like ids are refused"
}
