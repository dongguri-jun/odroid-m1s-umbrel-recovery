#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

private_denylist_file="${PUBLIC_SCRUB_DENYLIST:-}"
if [[ -z "$private_denylist_file" ]]; then
  for candidate in ".local/public-scrub-denylist.txt" "docs/private/public-scrub-denylist.txt"; do
    if [[ -f "$candidate" ]]; then
      private_denylist_file="$candidate"
      break
    fi
  done
fi

mapfile -d '' -t tracked_paths < <(
  git ls-files -z -- \
    ':!docs/private/**' \
    ':!.local/**'
)

if [[ "${#tracked_paths[@]}" -eq 0 ]]; then
  printf '[scrub] no tracked public files to scan\n'
  exit 0
fi

python3 - "$private_denylist_file" "${tracked_paths[@]}" <<'PY'
from pathlib import Path
import re
import sys

private_denylist_file = sys.argv[1]
paths = sys.argv[2:]

checks = [
    (
        'private IPv4 address',
        re.compile(r'\b(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[0-1])\.\d{1,3}\.\d{1,3})\b'),
    ),
    (
        'MAC address',
        re.compile(r'\b[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}\b'),
    ),
    (
        'local checkout path',
        re.compile(r'(?<![A-Za-z0-9_])/(?:home/(?!\*)|Users/)[^\s`"\']*(?:Projects|odroid[_-]m1s[_-]umbrel[_-]recovery)[^\s`"\']*'),
    ),
    (
        'expanded safe.directory path',
        re.compile(r'safe\.directory="/(?:home/(?!\*)|Users/)'),
    ),
]

if private_denylist_file:
    denylist = Path(private_denylist_file)
    if not denylist.is_file():
        raise SystemExit(f'[scrub] denylist file does not exist: {private_denylist_file}')
    tokens = [line.strip() for line in denylist.read_text(encoding='utf-8').splitlines()]
    tokens = [token for token in tokens if token and not token.startswith('#')]
    if tokens:
        checks.append(('private denylist token', re.compile('|'.join(re.escape(token) for token in tokens))))

violations = []
for raw_path in paths:
    path = Path(raw_path)
    if not path.is_file():
        continue
    try:
        text = path.read_text(encoding='utf-8')
    except UnicodeDecodeError:
        continue
    for line_no, line in enumerate(text.splitlines(), start=1):
        for label, pattern in checks:
            if pattern.search(line):
                violations.append((str(path), line_no, label, line.strip()))

if violations:
    print('[scrub] public metadata scrub failed; remove private identifiers before publishing/releasing:', file=sys.stderr)
    for path, line_no, label, line in violations:
        preview = line[:180]
        print(f'  {path}:{line_no}: {label}: {preview}', file=sys.stderr)
    raise SystemExit(1)

print(f'[scrub] scanned {len(paths)} tracked files; no private identifiers found')
PY
