#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

cli="scripts/local-task.py"
test_dir="$(mktemp -d)"
ledger_path="$test_dir/task-ledger.json"
trap 'rm -rf "$test_dir"' EXIT

fail() {
  printf '[unit][FAIL] %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$message"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  [[ "$haystack" != *"$needle"* ]] || fail "$message"
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  [[ "$expected" == "$actual" ]] || fail "$message: expected '$expected', got '$actual'"
}

run_task() {
  LOCAL_TASK_SKIP_TRACKER_SYNC=1 python3 "$cli" --ledger "$ledger_path" "$@"
}

printf '[unit] local task Python baseline remains compatible with Ubuntu 22.04\n'
grep -Fxq '# requires-python = ">=3.10"' "$cli" || fail 'CLI must declare Python 3.10 compatibility'
for source in "$cli" scripts/local_task.py scripts/local_task_store.py; do
  source_loc="$(awk '!/^[[:space:]]*$/ && !/^[[:space:]]*(#|\/\/|--)/' "$source" | wc -l)"
  [[ "$source_loc" -le 250 ]] || fail "$source must stay at or below 250 pure LOC"
done
if rg -n 'from typing import .*\boverride\b|@override|typing\.override|requires-python = ">=3\.(1[1-9]|[2-9][0-9])"' scripts/local-task.py scripts/local_task.py scripts/local_task_store.py; then
  fail 'Local task modules must not import or use typing.override'
fi

printf '[unit] local task IDs remain monotonic after terminal transitions\n'
first_task="$(run_task add 'First local task' --priority high --acceptance 'Acceptance is recorded')"
assert_contains "$first_task" 'LT-0001' 'First task should receive LT-0001'
run_task cancel LT-0001 --note 'No longer needed' >/dev/null
second_task="$(run_task add 'Second local task' --priority medium --acceptance 'Second acceptance is recorded')"
assert_contains "$second_task" 'LT-0002' 'Terminal tasks must not allow ID reuse'
backup_text="$(<"$ledger_path.bak")"
assert_contains "$backup_text" 'LT-0001' 'Backup must retain the previous valid ledger snapshot'
if [[ "$backup_text" == *'LT-0002'* ]]; then
  fail 'Backup must not contain the newly written task'
fi

printf '[unit] local task state transitions reject invalid operations\n'
if run_task 'done' LT-0002 >/dev/null 2>&1; then
  fail 'Pending tasks must not transition directly to completed'
fi
run_task start LT-0002 >/dev/null
if run_task block LT-0002 >/dev/null 2>&1; then
  fail 'Blocking a task without a reason must fail'
fi
run_task block LT-0002 --reason 'Waiting for a representative fixture' >/dev/null
run_task start LT-0002 >/dev/null
run_task 'done' LT-0002 --note 'Verified by regression coverage' >/dev/null
if run_task start LT-0002 >/dev/null 2>&1; then
  fail 'Completed tasks must be terminal'
fi

printf '[unit] local task notes append to terminal tasks without changing status\n'
python3 - "$ledger_path" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
ledger = json.loads(path.read_text(encoding="utf-8"))
for task in ledger["tasks"]:
    task["updated_at"] = "2026-07-25T10:00:00+09:00"
path.write_text(json.dumps(ledger, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
run_task note LT-0002 --text 'First completed finding' >/dev/null
run_task note LT-0002 --text 'Second completed finding' >/dev/null
run_task note LT-0001 --text 'Cancelled task finding' >/dev/null
python3 - "$ledger_path" <<'PY'
import json
import re
import sys
from pathlib import Path

ledger = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
tasks = {task["id"]: task for task in ledger["tasks"]}
completed = tasks["LT-0002"]
cancelled = tasks["LT-0001"]
if ledger["schema_version"] != 2:
    raise SystemExit("note writes must use schema v2")
if completed["status"] != "completed" or cancelled["status"] != "cancelled":
    raise SystemExit("notes must not alter terminal task status")
if completed["last_note"] != "Verified by regression coverage" or cancelled["last_note"] != "No longer needed":
    raise SystemExit("notes must not alter transition last_note")
expected_completed = ["First completed finding", "Second completed finding"]
actual_completed = [note.split(" - ", 1)[1] for note in completed["notes"]]
if actual_completed != expected_completed:
    raise SystemExit("completed task notes did not accumulate in order")
if [note.split(" - ", 1)[1] for note in cancelled["notes"]] != ["Cancelled task finding"]:
    raise SystemExit("cancelled task note was not recorded")
for task in (completed, cancelled):
    if not all(re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+09:00 - .+", note) for note in task["notes"]):
        raise SystemExit("notes must carry KST timestamps")
    if task["updated_at"] == "2026-07-25T10:00:00+09:00":
        raise SystemExit("adding a note must advance updated_at")
    if task["updated_at"] != task["notes"][-1].split(" - ", 1)[0]:
        raise SystemExit("updated_at must match the latest note timestamp")
PY
show_notes="$(run_task show LT-0002)"
assert_contains "$show_notes" 'First completed finding' 'Show must include the first note'
assert_contains "$show_notes" 'Second completed finding' 'Show must include the second note'
render_notes="$(run_task render)"
assert_contains "$render_notes" '[notes: 2]' 'Tracker rendering should show a compact note count'
assert_not_contains "$render_notes" 'First completed finding' 'Tracker rendering must not dump note history'
empty_note_before="$(sha256sum "$ledger_path")"
if run_task note LT-0002 --text '   ' >/dev/null 2>&1; then
  fail 'Whitespace-only notes must be rejected'
fi
empty_note_after="$(sha256sum "$ledger_path")"
assert_eq "$empty_note_before" "$empty_note_after" 'Rejected notes must not mutate the ledger'

printf '[unit] local task corruption is refused without automatic reset\n'
corrupt_ledger="$test_dir/corrupt-ledger.json"
printf '{"schema_version":1' > "$corrupt_ledger"
corrupt_before="$(sha256sum "$corrupt_ledger")"
if LOCAL_TASK_SKIP_TRACKER_SYNC=1 python3 "$cli" --ledger "$corrupt_ledger" add 'Must not overwrite corruption' --priority low --acceptance 'Never runs' >/dev/null 2>&1; then
  fail 'Malformed ledger must be refused'
fi
corrupt_after="$(sha256sum "$corrupt_ledger")"
assert_eq "$corrupt_before" "$corrupt_after" 'Malformed ledger must remain unchanged'

boolean_schema_ledger="$test_dir/boolean-schema-ledger.json"
printf '{"schema_version":true,"next_id":1,"tasks":[]}' > "$boolean_schema_ledger"
boolean_schema_before="$(sha256sum "$boolean_schema_ledger")"
if LOCAL_TASK_SKIP_TRACKER_SYNC=1 python3 "$cli" --ledger "$boolean_schema_ledger" add 'Must reject boolean schema version' --priority low --acceptance 'Never runs' >/dev/null 2>&1; then
  fail 'Boolean schema_version must be refused'
fi
boolean_schema_after="$(sha256sum "$boolean_schema_ledger")"
assert_eq "$boolean_schema_before" "$boolean_schema_after" 'Boolean schema_version must remain unchanged'

printf '[unit] local task schema v1 upgrades losslessly through the mutation path\n'
migration_ledger="$test_dir/migration-ledger.json"
cat > "$migration_ledger" <<'JSON'
{
  "schema_version": 1,
  "next_id": 8,
  "tasks": [
    {"id":"LT-0007","title":"Preserve every field","status":"blocked","priority":"high","acceptance":["first acceptance","second acceptance"],"created_at":"2026-07-24T09:10:11+09:00","updated_at":"2026-07-25T12:13:14+09:00","last_note":"Existing transition note"}
  ]
}
JSON
migration_before_hash="$(sha256sum "$migration_ledger" | cut -d' ' -f1)"
LOCAL_TASK_SKIP_TRACKER_SYNC=1 python3 "$cli" --ledger "$migration_ledger" add 'Post-upgrade task' --priority low --acceptance 'New task remains valid' >/dev/null
migration_backup_hash="$(sha256sum "$migration_ledger.bak" | cut -d' ' -f1)"
assert_eq "$migration_before_hash" "$migration_backup_hash" 'Upgrade backup must preserve the exact v1 payload'
python3 - "$migration_ledger" <<'PY'
import json
import sys
from pathlib import Path

ledger = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
expected = {
    "id": "LT-0007",
    "title": "Preserve every field",
    "status": "blocked",
    "priority": "high",
    "acceptance": ["first acceptance", "second acceptance"],
    "created_at": "2026-07-24T09:10:11+09:00",
    "updated_at": "2026-07-25T12:13:14+09:00",
    "last_note": "Existing transition note",
    "notes": [],
}
if ledger["schema_version"] != 2 or ledger["next_id"] != 9:
    raise SystemExit("v1 ledger did not upgrade to v2 with monotonic next_id")
if ledger["tasks"][0] != expected:
    raise SystemExit("v1 task fields were not preserved during upgrade")
if ledger["tasks"][1]["id"] != "LT-0008":
    raise SystemExit("post-upgrade allocation did not use the preserved next_id")
PY

duplicate_ledger="$test_dir/duplicate-ledger.json"
cat > "$duplicate_ledger" <<'JSON'
{
  "schema_version": 1,
  "next_id": 2,
  "tasks": [
    {"id":"LT-0001","title":"Duplicate one","status":"pending","priority":"high","acceptance":["one"],"created_at":"2026-07-25T10:00:00+09:00","updated_at":"2026-07-25T10:00:00+09:00","last_note":""},
    {"id":"LT-0001","title":"Duplicate two","status":"pending","priority":"high","acceptance":["two"],"created_at":"2026-07-25T10:00:00+09:00","updated_at":"2026-07-25T10:00:00+09:00","last_note":""}
  ]
}
JSON
duplicate_before="$(sha256sum "$duplicate_ledger")"
if LOCAL_TASK_SKIP_TRACKER_SYNC=1 python3 "$cli" --ledger "$duplicate_ledger" add 'Must not allocate duplicate IDs' --priority low --acceptance 'Never runs' >/dev/null 2>&1; then
  fail 'Duplicate task IDs must be refused'
fi
duplicate_after="$(sha256sum "$duplicate_ledger")"
assert_eq "$duplicate_before" "$duplicate_after" 'Duplicate IDs must be rejected before mutation'

printf '[unit] concurrent local task allocation assigns unique sequential IDs\n'
concurrent_ledger="$test_dir/concurrent-ledger.json"
declare -a worker_pids=()
for worker in $(seq 1 16); do
  LOCAL_TASK_SKIP_TRACKER_SYNC=1 python3 "$cli" --ledger "$concurrent_ledger" add "Concurrent task $worker" --priority low --acceptance "Worker $worker is recorded" >"$test_dir/worker-$worker.out" 2>&1 &
  worker_pids+=("$!")
done
for worker_pid in "${worker_pids[@]}"; do
  wait "$worker_pid"
done
python3 - "$concurrent_ledger" <<'PY'
import json
import sys
from pathlib import Path

ledger = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
ids = sorted(task["id"] for task in ledger["tasks"])
expected = [f"LT-{number:04d}" for number in range(1, 17)]
if ids != expected or ledger["next_id"] != 17:
    raise SystemExit("concurrent allocation did not produce LT-0001 through LT-0016")
PY

printf '[unit] local task rendering is deterministic and read-only\n'
render_ledger="$test_dir/render-ledger.json"
python3 - "$render_ledger" <<'PY'
import json
import sys
from pathlib import Path

tasks = [
    {"id":"LT-0001","title":"Pending render task","status":"pending","priority":"medium","acceptance":["Visible in pending"],"created_at":"2026-07-25T10:00:00+09:00","updated_at":"2026-07-25T10:00:00+09:00","last_note":""},
    {"id":"LT-0002","title":"Blocked render task","status":"blocked","priority":"high","acceptance":["Visible in blocked"],"created_at":"2026-07-25T10:00:00+09:00","updated_at":"2026-07-25T10:00:00+09:00","last_note":"Awaiting proof"},
    {"id":"LT-0003","title":"Active render task","status":"in_progress","priority":"high","acceptance":["Visible in progress"],"created_at":"2026-07-25T10:00:00+09:00","updated_at":"2026-07-25T10:00:00+09:00","last_note":""},
]
for number in range(4, 16):
    tasks.append({"id":f"LT-{number:04d}","title":f"terminal-{number}","status":"completed","priority":"low","acceptance":["Terminal history"],"created_at":"2026-07-25T10:00:00+09:00","updated_at":f"2026-07-25T10:{number:02d}:00+09:00","last_note":"complete"})
Path(sys.argv[1]).write_text(json.dumps({"schema_version": 1, "next_id": 16, "tasks": tasks}, indent=2) + "\n", encoding="utf-8")
PY
render_before="$(sha256sum "$render_ledger")"
render_one="$(LOCAL_TASK_SKIP_TRACKER_SYNC=1 python3 "$cli" --ledger "$render_ledger" render)"
render_two="$(LOCAL_TASK_SKIP_TRACKER_SYNC=1 python3 "$cli" --ledger "$render_ledger" render)"
render_after="$(sha256sum "$render_ledger")"
assert_eq "$render_one" "$render_two" 'Rendering must be deterministic'
assert_eq "$render_before" "$render_after" 'Rendering must not mutate the ledger'
assert_contains "$render_one" '#### In Progress' 'Open tasks should be grouped by state'
assert_contains "$render_one" '#### Blocked' 'Blocked tasks should have a readable group'
assert_contains "$render_one" '#### Pending' 'Pending tasks should have a readable group'
terminal_count="$(printf '%s\n' "$render_one" | grep -c 'terminal-')"
assert_eq '10' "$terminal_count" 'Only ten recent terminal tasks should render'

printf '[unit] tracker-sync failure preserves the completed ledger mutation\n'
sync_failure_script="$test_dir/fail-sync.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$sync_failure_script"
chmod +x "$sync_failure_script"
sync_failure_output="$test_dir/sync-failure.out"
if LOCAL_TASK_SYNC_SCRIPT="$sync_failure_script" python3 "$cli" --ledger "$ledger_path" add 'Mutation survives sync failure' --priority high --acceptance 'Ledger entry remains present' >"$sync_failure_output" 2>&1; then
  fail 'A failed tracker sync must return nonzero after preserving the ledger mutation'
fi
assert_contains "$(<"$sync_failure_output")" 'warning' 'Sync failure should be reported as a warning'
assert_contains "$(LOCAL_TASK_SKIP_TRACKER_SYNC=1 python3 "$cli" --ledger "$ledger_path" show LT-0003)" 'Mutation survives sync failure' 'Failed sync must not roll back a ledger mutation'

printf '[unit] private ledger artifacts stay ignored and public entrypoints stay isolated\n'
grep -Fxq '/.local/' .gitignore || fail '.local/ must remain explicitly ignored'
grep -Fxq '__pycache__/' .gitignore || fail 'Python cache directories must be explicitly ignored'
grep -Fxq '*.pyc' .gitignore || fail 'Python bytecode files must be explicitly ignored'
grep -Fxq '/docs/private/local-task-operations-design.md' .gitignore || fail 'Private design document must have its own ignore rule'
GIT_MASTER=1 git check-ignore -q .local/task-ledger.json || fail 'Ledger path must be ignored'
GIT_MASTER=1 git check-ignore -q scripts/__pycache__/local_task_store.cpython-310.pyc || fail 'Python bytecode cache path must be ignored'
GIT_MASTER=1 git check-ignore -q docs/private/local-task-operations-design.md || fail 'Design document path must be ignored'
if GIT_MASTER=1 git ls-files --error-unmatch .local/task-ledger.json >/dev/null 2>&1; then
  fail 'Ledger must not be tracked'
fi
if GIT_MASTER=1 git ls-files --error-unmatch docs/private/local-task-operations-design.md >/dev/null 2>&1; then
  fail 'Design document must not be tracked'
fi
if rg -n --glob 'm1s-*.sh' 'local-task\.py|local_task_store\.py|task-ledger|\.local/dev-tracker\.md' scripts >/dev/null; then
  fail 'Public installer, updater, and recovery entrypoints must not reference local task artifacts'
fi

printf '[unit] local task tests complete\n'
