# openclaw

Shell-based система оркестрации AI-агентов для параллельной разработки через изолированные git worktree + tmux.

> Текущее состояние: оркестрация пока работает через модель `openai-codex/gpt-5.3-codex`.

## Зависимости

Нужны в PATH:
- `claude`
- `gh`
- `tmux`
- `jq`
- `python3`
- `pnpm` (если в worktree есть `package.json`)

## Установка

```bash
cd openclaw
cp .env.example .env
# Заполни OPENAI_API_KEY, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
python3 openclaw.py install-cron
```

## Использование

```bash
python3 openclaw.py run "добавить тёмную тему на страницу настроек"
```

При запуске `run/plan` обязательно укажи:
- **путь к директории кода** (целевой git-репозиторий),
- **путь к директории плана** (где хранить architecture/project docs).

Это и есть Вариант B (оркестратор отдельно, код проекта отдельно).

Дополнительно:

```bash
python3 openclaw.py plan "добавить платёжный модуль"
python3 openclaw.py status
python3 openclaw.py logs <task-id>
python3 openclaw.py kill <task-id>
python3 openclaw.py cleanup
```

`run` поддерживает:

```bash
python3 openclaw.py run "добавить платёжный модуль" --plan-first
```

## Как работает цикл мониторинга

`scripts/monitor.sh` — детерминированный цикл без вызовов LLM:
1. Проверяет, жива ли tmux-сессия агента.
2. Проверяет наличие PR (`gh pr list --head agent/<task-id>`).
3. Проверяет CI (`gh pr checks`).
4. Проверяет `review_status` в `registry/agents.json`.
5. Запускает `review-pr.sh` или завершает задачу, уведомляя в Telegram.

Источник истины — `registry/agents.json`.

## Шаг 8: Merge + cleanup

- После мержа PR ежедневный cron запускает `scripts/cleanup.sh`.
- `cleanup.sh` удаляет:
  - осиротевшие worktree у терминальных задач (`done/blocked/cancelled`),
  - записи из `registry/agents.json`, если ветка задачи уже влита в `main`.
- Ручной запуск: `python3 openclaw.py cleanup`.

## Как работает Цикл Ральфа V2

Адаптивный перезапуск с контекстом:

- **Режим A (инъекция):** если tmux жива, монитор может отправить конкретный контекст в текущую сессию агента через `tmux send-keys`.
- **Режим B (полный рестарт):** если сессия умерла, CI упал, или ревью провалено — создаётся новый restart-промпт из:
  - оригинальной задачи,
  - причины сбоя,
  - последних 50 строк лога,
  - `restart_prompt_addendum`.

После этого агент спаунится заново в ту же ветку (`agent/<task-id>`). После 3 попыток задача помечается `blocked` и отправляется Telegram-уведомление.

## Структура

```text
openclaw/
├── registry/agents.json
├── logs/
├── prompts/
│   ├── agent.md.tmpl
│   ├── architect.md.tmpl
│   └── restart.md.tmpl
├── scripts/
│   ├── run-agent.sh
│   ├── spawn-agent.sh
│   ├── monitor.sh
│   ├── review-pr.sh
│   └── notify-telegram.sh
├── docs/
├── openclaw.py
├── .env.example
└── README.md
```
