#!/usr/bin/env bash
set -euo pipefail

# macOS cron often has a minimal PATH; include common Homebrew/bin locations.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTRY="$ROOT_DIR/registry/agents.json"

[[ -f "$REGISTRY" ]] || printf '{"agents":{}}\n' > "$REGISTRY"

json_update() {
  local tmp
  tmp="$(mktemp)"
  jq "$@" "$REGISTRY" > "$tmp"
  mv "$tmp" "$REGISTRY"
}

is_terminal_status() {
  case "$1" in
    done|blocked|cancelled) return 0 ;;
    *) return 1 ;;
  esac
}

is_branch_merged() {
  local repo_path="$1"
  local branch="$2"

  [[ -n "$repo_path" && -n "$branch" ]] || return 1
  git -C "$repo_path" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1

  local base_ref=""
  if git -C "$repo_path" show-ref --verify --quiet refs/remotes/origin/main; then
    base_ref="origin/main"
  elif git -C "$repo_path" show-ref --verify --quiet refs/heads/main; then
    base_ref="main"
  elif git -C "$repo_path" show-ref --verify --quiet refs/heads/master; then
    base_ref="master"
  else
    return 1
  fi

  git -C "$repo_path" branch --merged "$base_ref" --format='%(refname:short)' | grep -Fxq "$branch"
}

worktree_registered() {
  local repo_path="$1"
  local worktree_path="$2"
  [[ -n "$repo_path" && -n "$worktree_path" ]] || return 1
  git -C "$repo_path" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  git -C "$repo_path" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10)}' | grep -Fxq "$worktree_path"
}

removed=0
kept=0

mapfile -t TASK_IDS < <(jq -r '.agents | keys[]' "$REGISTRY")

for task_id in "${TASK_IDS[@]}"; do
  status="$(jq -r --arg t "$task_id" '.agents[$t].status // ""' "$REGISTRY")"
  branch="$(jq -r --arg t "$task_id" '.agents[$t].branch // ""' "$REGISTRY")"
  repo_path="$(jq -r --arg t "$task_id" '.agents[$t].repo_path // ""' "$REGISTRY")"
  worktree_path="$(jq -r --arg t "$task_id" '.agents[$t].worktree // ""' "$REGISTRY")"

  merged=false
  orphan=false

  if is_branch_merged "$repo_path" "$branch"; then
    merged=true
  fi

  if [[ -z "$worktree_path" || ! -d "$worktree_path" ]]; then
    orphan=true
  elif ! worktree_registered "$repo_path" "$worktree_path"; then
    orphan=true
  fi

  should_cleanup=false
  if [[ "$merged" == true ]]; then
    should_cleanup=true
  elif is_terminal_status "$status" && [[ "$orphan" == true ]]; then
    should_cleanup=true
  fi

  if [[ "$should_cleanup" != true ]]; then
    kept=$((kept + 1))
    continue
  fi

  if [[ -n "$repo_path" && -n "$worktree_path" ]] && worktree_registered "$repo_path" "$worktree_path"; then
    git -C "$repo_path" worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
  elif [[ -n "$worktree_path" && -d "$worktree_path" ]]; then
    rm -rf "$worktree_path"
  fi

  if [[ -n "$repo_path" && -n "$branch" ]]; then
    git -C "$repo_path" branch -D "$branch" >/dev/null 2>&1 || true
  fi

  json_update --arg t "$task_id" 'del(.agents[$t])'
  removed=$((removed + 1))
done

if (( removed > 0 )); then
  "$ROOT_DIR/scripts/notify-telegram.sh" "🧹 Cleanup: удалено задач из registry: $removed (оставлено: $kept)"
fi

echo "cleanup complete: removed=$removed kept=$kept"
