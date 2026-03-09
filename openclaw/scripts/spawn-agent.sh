#!/usr/bin/env bash
set -euo pipefail

TASK_ID="${1:-}"
AGENT_TYPE="${2:-}"
REPO_NAME="${3:-}"
PROMPT_FILE="${4:-}"
TARGET_REPO_PATH="${5:-}"

if [[ -z "$TASK_ID" || -z "$AGENT_TYPE" || -z "$REPO_NAME" || -z "$PROMPT_FILE" ]]; then
  echo "Usage: $0 <task-id> <agent-type> <repo> <prompt-file> [target-repo-path]" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTRY="$ROOT_DIR/registry/agents.json"
LOGS_DIR="$ROOT_DIR/logs"
BRANCH="agent/$TASK_ID"
SESSION_NAME="agent-$TASK_ID"
LOG_FILE="$LOGS_DIR/agent-$TASK_ID.log"
RUN_SCRIPT="$ROOT_DIR/scripts/run-agent.sh"
PROMPT_ABS="$(python3 -c 'import os,sys;print(os.path.abspath(sys.argv[1]))' "$PROMPT_FILE")"

if [[ -z "$TARGET_REPO_PATH" ]]; then
  TARGET_REPO_PATH="$ROOT_DIR"
fi
TARGET_REPO_PATH="$(python3 -c 'import os,sys;print(os.path.abspath(sys.argv[1]))' "$TARGET_REPO_PATH")"
WORKTREE_PATH="$ROOT_DIR/agents/$TASK_ID"

mkdir -p "$ROOT_DIR/registry" "$LOGS_DIR" "$ROOT_DIR/agents"
[[ -f "$REGISTRY" ]] || printf '{"agents":{}}\n' > "$REGISTRY"

mkdir -p "$TARGET_REPO_PATH"
if [[ ! -d "$TARGET_REPO_PATH/.git" ]]; then
  git -C "$TARGET_REPO_PATH" init >/dev/null
fi

if ! git -C "$TARGET_REPO_PATH" rev-parse --verify HEAD >/dev/null 2>&1; then
  git -C "$TARGET_REPO_PATH" commit --allow-empty -m "chore: initialize repository for openclaw" >/dev/null
fi

BASE_REF=""
if git -C "$TARGET_REPO_PATH" show-ref --verify --quiet refs/remotes/origin/main; then
  BASE_REF="origin/main"
elif git -C "$TARGET_REPO_PATH" show-ref --verify --quiet refs/heads/main; then
  BASE_REF="main"
elif git -C "$TARGET_REPO_PATH" show-ref --verify --quiet refs/remotes/origin/master; then
  BASE_REF="origin/master"
elif git -C "$TARGET_REPO_PATH" show-ref --verify --quiet refs/heads/master; then
  BASE_REF="master"
else
  echo "Не найдена базовая ветка main/master (локально или в origin). Создай main/master перед запуском оркестратора." >&2
  exit 1
fi

if [[ -e "$WORKTREE_PATH" ]]; then
  echo "Worktree already exists: $WORKTREE_PATH" >&2
  exit 1
fi

git -C "$TARGET_REPO_PATH" worktree add "$WORKTREE_PATH" -b "$BRANCH" "$BASE_REF"

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
  --arg worktree "$WORKTREE_PATH" \
  --arg created_at "$NOW_ISO" \
  --arg repo_path "$TARGET_REPO_PATH" \
  '.agents[$task] = {
    branch: $branch,
    status: "running",
    agent: $agent,
    repo: $repo,
    repo_path: $repo_path,
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

TMUX_CMD="script -q '$LOG_FILE' '$RUN_SCRIPT' '$AGENT_TYPE' '$PROMPT_ABS'"
tmux new-session -d -s "$SESSION_NAME" -c "$WORKTREE_PATH" "bash -lc \"$TMUX_CMD\""

echo "Agent $TASK_ID spawned in $WORKTREE_PATH (repo: $TARGET_REPO_PATH)"
