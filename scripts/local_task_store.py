from __future__ import annotations

import fcntl
import json
import os
import re
import tempfile
from collections.abc import Callable, Generator
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Final, Literal, Protocol, TypedDict, TypeAlias

Status: TypeAlias = Literal["pending", "in_progress", "blocked", "completed", "cancelled"]
Priority: TypeAlias = Literal["high", "medium", "low"]
JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
TaskDocument = TypedDict("TaskDocument", {"id": str, "title": str, "status": Status, "priority": Priority, "acceptance": list[str], "created_at": str, "updated_at": str, "last_note": str, "notes": list[str]})
LedgerDocument = TypedDict("LedgerDocument", {"schema_version": int, "next_id": int, "tasks": list[TaskDocument]})
SCHEMA_VERSION: Final = 2
KST: Final = timezone(timedelta(hours=9), name="KST")
ID_PATTERN: Final = re.compile(r"LT-([0-9]{4,})$")
OPEN_STATUSES: Final = ("in_progress", "blocked", "pending")
TERMINAL_STATUSES: Final = ("completed", "cancelled")
V1_TASK_FIELDS: Final = frozenset({"id", "title", "status", "priority", "acceptance", "created_at", "updated_at", "last_note"})
V2_TASK_FIELDS: Final = V1_TASK_FIELDS | {"notes"}


class JsonDecoder(Protocol):
    def __call__(self, source: str, /, *, object_pairs_hook: Callable[[list[tuple[str, JsonValue]]], dict[str, JsonValue]]) -> JsonValue: ...


@dataclass(frozen=True, slots=True)
class JsonCodec:
    decode: JsonDecoder


class LedgerError(Exception):
    pass


@dataclass(frozen=True, slots=True)
class AddTask:
    title: str
    priority: Priority
    acceptance: list[str]


@dataclass(frozen=True, slots=True)
class TransitionTask:
    task_id: str
    target: Status
    note: str


@dataclass(frozen=True, slots=True)
class NoteTask:
    task_id: str
    text: str


MutationRequest: TypeAlias = AddTask | TransitionTask | NoteTask
JSON_CODEC: Final = JsonCodec(json.loads)


def now_kst() -> str:
    return datetime.now(KST).isoformat(timespec="seconds")


def empty_ledger() -> LedgerDocument:
    return {"schema_version": SCHEMA_VERSION, "next_id": 1, "tasks": []}


def parse_id(value: JsonValue) -> int:
    if not isinstance(value, str):
        raise LedgerError("task id must be text")
    matched = ID_PATTERN.fullmatch(value)
    if matched is None:
        raise LedgerError(f"malformed task id: {value}")
    number = int(matched.group(1))
    if number < 1 or value != f"LT-{number:04d}":
        raise LedgerError(f"malformed task id: {value}")
    return number


def parse_status(value: JsonValue) -> Status:
    match value:
        case "pending":
            return "pending"
        case "in_progress":
            return "in_progress"
        case "blocked":
            return "blocked"
        case "completed":
            return "completed"
        case "cancelled":
            return "cancelled"
        case _:
            raise LedgerError("task status is invalid")


def parse_priority(value: JsonValue) -> Priority:
    match value:
        case "high":
            return "high"
        case "medium":
            return "medium"
        case "low":
            return "low"
        case _:
            raise LedgerError("task priority is invalid")


def parse_text(value: JsonValue, field: str, nonempty: bool = True) -> str:
    if not isinstance(value, str) or (nonempty and not value.strip()):
        raise LedgerError(f"{field} must be {'non-empty ' if nonempty else ''}text")
    return value


def parse_timestamp(value: JsonValue, field: str) -> str:
    text = parse_text(value, field)
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError as error:
        raise LedgerError(f"{field} must be an ISO-8601 timestamp") from error
    if parsed.utcoffset() != timedelta(hours=9):
        raise LedgerError(f"{field} must use KST (+09:00)")
    return text


def parse_journal_note(value: JsonValue) -> str:
    text = parse_text(value, "note")
    timestamp, separator, note = text.partition(" - ")
    if not separator:
        raise LedgerError("note must start with a KST timestamp")
    _ = parse_timestamp(timestamp, "note timestamp")
    _ = parse_text(note, "note text")
    return text


def parse_task(value: JsonValue, seen_ids: set[int], schema_version: int) -> TaskDocument:
    task_fields = V1_TASK_FIELDS if schema_version == 1 else V2_TASK_FIELDS
    if not isinstance(value, dict) or set(value) != set(task_fields):
        raise LedgerError(f"task entries must contain only the v{schema_version} task fields")
    number = parse_id(value["id"])
    if number in seen_ids:
        raise LedgerError(f"duplicate task id: {value['id']}")
    seen_ids.add(number)
    raw_acceptance = value["acceptance"]
    raw_notes: JsonValue = [] if schema_version == 1 else value["notes"]
    if not isinstance(raw_acceptance, list):
        raise LedgerError("task acceptance must be a list of non-empty text")
    if not isinstance(raw_notes, list):
        raise LedgerError("task notes must be a list of non-empty text")
    return {"id": parse_text(value["id"], "id"), "title": parse_text(value["title"], "title"), "status": parse_status(value["status"]), "priority": parse_priority(value["priority"]), "acceptance": [parse_text(item, "acceptance item") for item in raw_acceptance], "created_at": parse_timestamp(value["created_at"], "created_at"), "updated_at": parse_timestamp(value["updated_at"], "updated_at"), "last_note": parse_text(value["last_note"], "last_note", nonempty=False), "notes": [parse_journal_note(item) for item in raw_notes]}


def validate_ledger(value: JsonValue) -> LedgerDocument:
    if not isinstance(value, dict) or set(value) != {"schema_version", "next_id", "tasks"}:
        raise LedgerError("ledger must contain only schema_version, next_id, and tasks")
    if type(value["schema_version"]) is not int or value["schema_version"] not in (1, SCHEMA_VERSION) or type(value["next_id"]) is not int or value["next_id"] < 1 or not isinstance(value["tasks"], list):
        raise LedgerError("ledger schema is invalid")
    seen_ids: set[int] = set()
    tasks = [parse_task(item, seen_ids, value["schema_version"]) for item in value["tasks"]]
    if seen_ids and value["next_id"] <= max(seen_ids):
        raise LedgerError("next_id must be greater than every existing task number")
    return {"schema_version": SCHEMA_VERSION, "next_id": value["next_id"], "tasks": tasks}


def reject_duplicate_keys(pairs: list[tuple[str, JsonValue]]) -> dict[str, JsonValue]:
    decoded: dict[str, JsonValue] = {}
    for key, value in pairs:
        if key in decoded:
            raise LedgerError(f"duplicate JSON key: {key}")
        decoded[key] = value
    return decoded


def load_ledger(path: Path) -> LedgerDocument:
    if path.is_symlink():
        raise LedgerError(f"ledger path must not be a symlink: {path}")
    if not path.exists():
        return empty_ledger()
    try:
        decoded = JSON_CODEC.decode(path.read_text(encoding="utf-8"), object_pairs_hook=reject_duplicate_keys)
    except json.JSONDecodeError as error:
        raise LedgerError("ledger JSON is malformed; refusing to reset it") from error
    except UnicodeDecodeError as error:
        raise LedgerError("ledger is not UTF-8 text") from error
    return validate_ledger(decoded)


def encode_ledger(ledger: LedgerDocument) -> bytes:
    return (json.dumps(ledger, ensure_ascii=True, indent=2, sort_keys=True) + "\n").encode("utf-8")


def atomic_write(path: Path, payload: bytes) -> None:
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as temporary_file:
            _ = temporary_file.write(payload)
            temporary_file.flush()
            os.fsync(temporary_file.fileno())
        os.replace(temporary_path, path)
        descriptor = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        if temporary_path.exists():
            temporary_path.unlink()


@contextmanager
def exclusive_lock(path: Path) -> Generator[None, None, None]:
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_name(f".{path.name}.lock")
    with lock_path.open("a", encoding="utf-8") as lock_file:
        os.chmod(lock_path, 0o600)
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        yield


def transition_allowed(current: Status, target: Status) -> bool:
    match current:
        case "pending":
            return target in ("in_progress", "cancelled")
        case "in_progress":
            return target in ("blocked", "completed", "cancelled")
        case "blocked":
            return target in ("in_progress", "cancelled")
        case "completed" | "cancelled":
            return False


def apply_request(ledger: LedgerDocument, request: MutationRequest) -> TaskDocument:
    match request:
        case AddTask(title=title, priority=priority, acceptance=acceptance):
            timestamp = now_kst()
            task: TaskDocument = {"id": f"LT-{ledger['next_id']:04d}", "title": title, "status": "pending", "priority": priority, "acceptance": acceptance, "created_at": timestamp, "updated_at": timestamp, "last_note": "", "notes": []}
            ledger["next_id"] += 1
            ledger["tasks"].append(task)
            return task
        case TransitionTask(task_id=task_id, target=target, note=note):
            for task in ledger["tasks"]:
                if task["id"] == task_id:
                    if not transition_allowed(task["status"], target):
                        raise LedgerError(f"invalid transition: {task['status']} -> {target}")
                    task["status"], task["updated_at"], task["last_note"] = target, now_kst(), note
                    return task
            raise LedgerError(f"task not found: {task_id}")
        case NoteTask(task_id=task_id, text=text):
            timestamp = now_kst()
            for task in ledger["tasks"]:
                if task["id"] == task_id:
                    task["updated_at"] = timestamp
                    task["notes"].append(f"{timestamp} - {text}")
                    return task
            raise LedgerError(f"task not found: {task_id}")


def write_request(path: Path, request: MutationRequest) -> TaskDocument:
    with exclusive_lock(path):
        ledger = load_ledger(path)
        previous = path.read_bytes() if path.exists() else None
        task = apply_request(ledger, request)
        _ = validate_ledger(JSON_CODEC.decode(encode_ledger(ledger).decode("utf-8"), object_pairs_hook=reject_duplicate_keys))
        if previous is not None:
            atomic_write(path.with_suffix(path.suffix + ".bak"), previous)
        atomic_write(path, encode_ledger(ledger))
        return task


def find_task(ledger: LedgerDocument, task_id: str) -> TaskDocument:
    for task in ledger["tasks"]:
        if task["id"] == task_id:
            return task
    raise LedgerError(f"task not found: {task_id}")


def render_ledger(ledger: LedgerDocument) -> str:
    lines = ["### Open tasks"]
    has_open = False
    for status in OPEN_STATUSES:
        tasks = sorted((task for task in ledger["tasks"] if task["status"] == status), key=lambda task: task["id"])
        if tasks:
            has_open = True
            lines.append(f"#### {status.replace('_', ' ').title()}")
            lines.extend(render_task(task) for task in tasks)
    if not has_open:
        lines.append("- No open local tasks.")
    terminal = sorted((task for task in ledger["tasks"] if task["status"] in TERMINAL_STATUSES), key=lambda task: (task["updated_at"], task["id"]), reverse=True)[:10]
    if terminal:
        lines.extend(["", "### Recent terminal tasks"])
        lines.extend(render_task(task) for task in terminal)
    return "\n".join(lines)


def render_task(task: TaskDocument) -> str:
    note = f" - {task['last_note']}" if task["last_note"] else ""
    journal = f" [notes: {len(task['notes'])}]" if task["notes"] else ""
    return f"- `{task['id']}` [{task['priority']}] {task['title']}{note}{journal}"
