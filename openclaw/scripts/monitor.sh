#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTRY="$ROOT_DIR/registry/agents.json"
LOGS_DIR="$ROOT_DIR/logs"
RESTART_TMPL="$ROOT_DIR/prompts/restart.md.tmpl"

mkdir -p "$LOGS_DIR"
[[ -f "$REGISTRY" ]] || printf '{"agents":{}}\n' > "$REGISTRY"

json_update() {
  local tmp
  tmp="$(mktemp)"
  jq "$@" "$REGISTRY" > "$tmp"
  mv "$tmp" "$REGISTRY"
}

build_restart_prompt() {
  local task_id="$1"
  local retry="$2"
  local reason="$3"

  local task_desc acceptance addendum log_file log_tail out_file
  task_desc="$(jq -r --arg t "$task_id" '.agents[$t].task_description // "(не указано)"' "$REGISTRY")"
  acceptance="$(jq -r --arg t "$task_id" '.agents[$t].acceptance_criteria // "(не указано)"' "$REGISTRY")"
  addendum="$(jq -r --arg t "$task_id" '.agents[$t].restart_prompt_addendum // ""' "$REGISTRY")"
  log_file="$LOGS_DIR/agent-$task_id.log"
  log_tail="$(tail -n 50 "$log_file" 2>/dev/null || true)"
  out_file="/tmp/restart-$task_id.md"

  python3 - "$RESTART_TMPL" "$out_file" "$retry" "$task_desc" "$reason" "$log_tail" "$addendum" "$acceptance" <<'PY'
import sys
from pathlib import Path

template = Path(sys.argv[1]).read_text(encoding='utf-8')
out = Path(sys.argv[2])
values = {
    '{{RETRY_NUMBER}}': sys.argv[3],
    '{{TASK_DESCRIPTION}}': sys.argv[4],
    '{{FAILURE_REASON}}': sys.argv[5],
    '{{LOG_TAIL}}': sys.argv[6],
    '{{RESTART_ADDENDUM}}': sys.argv[7],
    '{{ACCEPTANCE_CRITERIA}}': sys.argv[8],
}
for k, v in values.items():
    template = template.replace(k, v)
out.write_text(template, encoding='utf-8')
print(str(out))
PY
}

full_restart() {
  local task_id="$1"
  local reason="$2"

  local retries agent repo next_retry
  retries="$(jq -r --arg t "$task_id" '.agents[$t].retries // 0' "$REGISTRY")"
  if (( retries >= 3 )); then
    json_update --arg t "$task_id" --arg r "$reason" '
      .agents[$t].status = "blocked" |
      .agents[$t].last_failure = $r
    '
    "$ROOT_DIR/scripts/notify-telegram.sh" "🚨 Агент $task_id требует внимания человека"
    return
  fi

  next_retry=$((retries + 1))
  json_update --arg t "$task_id" --arg r "$reason" --argjson nr "$next_retry" '
    .agents[$t].retries = $nr |
    .agents[$t].last_failure = $r |
    .agents[$t].status = "running"
  '

  local prompt_file
  prompt_file="$(build_restart_prompt "$task_id" "$next_retry" "$reason")"

  if tmux has-session -t "agent-$task_id" 2>/dev/null; then
    tmux kill-session -t "agent-$task_id"
  fi

  agent="$(jq -r --arg t "$task_id" '.agents[$t].agent' "$REGISTRY")"
  repo="$(jq -r --arg t "$task_id" '.agents[$t].repo' "$REGISTRY")"
  "$ROOT_DIR/scripts/spawn-agent.sh" "$task_id" "$agent" "$repo" "$prompt_file"
}

inject_context() {
  local task_id="$1"
  local message="$2"
  local retries
  retries="$(jq -r --arg t "$task_id" '.agents[$t].retries // 0' "$REGISTRY")"
  tmux send-keys -t "agent-$task_id" "$message" Enter
  json_update --arg t "$task_id" --arg m "$message" --argjson nr "$((retries + 1))" '
    .agents[$t].restart_prompt_addendum = $m |
    .agents[$t].retries = $nr
  '
}

mapfile -t TASK_IDS < <(jq -r '.agents | keys[]' "$REGISTRY")

for task_id in "${TASK_IDS[@]}"; do
  status="$(jq -r --arg t "$task_id" '.agents[$t].status' "$REGISTRY")"
  if [[ "$status" == "done" || "$status" == "blocked" || "$status" == "cancelled" ]]; then
    continue
  fi

  session_alive="yes"
  if ! tmux has-session -t "agent-$task_id" 2>/dev/null; then
    session_alive="no"
  fi

  if [[ "$session_alive" == "no" && "$status" == "running" ]]; then
    full_restart "$task_id" "tmux_session_dead"
    continue
  fi

  pr_json="$(gh pr list --head "agent/$task_id" --json number,state,url --jq '.[0]')"
  if [[ -z "$pr_json" || "$pr_json" == "null" ]]; then
    continue
  fi

  pr_number="$(jq -r '.number' <<<"$pr_json")"
  json_update --arg t "$task_id" --argjson p "$pr_number" '.agents[$t].pr_number = $p'

  checks="$(gh pr checks "$pr_number" --json name,state --jq '[.[] | {name,state}]')"
  if jq -e 'map(select(.state == "failure")) | length > 0' >/dev/null <<<"$checks"; then
    full_restart "$task_id" "ci_failure"
    continue
  fi

  if jq -e 'map(select(.state == "pending")) | length > 0' >/dev/null <<<"$checks"; then
    continue
  fi

  review_status="$(jq -r --arg t "$task_id" '.agents[$t].review_status' "$REGISTRY")"
  case "$review_status" in
    null)
      "$ROOT_DIR/scripts/review-pr.sh" "$pr_number" "$task_id" >/dev/null 2>&1 &
      json_update --arg t "$task_id" '.agents[$t].review_status = "pending"'
      ;;
    pending)
      ;;
    failed)
      if [[ "$session_alive" == "yes" ]]; then
        addendum="$(jq -r --arg t "$task_id" '.agents[$t].restart_prompt_addendum // ""' "$REGISTRY")"
        if [[ -n "$addendum" ]]; then
          inject_context "$task_id" "$addendum"
        else
          full_restart "$task_id" "review_failed"
        fi
      else
        full_restart "$task_id" "review_failed"
      fi
      ;;
    approved)
      if [[ "$(jq -r --arg t "$task_id" '.agents[$t].notify_on_complete // true' "$REGISTRY")" == "true" ]]; then
        "$ROOT_DIR/scripts/notify-telegram.sh" "✅ Агент $task_id завершил задачу. PR #$pr_number готов к ревью человеком"
      fi
      json_update --arg t "$task_id" '.agents[$t].status = "done"'
      ;;
  esac
done
