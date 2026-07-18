#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

workflow_name="Verify scripts"
dry_run=0
real_device_validation=0

usage() {
  cat <<'USAGE'
Usage: bash scripts/release.sh [--dry-run] [--real-device-validation]

Creates the Git tag and GitHub Release for the version in VERSION.

This script refuses to release unless:
  - the working tree is clean,
  - the current branch is public-clean,
  - local HEAD matches origin/main,
  - the latest GitHub Actions run for HEAD succeeded,
  - CHANGELOG.md has a section for the version,
  - public metadata contains no private device identifiers,
  - the tag and release do not already exist.

Options:
  --dry-run                 Show what would be released without creating anything.
  --real-device-validation  Include the ODROID M1S real-device validation note.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      dry_run=1
      ;;
    --real-device-validation)
      real_device_validation=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$cmd" >&2
    exit 1
  fi
}

require_cmd git
require_cmd gh
require_cmd python3

version="$(tr -d '[:space:]' < VERSION)"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'VERSION must be semver without v prefix. Got: %s\n' "$version" >&2
  exit 1
fi

tag="v${version}"
head_sha="$(git rev-parse HEAD)"
current_branch="$(git branch --show-current)"

printf '[release] version %s\n' "$version"
printf '[release] tag %s\n' "$tag"
printf '[release] HEAD %s\n' "$head_sha"

if [[ "$current_branch" != "public-clean" ]]; then
  printf 'Release must run from public-clean. Current branch: %s\n' "$current_branch" >&2
  exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  printf 'Working tree has unstaged or staged changes. Commit and push before releasing.\n' >&2
  exit 1
fi

if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
  printf 'Working tree has untracked files. Commit, ignore, or remove them before releasing.\n' >&2
  git status --short --untracked-files=all >&2
  exit 1
fi

git fetch origin main --tags >/dev/null
origin_main_sha="$(git rev-parse origin/main)"
if [[ "$head_sha" != "$origin_main_sha" ]]; then
  printf 'Local HEAD must match origin/main before releasing.\n' >&2
  printf '  HEAD:        %s\n' "$head_sha" >&2
  printf '  origin/main: %s\n' "$origin_main_sha" >&2
  exit 1
fi

python3 - "$version" <<'PY'
from pathlib import Path
import re
import sys
version = sys.argv[1]
text = Path('CHANGELOG.md').read_text(encoding='utf-8')
if not re.search(rf'^##\s+{re.escape(version)}\s*$', text, flags=re.M):
    raise SystemExit(f'CHANGELOG.md is missing section: ## {version}')
PY

bash scripts/check-public-scrub.sh

if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
  tag_target="$(git rev-parse "${tag}^{}")"
  printf 'Local tag already exists: %s -> %s\n' "$tag" "$tag_target" >&2
  exit 1
fi

if git ls-remote --exit-code --tags origin "$tag" >/dev/null 2>&1; then
  printf 'Remote tag already exists: %s\n' "$tag" >&2
  exit 1
fi

if gh release view "$tag" >/dev/null 2>&1; then
  printf 'GitHub Release already exists: %s\n' "$tag" >&2
  exit 1
fi

run_json="$(gh run list --workflow "$workflow_name" --branch main --commit "$head_sha" --limit 1 --json conclusion,databaseId,event,headSha,status,url)"
RUN_JSON="$run_json" python3 - "$head_sha" <<'PY'
import json
import os
import sys
head_sha = sys.argv[1]
runs = json.loads(os.environ['RUN_JSON'])
if not runs:
    raise SystemExit(f'No GitHub Actions run found for HEAD {head_sha}')
run = runs[0]
if run.get('headSha') != head_sha:
    raise SystemExit(f'Latest workflow run does not match HEAD {head_sha}: {run}')
if run.get('status') != 'completed' or run.get('conclusion') != 'success':
    raise SystemExit(f'Latest workflow run is not successful: {run}')
print(f"[release] CI success run {run.get('databaseId')} {run.get('url')}")
PY

notes="$(REAL_DEVICE_VALIDATION="$real_device_validation" python3 - "$version" <<'PY'
from pathlib import Path
import os
import re
import sys
version = sys.argv[1]
real_device_validation = os.environ.get('REAL_DEVICE_VALIDATION') == '1'
text = Path('CHANGELOG.md').read_text(encoding='utf-8')
match = re.search(rf'^##\s+{re.escape(version)}\s*\n(?P<body>.*?)(?=^##\s+|\Z)', text, flags=re.M | re.S)
if not match:
    raise SystemExit(f'CHANGELOG.md is missing section: ## {version}')
body = match.group('body').strip()
verification_lines = [
    '- Latest GitHub Actions `Verify scripts` workflow passed for this release commit.',
    '- `bash scripts/verify-scripts.sh` checks bash syntax, ShellCheck, version consistency, heredoc safety, installer invariants, updater safety, public metadata scrub, and workflow presence.',
]
if real_device_validation:
    verification_lines.append('- Real-device validation passed on ODROID M1S hardware.')
verification = '\n'.join(verification_lines)
print(f'''## Highlights

{body}

## Upgrade path for existing installations

Existing hosts can update in place with the usual updater command set. Run the following five commands from the repository directory:

```bash
cd /home/*/odroid-m1s-umbrel-recovery
sudo git -c safe.directory="$(pwd)" fetch https://github.com/dongguri-jun/odroid-m1s-umbrel-recovery.git main
sudo git -c safe.directory="$(pwd)" reset --hard FETCH_HEAD
sudo bash scripts/m1s-update-umbrel.sh --check
sudo bash scripts/m1s-update-umbrel.sh
```

If the local updater is still `0.5.6` or older and exits with “No migrations needed,” that means the device does not have the auto-sync updater yet. In that case, run the same five commands above again after the one-time repository sync step updates the local scripts.

## Verification

{verification}
''')
PY
)"

NOTES="$notes" REPO_ROOT="$repo_root" python3 - <<'PY'
import os
import re

notes = os.environ['NOTES']
repo_root = os.environ['REPO_ROOT']
public_updater_block = '''```bash
cd /home/*/odroid-m1s-umbrel-recovery
sudo git -c safe.directory="$(pwd)" fetch https://github.com/dongguri-jun/odroid-m1s-umbrel-recovery.git main
sudo git -c safe.directory="$(pwd)" reset --hard FETCH_HEAD
sudo bash scripts/m1s-update-umbrel.sh --check
sudo bash scripts/m1s-update-umbrel.sh
```'''

checks = [
    ('release notes expanded $(pwd) to this checkout path', re.escape(repo_root)),
    ('release notes contain a local home-directory path', r'(?<![A-Za-z0-9_])/(?:home|Users)/[^\s`"\']+'),
    ('release notes lost the literal safe.directory=$(pwd) command', r'safe\.directory="\$\(pwd\)"'),
]

if notes.count(public_updater_block) != 1:
    raise SystemExit('Release notes scrub failed: exact public updater block changed or duplicated')

notes_without_public_updater_block = notes.replace(public_updater_block, '')

for label, pattern in checks[:2]:
    if re.search(pattern, notes_without_public_updater_block):
        raise SystemExit(f'Release notes scrub failed: {label}')

if not re.search(checks[2][1], notes):
    raise SystemExit(f'Release notes scrub failed: {checks[2][0]}')

print('[release] release notes scrub passed')
PY

if [[ "$dry_run" -eq 1 ]]; then
  printf '[release] dry-run passed. Would create tag and release %s.\n' "$tag"
  exit 0
fi

git tag -a "$tag" -m "$tag"
git push origin "$tag"
gh release create "$tag" --title "$tag" --notes "$notes"
printf '[release] created %s\n' "$tag"
