#!/usr/bin/env bash
set -euo pipefail

AGENT_TYPE="${1:-}"
PROMPT_FILE="${2:-}"

if [[ -z "$AGENT_TYPE" || -z "$PROMPT_FILE" ]]; then
  echo "Usage: $0 <agent-type> <prompt-file>" >&2
  exit 1
fi

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "Prompt file not found: $PROMPT_FILE" >&2
  exit 1
fi

case "$AGENT_TYPE" in
  claude)
    claude --model claude-opus-4-5 \
      --dangerously-skip-permissions \
      -p "$(cat "$PROMPT_FILE")"
    ;;
  codex)
    codex --model gpt-4o \
      -c "model_reasoning_effort=high" \
      --dangerously-bypass-approvals-and-sandbox \
      "$(cat "$PROMPT_FILE")"
    ;;
  *)
    echo "Неизвестный тип агента: $AGENT_TYPE" >&2
    exit 1
    ;;
esac
