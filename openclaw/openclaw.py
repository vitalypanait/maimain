#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Dict

ROOT = Path(__file__).resolve().parent
REGISTRY_PATH = ROOT / "registry" / "agents.json"
PROMPTS_DIR = ROOT / "prompts"
SCRIPTS_DIR = ROOT / "scripts"
LOGS_DIR = ROOT / "logs"
DOCS_DIR = ROOT / "docs"


def ensure_layout() -> None:
    (ROOT / "registry").mkdir(parents=True, exist_ok=True)
    LOGS_DIR.mkdir(parents=True, exist_ok=True)
    (ROOT / "agents").mkdir(parents=True, exist_ok=True)
    DOCS_DIR.mkdir(parents=True, exist_ok=True)
    if not REGISTRY_PATH.exists():
        atomic_write_json(REGISTRY_PATH, {"agents": {}})


def load_registry() -> Dict[str, Any]:
    ensure_layout()
    try:
        return json.loads(REGISTRY_PATH.read_text(encoding="utf-8"))
    except Exception:
        return {"agents": {}}


def atomic_write_json(path: Path, payload: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", delete=False, dir=str(path.parent), encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
        f.write("\n")
        tmp_name = f.name
    os.replace(tmp_name, path)


def save_registry(registry: Dict[str, Any]) -> None:
    atomic_write_json(REGISTRY_PATH, registry)


def run_cmd(cmd: list[str], cwd: Path | None = None, check: bool = True) -> int:
    proc = subprocess.run(cmd, cwd=str(cwd) if cwd else None)
    if check and proc.returncode != 0:
        raise SystemExit(proc.returncode)
    return proc.returncode


def ask(prompt: str, default: str | None = None) -> str:
    suffix = f" [{default}]" if default else ""
    value = input(f"{prompt}{suffix}: ").strip()
    if not value and default is not None:
        return default
    return value


def ask_multiline(prompt: str) -> str:
    print(f"{prompt} (пустая строка завершает ввод):")
    lines: list[str] = []
    while True:
        line = input()
        if line == "":
            break
        lines.append(line)
    return "\n".join(lines).strip()


def render_template(template_path: Path, replacements: Dict[str, str]) -> str:
    text = template_path.read_text(encoding="utf-8")
    for key, value in replacements.items():
        text = text.replace(key, value)
    return text


def create_prompt_file(task_id: str, template_name: str, replacements: Dict[str, str]) -> Path:
    content = render_template(PROMPTS_DIR / template_name, replacements)
    prompt_path = Path(f"/tmp/prompt-{task_id}.md")
    prompt_path.write_text(content, encoding="utf-8")
    return prompt_path


def update_agent_metadata(task_id: str, **fields: Any) -> None:
    registry = load_registry()
    agent = registry.setdefault("agents", {}).setdefault(task_id, {})
    agent.update(fields)
    save_registry(registry)


def cmd_run(args: argparse.Namespace) -> None:
    ensure_layout()
    task_id = f"task-{int(time.time())}"

    files_to_focus = ask("Файлы/директории для работы", ".")
    files_not_to_touch = ask("Файлы, которые нельзя трогать", "-")
    agent_type = ask("Тип агента (claude|codex)", "claude")
    repo = ask("Имя репозитория", ROOT.name)
    acceptance = ask_multiline("Критерии приёмки")
    business_context = ask_multiline("Бизнес-контекст")

    prompt_path = create_prompt_file(
        task_id,
        "agent.md.tmpl",
        {
            "{{TASK_DESCRIPTION}}": args.task,
            "{{TASK_ID}}": task_id,
            "{{FILES_TO_FOCUS}}": files_to_focus,
            "{{FILES_NOT_TO_TOUCH}}": files_not_to_touch,
            "{{BUSINESS_CONTEXT}}": business_context or "(не указан)",
            "{{ACCEPTANCE_CRITERIA}}": acceptance or "(не указаны)",
        },
    )

    if args.plan_first:
        print("--plan-first включён: сначала запускаю архитектурного агента...")
        plan_id = f"plan-{int(time.time())}"
        plan_prompt = create_prompt_file(
            plan_id,
            "architect.md.tmpl",
            {
                "{{TASK_DESCRIPTION}}": args.task,
                "{{TASK_ID}}": plan_id,
                "{{FILES_TO_FOCUS}}": files_to_focus,
                "{{BUSINESS_CONTEXT}}": business_context or "(не указан)",
            },
        )
        run_cmd([str(SCRIPTS_DIR / "spawn-agent.sh"), plan_id, agent_type, repo, str(plan_prompt)], cwd=ROOT)
        update_agent_metadata(
            plan_id,
            task_description=f"Architecture planning: {args.task}",
            acceptance_criteria="Создан architecture doc + PR",
            business_context=business_context,
            files_to_focus=files_to_focus,
            files_not_to_touch="-",
        )
        print(f"Архитектурный агент {plan_id} запущен. После мержа его PR запусти openclaw run без --plan-first для исполнения.")
        return

    run_cmd([str(SCRIPTS_DIR / "spawn-agent.sh"), task_id, agent_type, repo, str(prompt_path)], cwd=ROOT)
    update_agent_metadata(
        task_id,
        task_description=args.task,
        acceptance_criteria=acceptance,
        business_context=business_context,
        files_to_focus=files_to_focus,
        files_not_to_touch=files_not_to_touch,
    )
    print(f"Агент {task_id} запущен. Мониторинг: python3 {ROOT / 'openclaw.py'} status")


def cmd_plan(args: argparse.Namespace) -> None:
    ensure_layout()
    task_id = f"plan-{int(time.time())}"

    files_to_focus = ask("Файлы/директории для анализа", ".")
    agent_type = ask("Тип агента (claude|codex)", "claude")
    repo = ask("Имя репозитория", ROOT.name)
    business_context = ask_multiline("Бизнес-контекст")

    prompt_path = create_prompt_file(
        task_id,
        "architect.md.tmpl",
        {
            "{{TASK_DESCRIPTION}}": args.task,
            "{{TASK_ID}}": task_id,
            "{{FILES_TO_FOCUS}}": files_to_focus,
            "{{BUSINESS_CONTEXT}}": business_context or "(не указан)",
        },
    )

    run_cmd([str(SCRIPTS_DIR / "spawn-agent.sh"), task_id, agent_type, repo, str(prompt_path)], cwd=ROOT)
    update_agent_metadata(
        task_id,
        task_description=f"Architecture planning: {args.task}",
        acceptance_criteria=f"docs/architecture-{task_id}.md создан и PR открыт",
        business_context=business_context,
        files_to_focus=files_to_focus,
        files_not_to_touch="-",
    )
    print(f"Архитектурный агент {task_id} запущен. Результат появится в docs/architecture-{task_id}.md")


def cmd_status(_: argparse.Namespace) -> None:
    registry = load_registry()
    agents = registry.get("agents", {})
    print("TASK-ID\tСТАТУС\tПОПЫТКИ\tPR\tCI")
    for task_id, data in agents.items():
        pr = data.get("pr_number")
        pr_label = f"#{pr}" if pr else "-"
        review = data.get("review_status")
        if review == "approved":
            ci = "✅"
        elif review == "failed":
            ci = "❌"
        elif review == "pending":
            ci = "⏳"
        else:
            ci = "-"
        print(f"{task_id}\t{data.get('status','-')}\t{data.get('retries',0)}\t{pr_label}\t{ci}")


def cmd_logs(args: argparse.Namespace) -> None:
    log_file = LOGS_DIR / f"agent-{args.task_id}.log"
    if not log_file.exists():
        raise SystemExit(f"Лог не найден: {log_file}")
    os.execvp("tail", ["tail", "-f", str(log_file)])


def cmd_kill(args: argparse.Namespace) -> None:
    session = f"agent-{args.task_id}"
    subprocess.run(["tmux", "kill-session", "-t", session], check=False)
    registry = load_registry()
    if args.task_id in registry.get("agents", {}):
        registry["agents"][args.task_id]["status"] = "cancelled"
        save_registry(registry)
    print(f"Агент {args.task_id} остановлен")


def cmd_install_cron(_: argparse.Namespace) -> None:
    monitor = ROOT / "scripts" / "monitor.sh"
    log_file = ROOT / "logs" / "monitor.log"
    line = f"*/10 * * * * {monitor} >> {log_file} 2>&1"

    current = subprocess.run(["crontab", "-l"], capture_output=True, text=True)
    existing = current.stdout if current.returncode == 0 else ""
    lines = [l for l in existing.splitlines() if l.strip()]
    if line not in lines:
      lines.append(line)
    payload = "\n".join(lines) + "\n"
    proc = subprocess.run(["crontab", "-"], input=payload, text=True)
    if proc.returncode != 0:
        raise SystemExit(proc.returncode)
    print("Cron установлен:")
    print(line)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="openclaw — shell-based оркестрация AI-агентов")
    sub = parser.add_subparsers(dest="command", required=True)

    run_p = sub.add_parser("run", help='Запустить исполняющего агента')
    run_p.add_argument("task", help="Описание задачи")
    run_p.add_argument("--plan-first", action="store_true", help="Сначала запустить архитектурный план")
    run_p.set_defaults(func=cmd_run)

    plan_p = sub.add_parser("plan", help='Запустить архитектурного агента')
    plan_p.add_argument("task", help="Описание задачи")
    plan_p.set_defaults(func=cmd_plan)

    status_p = sub.add_parser("status", help="Показать состояние агентов")
    status_p.set_defaults(func=cmd_status)

    logs_p = sub.add_parser("logs", help="Хвост логов агента")
    logs_p.add_argument("task_id")
    logs_p.set_defaults(func=cmd_logs)

    kill_p = sub.add_parser("kill", help="Остановить агента")
    kill_p.add_argument("task_id")
    kill_p.set_defaults(func=cmd_kill)

    cron_p = sub.add_parser("install-cron", help="Установить cron для monitor.sh")
    cron_p.set_defaults(func=cmd_install_cron)

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
