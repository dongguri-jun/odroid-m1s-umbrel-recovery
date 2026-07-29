#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
original_path="$PATH"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

fail() {
  printf '[unit][FAIL] %s\n' "$1" >&2
  exit 1
}

pass() {
  printf '[unit][PASS] %s\n' "$1"
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"
}

assert_contains() {
  [[ "$1" == *"$2"* ]] || fail "$3: missing '$2'"
}

new_fixture() {
  local name="$1"
  local fixture_root="$TEST_TMPDIR/$name"

  mkdir -p "$fixture_root/bin" "$fixture_root/scripts" "$fixture_root/main"
  cp \
    "$repo_root/scripts/publish-public.sh" \
    "$repo_root/scripts/release.sh" \
    "$repo_root/scripts/record-real-device-validation.sh" \
    "$repo_root/scripts/real-device-validation.sh" \
    "$repo_root/scripts/public-tree-private-paths.sh" \
    "$fixture_root/scripts/"
  chmod +x "$fixture_root/scripts/"*.sh
  cat > "$fixture_root/scripts/check-public-scrub.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '[scrub] fixture public metadata scrub passed\n'
EOF
  chmod +x "$fixture_root/scripts/check-public-scrub.sh"

  for required_path in \
    README.md \
    README.en.md \
    CHANGELOG.md \
    VERSION \
    scripts/m1s-support-policy.sh \
    tests/test-support-policy.sh \
    tests/fixtures/shutdown-ui-cache/server.py
  do
    mkdir -p "$fixture_root/$(dirname "$required_path")"
    cp "$repo_root/$required_path" "$fixture_root/$required_path"
  done

  cat > "$fixture_root/bin/git" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

case "$1" in
  branch)
    [[ "${2:-}" == '--show-current' ]] || exit 1
    printf 'public-clean\n'
    ;;
  rev-parse)
    case "${2:-}" in
      HEAD|origin/main)
        printf 'fixture-head\n'
        ;;
      'HEAD^{tree}')
        printf '%s\n' "$VALIDATION_TREE"
        ;;
      --verify)
        [[ "${3:-}" == 'HEAD^{tree}' ]] || exit 1
        printf '%s\n' "$VALIDATION_TREE"
        ;;
      -q|--abbrev-ref)
        exit 1
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  worktree)
    [[ "${2:-}" == 'list' && "${3:-}" == '--porcelain' && "${4:-}" == '-z' ]] || exit 1
    printf 'worktree %s\0HEAD fixture-main\0branch refs/heads/main\0\0' "$VALIDATION_MAIN_WORKTREE"
    ;;
  ls-tree)
    [[ "${2:-}" == '-r' && "${3:-}" == '-z' && "${4:-}" == '--name-only' ]] || exit 1
    printf 'README.md\0'
    ;;
  check-ignore)
    exit 1
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

case "$1" in
  release)
    [[ "${2:-}" == 'view' ]] || exit 1
    exit 1
    ;;
  run)
    [[ "${2:-}" == 'list' ]] || exit 1
    printf '%s\n' '[{"conclusion":"success","databaseId":"1","headSha":"fixture-head","status":"completed","url":"https://example.invalid/run/1"}]'
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$fixture_root/bin/gh"
  printf '%s\n' "$fixture_root"
}

run_fixture() {
  local fixture_root="$1"
  local tree_hash="$2"
  shift 2

  (
    cd "$fixture_root"
    PATH="$fixture_root/bin:$original_path" \
      VALIDATION_MAIN_WORKTREE="$fixture_root/main" \
      VALIDATION_TREE="$tree_hash" \
      "$@"
  )
}

record_validation() {
  local fixture_root="$1"
  local tree_hash="$2"

  run_fixture "$fixture_root" "$tree_hash" bash scripts/record-real-device-validation.sh \
    --user-path 'performed: Ran the documented command against the candidate tree.' \
    --fresh-install 'not_applicable: The candidate does not change installation.' \
    --official-update 'not_applicable: The candidate does not change the update path.' \
    --web-ui 'not_applicable: The candidate has no web UI change.' \
    --verify-scripts 'performed: bash scripts/verify-scripts.sh passed.' \
    --evidence-for 'Dry-run gate fixture observed each expected result.' \
    --evidence-against 'No contrary fixture observation.' \
    --not-confirmed 'No physical device operation occurs in this hermetic test.' \
    --honest-caveat 'This proves record and gate wiring, not real-device execution.'
}

tree_a='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
tree_b='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

printf '[unit] exact-content validation record blocks both release paths when absent\n'
missing_fixture="$(new_fixture 'missing')"
set +e
missing_publish_output="$(run_fixture "$missing_fixture" "$tree_a" bash scripts/publish-public.sh --dry-run 2>&1)"
missing_publish_status=$?
missing_release_output="$(run_fixture "$missing_fixture" "$tree_a" bash scripts/release.sh --dry-run 2>&1)"
missing_release_status=$?
set -e
assert_eq '1' "$missing_publish_status" 'publish dry-run should fail without a record'
assert_eq '1' "$missing_release_status" 'release dry-run should fail without a record'
assert_contains "$missing_publish_output" "Missing real-device validation record for content tree: $tree_a" 'publish missing record diagnostic'
assert_contains "$missing_release_output" "Missing real-device validation record for content tree: $tree_a" 'release missing record diagnostic'
pass 'both dry-run paths name the missing exact content tree'

printf '[unit] explicit not_applicable checks satisfy a matching validation record\n'
matching_fixture="$(new_fixture 'matching')"
record_output="$(record_validation "$matching_fixture" "$tree_a")"
record_path="$matching_fixture/main/.local/real-device-validations/$tree_a.record"
assert_contains "$record_output" "Recorded real-device validation for content tree: $tree_a" 'record command should name the exact content tree'
assert_contains "$(<"$record_path")" 'fresh_install_status=not_applicable' 'record should preserve explicit fresh-install non-applicability'
assert_contains "$(<"$record_path")" 'web_ui_status=not_applicable' 'record should preserve explicit web UI non-applicability'
matching_publish_output="$(run_fixture "$matching_fixture" "$tree_a" bash scripts/publish-public.sh --dry-run)"
matching_release_output="$(run_fixture "$matching_fixture" "$tree_a" bash scripts/release.sh --dry-run)"
assert_contains "$matching_publish_output" "Accepted real-device validation record for content tree: $tree_a" 'publish should accept matching record'
assert_contains "$matching_release_output" "Accepted real-device validation record for content tree: $tree_a" 'release should accept matching record'
assert_contains "$matching_publish_output" '[public-tree] no paths matching .gitignore found in HEAD' 'publish should inspect the exact public tree before validation acceptance'
assert_contains "$matching_release_output" '[public-tree] no paths matching .gitignore found in HEAD' 'release should inspect the exact public tree before validation acceptance'
assert_contains "$matching_publish_output" '[publish] dry-run passed.' 'publish should reach dry-run output after the gate'
assert_contains "$matching_release_output" '[release] dry-run passed.' 'release should reach dry-run output after the gate'
pass 'record command and both dry-run paths accept the matching tree'

printf '[unit] a record for different content remains stale\n'
stale_fixture="$(new_fixture 'stale')"
record_validation "$stale_fixture" "$tree_b" >/dev/null
set +e
stale_publish_output="$(run_fixture "$stale_fixture" "$tree_a" bash scripts/publish-public.sh --dry-run 2>&1)"
stale_publish_status=$?
stale_release_output="$(run_fixture "$stale_fixture" "$tree_a" bash scripts/release.sh --dry-run 2>&1)"
stale_release_status=$?
set -e
assert_eq '1' "$stale_publish_status" 'publish dry-run should reject a different tree record'
assert_eq '1' "$stale_release_status" 'release dry-run should reject a different tree record'
assert_contains "$stale_publish_output" "Missing real-device validation record for content tree: $tree_a" 'publish should not reuse stale tree evidence'
assert_contains "$stale_release_output" "Missing real-device validation record for content tree: $tree_a" 'release should not reuse stale tree evidence'
pass 'records for different content cannot satisfy either gate'

printf '[unit] missing record fields fail even when a tree-named file exists\n'
malformed_fixture="$(new_fixture 'malformed')"
malformed_record_dir="$malformed_fixture/main/.local/real-device-validations"
mkdir -p "$malformed_record_dir"
cat > "$malformed_record_dir/$tree_a.record" <<EOF
schema_version=1
content_tree=$tree_a
recorded_at=2026-07-29T12:00:00+0900
user_facing_path_status=performed
user_facing_path_evidence=Ran documented path.
fresh_install_status=not_applicable
fresh_install_evidence=No install change.
official_update_status=not_applicable
official_update_evidence=No update change.
web_ui_evidence=No web change.
verify_scripts_status=performed
verify_scripts_evidence=Verifier passed.
evidence_for=Fixture evidence.
evidence_against=None observed.
not_confirmed=No device operation.
honest_caveat=Gate-only test.
EOF
set +e
malformed_output="$(run_fixture "$malformed_fixture" "$tree_a" bash scripts/publish-public.sh --dry-run 2>&1)"
malformed_status=$?
set -e
assert_eq '1' "$malformed_status" 'missing field should fail the gate'
assert_contains "$malformed_output" 'Record is missing required field: web_ui_status' 'missing field diagnostic'
pass 'missing fields cannot masquerade as not_applicable checks'

printf '[unit] real-device validation gate tests complete\n'
