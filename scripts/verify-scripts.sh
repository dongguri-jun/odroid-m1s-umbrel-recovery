#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

scripts=(scripts/*.sh)
installer="scripts/m1s-clean-install-umbrel.sh"
updater="scripts/m1s-update-umbrel.sh"

printf '[verify] bash syntax\n'
for script in "${scripts[@]}"; do
  bash -n "$script"
  printf '  ok %s\n' "$script"
done

printf '[verify] shellcheck\n'
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "${scripts[@]}"
  printf '  ok shellcheck %s\n' "${scripts[*]}"
else
  printf '  skip shellcheck not installed\n'
fi

printf '[verify] script version flags\n'
for script in "$installer" "$updater"; do
  bash "$script" --version >/dev/null
  printf '  ok bash %s --version\n' "$script"
done

printf '[verify] version consistency\n'
python3 - <<'PY'
from pathlib import Path
import re

version = Path('VERSION').read_text(encoding='utf-8').strip()
for path in [Path('scripts/m1s-clean-install-umbrel.sh'), Path('scripts/m1s-update-umbrel.sh')]:
    text = path.read_text(encoding='utf-8')
    match = re.search(r'^SCRIPT_VERSION="([^"]+)"', text, flags=re.M)
    if not match:
        raise SystemExit(f'{path}: SCRIPT_VERSION is missing')
    if match.group(1) != version:
        raise SystemExit(f'{path}: SCRIPT_VERSION {match.group(1)} does not match VERSION {version}')
print(f'  ok VERSION and script versions match ({version})')
PY

printf '[verify] unsafe heredoc wrappers\n'
python3 - <<'PY'
from pathlib import Path
import re
import sys

# This catches the class of bug where a multi-line heredoc is embedded inside a
# double-quoted shell string, for example:
#   wrapper "... python3 - <<'PY'
#   ... Python code containing " characters ...
#   PY"
# Bash parses the outer double-quoted string before Python ever runs, so a valid
# looking dry-run can still break during real execution.
patterns = [
    re.compile(r'run_shell\s+"[^"\n]*<<[\'\"]?[A-Z_]+', re.DOTALL),
    re.compile(r'bash\s+-lc\s+"[^"\n]*<<[\'\"]?[A-Z_]+', re.DOTALL),
]
violations = []
for path in sorted(Path('scripts').glob('*.sh')):
    text = path.read_text(encoding='utf-8')
    for pattern in patterns:
        for match in pattern.finditer(text):
            line_no = text.count('\n', 0, match.start()) + 1
            excerpt = text[match.start():match.start() + 100].splitlines()[0]
            violations.append(f'{path}:{line_no}: {excerpt}')

if violations:
    print('Unsafe heredoc wrapper found. Use direct heredoc execution or a standalone helper file instead.')
    for item in violations:
        print(f'  {item}')
    sys.exit(1)

print('  ok no heredoc embedded in double-quoted shell command wrappers')
PY

printf '[verify] installer safety invariants\n'
python3 - <<'PY'
from pathlib import Path

text = Path('scripts/m1s-clean-install-umbrel.sh').read_text(encoding='utf-8')
required = [
    'set -Eeuo pipefail',
    'Type ERASE-EMMC-AND-FORMAT-SSD-AND-INSTALL-UMBREL to continue',
    'Refusing to format the root/system disk',
    'TARGET_DISK" == "$ROOT_DISK',
    'run_cmd mkfs.ext4 -F "$TARGET_PARTITION"',
    'Mount verification failed',
    'expected $TARGET_PARTITION mounted at $DATA_DIR',
    'RequiresMountsFor=$DATA_DIR',
    'docker run -d --name umbrel',
    'Install health summary',
    'HTTP by device IP',
    'HTTP by umbrel.local',
]
missing = [needle for needle in required if needle not in text]
if missing:
    print('Missing expected installer safety/health invariant text:')
    for needle in missing:
        print(f'  {needle}')
    raise SystemExit(1)

def pos(needle: str) -> int:
    idx = text.find(needle)
    if idx == -1:
        raise AssertionError(needle)
    return idx

order_checks = [
    ('root disk guard must appear before mkfs', 'Refusing to format the root/system disk', 'run_cmd mkfs.ext4 -F "$TARGET_PARTITION"'),
    ('destructive confirmation must appear before service cleanup', 'Type ERASE-EMMC-AND-FORMAT-SSD-AND-INSTALL-UMBREL to continue', 'Stopping and removing Incus containers if present'),
    ('mount verification must happen before Docker install', 'Mount verification failed', 'Installing fresh Docker'),
    ('Docker mount guard must be installed before Umbrel start', 'Installing self-heal guard for fullnode mount', 'Pulling and starting Umbrel'),
    ('health summary must run before install state recording', 'Install health summary', 'Recording install state'),
]
for label, before, after in order_checks:
    if pos(before) > pos(after):
        raise SystemExit(f'Order invariant failed: {label}')
print('  ok installer safety invariants and critical ordering')
PY

printf '[verify] updater safety invariants\n'
python3 - <<'PY'
from pathlib import Path
text = Path('scripts/m1s-update-umbrel.sh').read_text(encoding='utf-8')
for forbidden in ['mkfs.', 'sfdisk', 'parted', 'wipefs']:
    if forbidden in text:
        raise SystemExit(f'Updater must never contain destructive disk command: {forbidden}')
required = [
    'without touching user data',
    '--check',
    '--dry-run',
    'CURRENT_VERSION',
    'TARGET_VERSION',
]
missing = [needle for needle in required if needle not in text]
if missing:
    print('Missing expected updater invariant text:')
    for needle in missing:
        print(f'  {needle}')
    raise SystemExit(1)
print('  ok updater has no disk-format commands and keeps check/dry-run path')
PY

printf '[verify] workflow presence\n'
python3 - <<'PY'
from pathlib import Path
workflow = Path('.github/workflows/verify.yml')
if not workflow.exists():
    raise SystemExit('.github/workflows/verify.yml is missing')
text = workflow.read_text(encoding='utf-8')
required = [
    'shellcheck',
    'bash scripts/verify-scripts.sh',
    'pull_request:',
    'push:',
]
missing = [needle for needle in required if needle not in text]
if missing:
    print('Workflow is missing expected checks:')
    for needle in missing:
        print(f'  {needle}')
    raise SystemExit(1)
print('  ok GitHub workflow runs the verifier with shellcheck available')
PY

printf '[verify] complete\n'
