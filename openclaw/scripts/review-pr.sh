#!/usr/bin/env bash
set -euo pipefail

PR_NUMBER="${1:-}"
TASK_ID="${2:-}"

if [[ -z "$PR_NUMBER" || -z "$TASK_ID" ]]; then
  echo "Usage: $0 <pr-number> <task-id>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTRY="$ROOT_DIR/registry/agents.json"

DIFF_CONTENT="$(gh pr diff "$PR_NUMBER")"
ACCEPTANCE_CRITERIA="$(jq -r --arg task "$TASK_ID" '.agents[$task].acceptance_criteria // "(не указаны)"' "$REGISTRY")"

CODEX_REVIEW="OPENAI_API_KEY не задан, ревью Codex пропущено."
if [[ -n "${OPENAI_API_KEY:-}" ]]; then
  SYSTEM_PROMPT="Ты дотошный ревьюер кода. Фокус: граничные случаи, отсутствующая обработка ошибок, состояния гонки, уязвимости безопасности. Будь лаконичен. Блокирующие проблемы помечай префиксом CRITICAL:"
  USER_PROMPT="Проверь этот PR.\n\nКритерии приёмки:\n${ACCEPTANCE_CRITERIA}\n\nDiff:\n${DIFF_CONTENT}"
  OPENAI_PAYLOAD="$(jq -n --arg sys "$SYSTEM_PROMPT" --arg usr "$USER_PROMPT" '{model:"o4-mini",messages:[{role:"system",content:$sys},{role:"user",content:$usr}]}' )"
  CODEX_REVIEW="$(curl -s https://api.openai.com/v1/chat/completions \
    -H "Authorization: Bearer ${OPENAI_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$OPENAI_PAYLOAD" | jq -r '.choices[0].message.content // "Не удалось получить ревью от Codex"')"
fi

CLAUDE_REVIEW="CLI claude не найден, ревью Claude пропущено."
if command -v claude >/dev/null 2>&1; then
  CLAUDE_REVIEW="$(claude -p "Проверь PR #${PR_NUMBER}. Diff:\n${DIFF_CONTENT}\n\nОтмечай только те проблемы, в которых уверен. Блокирующие помечай префиксом CRITICAL:" || true)"
  [[ -n "$CLAUDE_REVIEW" ]] || CLAUDE_REVIEW="Claude не вернул текст ревью."
fi

gh pr comment "$PR_NUMBER" --body "### Codex Review\n\n${CODEX_REVIEW}"
gh pr comment "$PR_NUMBER" --body "### Claude Review\n\n${CLAUDE_REVIEW}"

CRITICAL_LINES="$(printf "%s\n%s\n" "$CODEX_REVIEW" "$CLAUDE_REVIEW" | grep -E '^CRITICAL:' || true)"
TMP_JSON="$(mktemp)"
if [[ -n "$CRITICAL_LINES" ]]; then
  jq --arg task "$TASK_ID" --arg crit "$CRITICAL_LINES" '
    .agents[$task].review_status = "failed" |
    .agents[$task].restart_prompt_addendum = $crit |
    .agents[$task].last_failure = "critical_review_findings"
  ' "$REGISTRY" > "$TMP_JSON"
else
  jq --arg task "$TASK_ID" '
    .agents[$task].review_status = "approved" |
    .agents[$task].restart_prompt_addendum = null
  ' "$REGISTRY" > "$TMP_JSON"
fi
mv "$TMP_JSON" "$REGISTRY"
