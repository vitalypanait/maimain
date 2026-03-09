#!/usr/bin/env bash
set -euo pipefail

FILE_PATH="${1:-}"
CAPTION="${2:-}"

if [[ -z "$FILE_PATH" ]]; then
  echo "Usage: $0 <file_path> [caption]" >&2
  exit 1
fi

if [[ ! -f "$FILE_PATH" ]]; then
  echo "Файл не найден: $FILE_PATH" >&2
  exit 1
fi

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
  echo "TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID не заданы, отправка документа пропущена" >&2
  exit 0
fi

curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
  -F "chat_id=${TELEGRAM_CHAT_ID}" \
  -F "caption=${CAPTION}" \
  -F "document=@${FILE_PATH}" >/dev/null
