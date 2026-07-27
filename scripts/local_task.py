from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

from .local_task_store import AddTask, LedgerError, NoteTask, TransitionTask, find_task, load_ledger, parse_priority, render_ledger, write_request

USAGE = "usage: local-task.py [--ledger PATH] add|list|show|note|start|block|done|cancel|render"


def parse_options(arguments: list[str], allowed: set[str]) -> dict[str, list[str]]:
    options: dict[str, list[str]] = {}
    position = 0
    while position < len(arguments):
        option = arguments[position]
        if option not in allowed or position + 1 >= len(arguments):
            raise LedgerError(f"invalid option: {option}")
        options.setdefault(option.removeprefix("--"), []).append(arguments[position + 1])
        position += 2
    return options


def option_value(options: dict[str, list[str]], name: str, required: bool = False) -> str:
    values = options.get(name, [])
    if required and (len(values) != 1 or not values[0].strip()):
        raise LedgerError(f"{name} is required")
    if len(values) > 1 and name != "acceptance":
        raise LedgerError(f"{name} may appear only once")
    return values[0] if values else ""


def sync_tracker(path: Path) -> bool:
    if os.environ.get("LOCAL_TASK_SKIP_TRACKER_SYNC") == "1":
        return True
    script = Path(os.environ.get("LOCAL_TASK_SYNC_SCRIPT", str(Path(__file__).with_name("sync-dev-tracker.sh"))))
    environment = os.environ.copy()
    environment["TASK_LEDGER_PATH"] = str(path)
    if subprocess.run(["bash", str(script)], env=environment, check=False).returncode != 0:
        print("warning: ledger mutation succeeded but tracker sync failed", file=sys.stderr)
        return False
    return True


def ledger_and_command(arguments: list[str]) -> tuple[Path, list[str]]:
    default_path = Path(os.environ.get("LOCAL_TASK_LEDGER_PATH", ".local/task-ledger.json"))
    match arguments:
        case ["--ledger", ledger_name, *remaining]:
            return Path(ledger_name), remaining
        case ["--ledger"]:
            raise LedgerError("--ledger requires a path")
        case _:
            return default_path, arguments


def run(arguments: list[str]) -> int:
    path, command = ledger_and_command(arguments)
    match command:
        case ["--help"] | ["-h"]:
            print(USAGE)
            return 0
        case ["list"]:
            print("\n".join(f"{task['id']} {task['status']} [{task['priority']}] {task['title']}" for task in load_ledger(path)["tasks"]))
            return 0
        case ["show", task_id]:
            print(json.dumps(find_task(load_ledger(path), task_id), ensure_ascii=True, indent=2, sort_keys=True))
            return 0
        case ["render"]:
            print(render_ledger(load_ledger(path)))
            return 0
        case ["add", title, *raw_options]:
            options = parse_options(raw_options, {"--priority", "--acceptance"})
            task = write_request(path, AddTask(title, parse_priority(option_value(options, "priority", True)), options.get("acceptance", [])))
        case ["note", task_id, *raw_options]:
            task = write_request(path, NoteTask(task_id, option_value(parse_options(raw_options, {"--text"}), "text", True)))
        case ["start", task_id, *raw_options]:
            task = write_request(path, TransitionTask(task_id, "in_progress", option_value(parse_options(raw_options, {"--note"}), "note")))
        case ["block", task_id, *raw_options]:
            task = write_request(path, TransitionTask(task_id, "blocked", option_value(parse_options(raw_options, {"--reason"}), "reason", True)))
        case ["done", task_id, *raw_options]:
            task = write_request(path, TransitionTask(task_id, "completed", option_value(parse_options(raw_options, {"--note"}), "note")))
        case ["cancel", task_id, *raw_options]:
            task = write_request(path, TransitionTask(task_id, "cancelled", option_value(parse_options(raw_options, {"--note"}), "note")))
        case _:
            raise LedgerError(USAGE)
    print(f"{task['id']} {task['status']}: {task['title']}")
    return 0 if sync_tracker(path) else 1


def main() -> int:
    try:
        return run(sys.argv[1:])
    except LedgerError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    except OSError as error:
        print(f"error: filesystem operation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
