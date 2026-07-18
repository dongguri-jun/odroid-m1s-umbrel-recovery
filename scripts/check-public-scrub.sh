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
import hashlib

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

guide_section_start = re.compile(r'^### 4-1\.[^\n]*$', re.MULTILINE)
guide_section_end = re.compile(r'^### 4-2\.[^\n]*$', re.MULTILINE)
credential_shaped_entry = re.compile(r'(?im)^[ \t]*(?:login|password):[ \t]*\S[^\r\n]*$')
authoritative_korean_existing_device_section_sha256 = '305419334aae086097924acd780db6604b9c1133cf434ffee3b081e348c8a63d'

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

tracked_path_set = set(paths)
for guide_name in ('README.md', 'README.en.md'):
    if guide_name not in tracked_path_set:
        violations.append((guide_name, 0, 'README 4-1 structure', 'required public guide is not tracked'))
        continue

    guide_path = Path(guide_name)
    try:
        guide_text = guide_path.read_text(encoding='utf-8')
    except (OSError, UnicodeDecodeError):
        violations.append((guide_name, 0, 'README 4-1 structure', 'required public guide is unreadable as UTF-8'))
        continue

    section_starts = list(guide_section_start.finditer(guide_text))
    section_ends = list(guide_section_end.finditer(guide_text))
    if len(section_starts) != 1 or len(section_ends) != 1:
        violations.append((guide_name, 0, 'README 4-1 structure', 'expected exactly one 4-1 heading and one 4-2 heading'))
        continue

    section_start = section_starts[0]
    section_end = section_ends[0]
    if section_start.start() >= section_end.start():
        violations.append((guide_name, 0, 'README 4-1 structure', '4-1 heading must appear before 4-2 heading'))
        continue

    guide_section = guide_text[section_start.start():section_end.start()]
    existing_device_section = guide_text[section_start.end():section_end.start()]
    credential_match = credential_shaped_entry.search(existing_device_section)
    is_authoritative_korean_existing_device_section = (
        guide_name == 'README.md'
        and hashlib.sha256(guide_section.encode('utf-8')).hexdigest()
        == authoritative_korean_existing_device_section_sha256
    )
    if credential_match and not is_authoritative_korean_existing_device_section:
        line_no = guide_text.count('\n', 0, section_start.end() + credential_match.start()) + 1
        violations.append((guide_name, line_no, 'README 4-1 credential-shaped entry', '[redacted]'))

if violations:
    print('[scrub] public metadata scrub failed; remove private identifiers before publishing/releasing:', file=sys.stderr)
    for path, line_no, label, line in violations:
        preview = line[:180]
        print(f'  {path}:{line_no}: {label}: {preview}', file=sys.stderr)
    raise SystemExit(1)

print(f'[scrub] scanned {len(paths)} tracked files; no private identifiers found')
PY
