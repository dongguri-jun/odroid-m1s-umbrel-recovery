#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
original_path="$PATH"
test_tmpdir="$(mktemp -d)"
release_version="$(tr -d '[:space:]' < "$repo_root/VERSION")"

fail() {
  printf '[unit][FAIL] %s\n' "$1" >&2
  exit 1
}

pass() {
  printf '[unit][PASS] %s\n' "$1"
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [[ "$actual" == "$expected" ]] || fail "$label: expected '$expected', got '$actual'"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$label: missing '$needle'"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  [[ "$haystack" != *"$needle"* ]] || fail "$label: unexpectedly found '$needle'"
}

cleanup() {
  rm -rf "$test_tmpdir"
}
trap cleanup EXIT

new_release_fixture() {
  local name="$1"
  local changelog_body="$2"
  local fixture_root="$test_tmpdir/$name"

  mkdir -p "$fixture_root/bin" "$fixture_root/scripts"
  cp "$repo_root/scripts/release.sh" "$fixture_root/scripts/release.sh"
  chmod +x "$fixture_root/scripts/release.sh"
  for required_path in \
    README.md \
    README.en.md \
    scripts/m1s-support-policy.sh \
    tests/test-support-policy.sh \
    tests/fixtures/shutdown-ui-cache/server.py
  do
    mkdir -p "$fixture_root/$(dirname "$required_path")"
    cp "$repo_root/$required_path" "$fixture_root/$required_path"
  done
  printf '%s\n' "$release_version" > "$fixture_root/VERSION"
  cat > "$fixture_root/CHANGELOG.md" <<EOF
## $release_version

$changelog_body

## 0.5.27 (unreleased)

- Reconcile shutdown completion delivery with live runtime state so the completion screen and the underlying container state agree while the node is stopping.
- Keep the unreleased shutdown path changes scoped to runtime-state reconciliation only.
EOF

  cat > "$fixture_root/scripts/check-public-scrub.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '[scrub] fixture public metadata scrub passed\n'
EOF
  chmod +x "$fixture_root/scripts/check-public-scrub.sh"

  cat > "$fixture_root/bin/git" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "$RELEASE_GIT_LOG"

case "$1" in
  rev-parse)
    case "${2:-}" in
      HEAD|origin/main)
        printf 'fixture-head\n'
        ;;
      -q)
        exit 1
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  branch)
    [[ "${2:-}" == "--show-current" ]] || exit 1
    printf 'public-clean\n'
    ;;
  diff|status|fetch|tag|push)
    ;;
  ls-remote)
    exit 2
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$fixture_root/bin/git"

  cat > "$fixture_root/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "$RELEASE_GH_LOG"

case "$1" in
  release)
    case "${2:-}" in
      view)
        exit 1
        ;;
      create)
        [[ "${6:-}" == "--notes" ]] || exit 1
        printf '%s' "${7:-}" > "$RELEASE_NOTES_CAPTURE"
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  run)
    [[ "${2:-}" == "list" ]] || exit 1
    printf '%s\n' '[{"conclusion":"success","databaseId":"1","event":"push","headSha":"fixture-head","status":"completed","url":"https://example.invalid/run/1"}]'
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$fixture_root/bin/gh"

  printf '%s\n' "$fixture_root"
}

run_release() {
  local fixture_root="$1"
  shift

  (
    cd "$fixture_root"
    PATH="$fixture_root/bin:$original_path" \
      RELEASE_GIT_LOG="$fixture_root/git.log" \
      RELEASE_GH_LOG="$fixture_root/gh.log" \
      RELEASE_NOTES_CAPTURE="$fixture_root/release-notes.md" \
      bash scripts/release.sh "$@"
  )
}

assert_release_prerequisite_missing_fails() {
  local fixture_root="$1"
  local missing_path="$2"
  local label="$3"
  local output status

  rm -f "$fixture_root/$missing_path"
  set +e
  output="$(run_release "$fixture_root" --dry-run 2>&1)"
  status=$?
  set -e

  assert_eq '1' "$status" "$label should fail the release prerequisite gate"
  assert_contains "$output" 'Release prerequisite missing:' "$label should report the missing release prerequisite"
  assert_contains "$output" "$missing_path" "$label should name the missing file"
}

assert_release_doc_audit() {
  local guide_name="$1"
  local guide_text

  guide_text="$(<"$guide_name")"
  assert_contains "$guide_text" 'ODROID M1S + Ubuntu 22.04 Server + Linux 5.10.x' "$guide_name should pin the supported baseline"
  assert_not_contains "$guide_text" 'Ubuntu 20.04 / 22.04 / 24.04 Server' "$guide_name should reject the broad Ubuntu baseline"

  case "$guide_name" in
    README.md)
      assert_contains "$guide_text" 'Ubuntu 20.04/24.04 Server' "$guide_name should reject Ubuntu 20.04/24.04"
      assert_contains "$guide_text" 'Linux 6.1 이상' "$guide_name should reject Linux 6.1+"
      ;;
    README.en.md)
      assert_contains "$guide_text" 'Ubuntu 20.04/24.04 Server' "$guide_name should reject Ubuntu 20.04/24.04"
      assert_contains "$guide_text" 'Linux 6.1+' "$guide_name should reject Linux 6.1+"
      ;;
  esac
}

extract_update_command_block() {
  local notes_path="$1"
  python3 - "$notes_path" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding='utf-8')
blocks = [block.strip('\n') for block in text.split('```')[1::2]]
matches = [block for block in blocks if 'm1s-update-umbrel.sh --check' in block]
if len(matches) != 1:
    raise SystemExit(f'expected one updater command block, found {len(matches)}')
print(matches[0])
PY
}

assert_release_scrub_rejects() {
  local name="$1"
  local changelog_body="$2"
  local expected_reason="$3"
  local fixture_root output status

  fixture_root="$(new_release_fixture "$name" "$changelog_body")"
  set +e
  output="$(run_release "$fixture_root" --dry-run 2>&1)"
  status=$?
  set -e

  assert_eq '1' "$status" "$name should fail the release-note scrub"
  assert_contains "$output" "$expected_reason" "$name should report the rejected privacy boundary"
  assert_not_contains "$(<"$fixture_root/git.log")" 'tag -a' "$name dry-run should not create a tag"
  assert_not_contains "$(<"$fixture_root/gh.log")" 'release create' "$name dry-run should not create a release"
}

new_public_scrub_fixture() {
  local name="$1"
  local public_note="$2"
  local fixture_root="$test_tmpdir/public-scrub-$name"

  mkdir -p "$fixture_root/bin" "$fixture_root/scripts"
  cp "$repo_root/scripts/check-public-scrub.sh" "$fixture_root/scripts/check-public-scrub.sh"
  chmod +x "$fixture_root/scripts/check-public-scrub.sh"
  cat > "$fixture_root/bin/git" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$1" == "ls-files" ]] || exit 1
printf 'README.md\0README.en.md\0public-note.md\0'
EOF
  chmod +x "$fixture_root/bin/git"
  printf '### 4-1. Existing device\n\nPublic guidance.\n\n### 4-2. New device\n' > "$fixture_root/README.md"
  cp "$fixture_root/README.md" "$fixture_root/README.en.md"
  printf '%s\n' "$public_note" > "$fixture_root/public-note.md"

  printf '%s\n' "$fixture_root"
}

run_public_scrub() {
  local fixture_root="$1"

  (
    cd "$fixture_root"
    PATH="$fixture_root/bin:$original_path" bash scripts/check-public-scrub.sh
  )
}

assert_public_scrub_rejects() {
  local name="$1"
  local public_note="$2"
  local expected_reason="$3"
  local fixture_root output status

  fixture_root="$(new_public_scrub_fixture "$name" "$public_note")"
  set +e
  output="$(run_public_scrub "$fixture_root" 2>&1)"
  status=$?
  set -e

  assert_eq '1' "$status" "$name should fail the public metadata scrub"
  assert_contains "$output" "$expected_reason" "$name should report the rejected public metadata"
}

assert_public_scrub_structure_rejects() {
  local name="$1"
  local readme="$2"
  local readme_en="$3"
  local expected_reason="$4"
  local fixture_root output status

  fixture_root="$(new_public_scrub_fixture "$name" '- Public fixture note.')"
  printf '%s' "$readme" > "$fixture_root/README.md"
  printf '%s' "$readme_en" > "$fixture_root/README.en.md"
  set +e
  output="$(run_public_scrub "$fixture_root" 2>&1)"
  status=$?
  set -e

  assert_eq '1' "$status" "$name should fail the public guide structure scrub"
  assert_contains "$output" "$expected_reason" "$name should report the rejected public guide boundary"
}

printf '[unit] release notes allow the exact public updater block\n'
safe_fixture="$(new_release_fixture 'safe' '- Public release-note fixture.')"
set +e
safe_dry_run_output="$(run_release "$safe_fixture" --dry-run --real-device-validation 2>&1)"
safe_dry_run_status=$?
set -e
assert_eq '0' "$safe_dry_run_status" 'exact public updater block should pass release dry-run'
assert_contains "$safe_dry_run_output" '[release] release notes scrub passed' 'safe dry-run should pass the release-note scrub'
assert_contains "$safe_dry_run_output" "[release] dry-run passed. Would create tag and release v$release_version." 'safe dry-run should complete'
assert_not_contains "$(<"$safe_fixture/git.log")" 'tag -a' 'safe dry-run should not create a tag'
assert_not_contains "$(<"$safe_fixture/gh.log")" 'release create' 'safe dry-run should not create a release'

safe_release_output="$(run_release "$safe_fixture" --real-device-validation)"
assert_contains "$safe_release_output" "[release] created v$release_version" 'fixture release should capture generated notes after all gates pass'
expected_update_block=$'bash\ncd /home/*/odroid-m1s-umbrel-recovery\nsudo git -c safe.directory="$(pwd)" fetch https://github.com/dongguri-jun/odroid-m1s-umbrel-recovery.git main\nsudo git -c safe.directory="$(pwd)" reset --hard FETCH_HEAD\nsudo bash scripts/m1s-update-umbrel.sh --check\nsudo bash scripts/m1s-update-umbrel.sh'
assert_eq "$expected_update_block" "$(extract_update_command_block "$safe_fixture/release-notes.md")" 'release notes should preserve the exact five-line public updater command block'
pass 'exact public updater block passes dry-run without tag or release mutation'

public_fence='```'
printf -v duplicated_public_updater_block '%s%s\n%s' "$public_fence" "$expected_update_block" "$public_fence"
assert_release_scrub_rejects \
  'duplicated-public-updater-block' \
  "$duplicated_public_updater_block" \
  'exact public updater block changed or duplicated'
assert_release_scrub_rejects \
  'concrete-home-path' \
  '- Concrete local path: /home/example-user/private' \
  'release notes contain a local home-directory path'
assert_release_scrub_rejects \
  'concrete-users-path' \
  '- Concrete local path: /Users/example-user/private' \
  'release notes contain a local home-directory path'
assert_release_scrub_rejects \
  'unapproved-wildcard-path' \
  '- Unapproved wildcard path: /home/*/different-directory' \
  'release notes contain a local home-directory path'
assert_release_scrub_rejects \
  'checkout-path' \
  "- Temporary checkout path: $test_tmpdir/checkout-path" \
  "release notes expanded \$(pwd) to this checkout path"
pass 'release notes reject concrete local paths, unapproved wildcards, and checkout paths'

private_ipv4_fixture="$(printf '%s.%s.%s.%s' 192 168 1 10)"
mac_address_fixture="$(printf '%s:%s:%s:%s:%s:%s' aa bb cc dd ee ff)"
fixture_home="/$(printf '%s%s' ho me)"
fixture_projects="$(printf '%s%s' Pro jects)"
fixture_repository="$(printf '%s-%s-%s-%s' odroid m1s umbrel recovery)"
local_checkout_fixture="$fixture_home/example-user/$fixture_projects/$fixture_repository"
assert_public_scrub_rejects \
  'private-ipv4' \
  "- Private network address: $private_ipv4_fixture" \
  'private IPv4 address'
assert_public_scrub_rejects \
  'mac-address' \
  "- Hardware address: $mac_address_fixture" \
  'MAC address'
assert_public_scrub_rejects \
  'concrete-checkout-path' \
  "- Local checkout: $local_checkout_fixture" \
  'local checkout path'
pass 'public metadata scrub continues to reject private network, hardware, and checkout identifiers'

printf '[unit] public guide scrub allows only the authoritative Korean existing-device section\n'
authoritative_fixture="$(new_public_scrub_fixture 'authoritative-korean-4-1' '- Public fixture note.')"
python3 - "$repo_root/README.md" "$repo_root/scripts/check-public-scrub.sh" "$authoritative_fixture/README.md" <<'PY'
from pathlib import Path
import hashlib
import re
import sys

readme_path, scrub_path, fixture_path = map(Path, sys.argv[1:])
scrub_source = scrub_path.read_text(encoding='utf-8')
match = re.search(r"authoritative_korean_existing_device_section_sha256 = '([0-9a-f]{64})'", scrub_source)
if not match:
    raise SystemExit('missing authoritative Korean README 4-1 hash')
source = readme_path.read_bytes()
start = source.index(b'### 4-1.')
end = source.index(b'### 4-2.', start)
section = source[start:end]
if hashlib.sha256(section).hexdigest() != match.group(1):
    raise SystemExit('current Korean README 4-1 section does not match the authoritative hash')
fixture_path.write_bytes(section + b'### 4-2. New device\n')
PY
if ! run_public_scrub "$authoritative_fixture"; then
  fail 'the authoritative Korean README 4-1 section must pass the public scrub'
fi
pass 'the authoritative Korean existing-device section passes without broadening credential acceptance'

valid_readme=$'### 4-1. Existing device\n\nPublic guidance.\n\n### 4-2. New device\n'
valid_readme_en=$'### 4-1. Existing device\n\nPublic guidance.\n\n### 4-2. New device\n'
assert_public_scrub_structure_rejects \
  'missing-korean-4-2' \
  $'### 4-1. Existing device\n\nPublic guidance.\n' \
  "$valid_readme_en" \
  'README 4-1 structure'
assert_public_scrub_structure_rejects \
  'duplicate-korean-4-1' \
  $'### 4-1. Existing device\n\nPublic guidance.\n\n### 4-1. Duplicate\n\n### 4-2. New device\n' \
  "$valid_readme_en" \
  'README 4-1 structure'
assert_public_scrub_structure_rejects \
  'out-of-order-korean-guide' \
  $'### 4-2. New device\n\n### 4-1. Existing device\n' \
  "$valid_readme_en" \
  'README 4-1 structure'
assert_public_scrub_structure_rejects \
  'unrelated-english-credential-entry' \
  "$valid_readme" \
  $'### 4-1. Existing device\n\nlogin: fixture-user\n\n### 4-2. New device\n' \
  'README 4-1 credential-shaped entry'
pass 'public guide scrub rejects malformed structure and unrelated English credential-shaped entries'

printf '[unit] release prerequisites and doc guidance are enforced\n'
support_fixture="$(new_release_fixture 'support-files' '- Public release-note fixture.')"
assert_release_prerequisite_missing_fails "$support_fixture" 'scripts/m1s-support-policy.sh' 'missing support-policy script'

support_fixture_2="$(new_release_fixture 'support-tests' '- Public release-note fixture.')"
assert_release_prerequisite_missing_fails "$support_fixture_2" 'tests/test-support-policy.sh' 'missing support-policy test'

support_fixture_3="$(new_release_fixture 'support-shutdown-fixture' '- Public release-note fixture.')"
assert_release_prerequisite_missing_fails "$support_fixture_3" 'tests/fixtures/shutdown-ui-cache/server.py' 'missing shutdown UI cache fixture'

assert_release_doc_audit 'README.md'
assert_release_doc_audit 'README.en.md'

python3 - <<'PY'
from pathlib import Path
import re

text = Path('CHANGELOG.md').read_text(encoding='utf-8')
if not re.search(r'^##\s+0\.5\.27\b', text, flags=re.M):
    raise SystemExit('CHANGELOG.md is missing section: ## 0.5.27')
if not re.search(r'^##\s+0\.5\.29\b', text, flags=re.M):
    raise SystemExit('CHANGELOG.md is missing section: ## 0.5.29')
print('[unit][PASS] changelog includes both the unreleased 0.5.27 transition and the 0.5.29 release section')
PY

printf '[unit] release script tests complete\n'
