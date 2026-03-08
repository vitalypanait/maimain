#!/usr/bin/env bash
set -euo pipefail

TASK_ID="${1:-}"
AGENT_TYPE="${2:-}"
REPO_NAME="${3:-}"
PROMPT_FILE="${4:-}"

if [[ -z "$TASK_ID" || -z "$AGENT_TYPE" || -z "$REPO_NAME" || -z "$PROMPT_FILE" ]]; then
  echo "Usage: $0 <task-id> <agent-type> <repo> <prompt-file>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTRY="$ROOT_DIR/registry/agents.json"
LOGS_DIR="$ROOT_DIR/logs"
WORKTREE_PATH="$ROOT_DIR/agents/$TASK_ID"
BRANCH="agent/$TASK_ID"
SESSION_NAME="agent-$TASK_ID"
LOG_FILE="$LOGS_DIR/agent-$TASK_ID.log"
RUN_SCRIPT="$ROOT_DIR/scripts/run-agent.sh"
PROMPT_ABS="$(python3 -c 'import os,sys;print(os.path.abspath(sys.argv[1]))' "$PROMPT_FILE")"

mkdir -p "$ROOT_DIR/registry" "$LOGS_DIR" "$ROOT_DIR/agents"
[[ -f "$REGISTRY" ]] || printf '{"agents":{}}\n' > "$REGISTRY"

if [[ ! -d "$ROOT_DIR/.git" ]]; then
  git -C "$ROOT_DIR" init >/dev/null
fi

BASE_REF=""
if git -C "$ROOT_DIR" show-ref --verify --quiet refs/remotes/origin/main; then
  BASE_REF="origin/main"
elif git -C "$ROOT_DIR" show-ref --verify --quiet refs/heads/main; then
  BASE_REF="main"
elif git -C "$ROOT_DIR" show-ref --verify --quiet refs/heads/master; then
  BASE_REF="master"
else
  BASE_REF="HEAD"
fi

if [[ -e "$WORKTREE_PATH" ]]; then
  echo "Worktree already exists: $WORKTREE_PATH" >&2
  exit 1
fi

git -C "$ROOT_DIR" worktree add "$WORKTREE_PATH" -b "$BRANCH" "$BASE_REF"

if [[ -f "$WORKTREE_PATH/package.json" ]]; then
  (cd "$WORKTREE_PATH" && pnpm install)
fi

NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
TMP_JSON="$(mktemp)"

jq \
  --arg task "$TASK_ID" \
  --arg branch "$BRANCH" \
  --arg agent "$AGENT_TYPE" \
  --arg repo "$REPO_NAME" \
  --arg worktree "agents/$TASK_ID" \
  --arg created_at "$NOW_ISO" \
  '.agents[$task] = {
    branch: $branch,
    status: "running",
    agent: $agent,
    repo: $repo,
    worktree: $worktree,
    retries: 0,
    pr_number: null,
    review_status: null,
    created_at: $created_at,
    last_failure: null,
    restart_prompt_addendum: null,
    notify_on_complete: true,
    task_description: null,
    acceptance_criteria: null,
    business_context: null,
    files_to_focus: null,
    files_not_to_touch: null
  }' "$REGISTRY" > "$TMP_JSON"
mv "$TMP_JSON" "$REGISTRY"

if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  tmux kill-session -t "$SESSION_NAME"
fi

TMUX_CMD="script -f '$LOG_FILE' -c '$RUN_SCRIPT $AGENT_TYPE $PROMPT_ABS'"
tmux new-session -d -s "$SESSION_NAME" -c "$WORKTREE_PATH" "$TMUX_CMD"

echo "Agent $TASK_ID spawned in $WORKTREE_PATH"
