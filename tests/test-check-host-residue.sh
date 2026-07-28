#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() {
  printf '[residue][FAIL] %s\n' "$1" >&2
  exit 1
}

pass() {
  printf '[residue][PASS] %s\n' "$1"
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

assert_drift_messages_actionable() {
  local output="$1"
  local label="$2"
  local -a messages=()
  local message
  mapfile -t messages < <(printf '%s\n' "$output" | grep -E '^  \[(static|runtime)\]')
  [[ "${#messages[@]}" -gt 0 ]] || fail "$label: no settings-drift detail lines"
  for message in "${messages[@]}"; do
    [[ "$message" == *'expected:'* ]] || fail "$label: missing expected value in '$message'"
    [[ "$message" == *'observed:'* ]] || fail "$label: missing observed value in '$message'"
    [[ "$message" == *'reason:'* ]] || fail "$label: missing reason in '$message'"
  done
}

TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/check-host-residue.XXXXXX")"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

fixture_repo="$TEST_TMPDIR/repository"
ownership_query="$TEST_TMPDIR/ownership-query"
clean_systemd_query="$TEST_TMPDIR/clean-systemd-query"
failed_systemd_query="$TEST_TMPDIR/failed-systemd-query"
hostname_query="$TEST_TMPDIR/hostname-query"
default_route_query="$TEST_TMPDIR/default-route-query"
uuid_query="$TEST_TMPDIR/uuid-query"
mkdir -p "$fixture_repo/scripts"

write_retention_helper() {
  local retention_count="$1"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    "M1S_BACKUP_RETENTION_COUNT=\"\${M1S_BACKUP_RETENTION_COUNT:-${retention_count}}\"" \
    > "$fixture_repo/scripts/m1s-backup-retention.sh"
}

write_retention_helper 5

cat > "$fixture_repo/scripts/fixture-installer.sh" <<'EOF'
#!/usr/bin/env bash
managed_unit="/etc/systemd/system/m1s-managed.service"
managed_dropin="/etc/systemd/system/docker.service.d/require-fullnode.conf"
managed_config_ini="/boot/config.ini"
managed_extlinux_conf="/boot/extlinux/extlinux.conf"
managed_flash_kernel_defaults="/etc/default/flash-kernel"
managed_fstab="/etc/fstab"
managed_hosts="/etc/hosts"
managed_avahi_conf="/etc/avahi/avahi-daemon.conf"
managed_docker_json="/etc/docker/daemon.json"
DATA_DIR="/mnt/fullnode"
UMBREL_HOSTNAME="umbrel"
printf '127.0.1.1\t%s\n' "$UMBREL_HOSTNAME" >/dev/null
cat >/dev/null <<'DOCKER_JSON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "5"
  }
}
DOCKER_JSON
printf '%s\n' \
  "$managed_unit" \
  "$managed_dropin" \
  "$managed_config_ini" \
  "$managed_extlinux_conf" \
  "$managed_flash_kernel_defaults" \
  "$managed_fstab" \
  "$managed_hosts" \
  "$managed_avahi_conf" \
  "$managed_docker_json" \
  >/dev/null
EOF

cat > "$ownership_query" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "/etc/systemd/system/package-owned.service" ]]
EOF

cat > "$clean_systemd_query" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$failed_systemd_query" <<'EOF'
#!/usr/bin/env bash
printf 'broken-residue.service loaded failed failed Broken residue fixture\n'
EOF

cat > "$hostname_query" <<'EOF'
#!/usr/bin/env bash
cat "$M1S_TEST_RUNTIME_ROOT/runtime-hostname"
EOF

cat > "$default_route_query" <<'EOF'
#!/usr/bin/env bash
cat "$M1S_TEST_RUNTIME_ROOT/runtime-default-interface"
EOF

cat > "$uuid_query" <<'EOF'
#!/usr/bin/env bash
uuid="$1"
grep -qxF "$uuid" "$M1S_TEST_RUNTIME_ROOT/runtime-present-uuids" || exit 1
printf '/dev/disk/by-uuid/%s\n' "$uuid"
EOF

chmod +x \
  "$ownership_query" \
  "$clean_systemd_query" \
  "$failed_systemd_query" \
  "$hostname_query" \
  "$default_route_query" \
  "$uuid_query"

prepare_clean_settings() {
  local fake_root="$1"
  mkdir -p \
    "$fake_root/etc/avahi" \
    "$fake_root/etc/docker" \
    "$fake_root/etc/systemd/system/docker.service.d" \
    "$fake_root/sys/class/net/lan0"
  printf 'umbrel\n' > "$fake_root/runtime-hostname"
  printf 'lan0\n' > "$fake_root/runtime-default-interface"
  printf 'FULLNODE-UUID\n' > "$fake_root/runtime-present-uuids"
  printf '127.0.0.1 localhost\n127.0.1.1 umbrel\n' > "$fake_root/etc/hosts"
  printf 'UUID=FULLNODE-UUID /mnt/fullnode ext4 defaults 0 0\n' > "$fake_root/etc/fstab"
  cat > "$fake_root/etc/docker/daemon.json" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "5"
  }
}
EOF
  printf '[Unit]\nRequiresMountsFor=/mnt/fullnode\n' \
    > "$fake_root/etc/systemd/system/docker.service.d/require-fullnode.conf"
  printf '[server]\n#allow-interfaces=\n' > "$fake_root/etc/avahi/avahi-daemon.conf"
}

run_check() {
  local fake_root="$1"
  local systemd_query="$2"
  local output_file="$3"
  local repository="${4:-$fixture_repo}"
  local prepare_settings="${5:-1}"
  local status
  if [[ "$prepare_settings" -eq 1 ]]; then
    prepare_clean_settings "$fake_root"
  fi
  set +e
  M1S_TEST_RUNTIME_ROOT="$fake_root" \
    M1S_RESIDUE_OWNERSHIP_QUERY_COMMAND="$ownership_query" \
    M1S_RESIDUE_SYSTEMD_QUERY_COMMAND="$systemd_query" \
    M1S_RESIDUE_HOSTNAME_QUERY_COMMAND="$hostname_query" \
    M1S_RESIDUE_UUID_QUERY_COMMAND="$uuid_query" \
    M1S_AVAHI_DEFAULT_ROUTE_QUERY_COMMAND="$default_route_query" \
    bash scripts/check-host-residue.sh --root "$fake_root" "$repository" > "$output_file" 2>&1
  status=$?
  set -e
  printf '%s' "$status"
}

classification_root="$TEST_TMPDIR/classification-root"
mkdir -p \
  "$classification_root/etc/systemd/system/docker.service.d" \
  "$classification_root/etc/NetworkManager/conf.d" \
  "$classification_root/etc/docker"
: > "$classification_root/etc/systemd/system/m1s-abandoned.service"
: > "$classification_root/etc/systemd/system/vendor-thing.service"
: > "$classification_root/etc/systemd/system/snap-example.mount"
: > "$classification_root/etc/systemd/system/m1s-managed.service"
: > "$classification_root/etc/systemd/system/package-owned.service"
: > "$classification_root/etc/systemd/system/docker.service.d/m1s-dropin-orphan.conf"
: > "$classification_root/etc/systemd/system/docker.service.d/require-fullnode.conf"
: > "$classification_root/etc/NetworkManager/conf.d/90-m1s-wifi.conf"
: > "$classification_root/etc/docker/daemon.json.bak.20260728"

classification_output_file="$TEST_TMPDIR/classification.out"
classification_status="$(run_check "$classification_root" "$clean_systemd_query" "$classification_output_file")"
classification_output="$(<"$classification_output_file")"
assert_eq 1 "$classification_status" 'ours residue must fail the gate'
assert_contains "$classification_output" '### FAIL: our own abandoned artefacts (3)' 'ours-orphan count'
assert_contains "$classification_output" '/etc/systemd/system/m1s-abandoned.service' 'plain ours orphan classification'
assert_contains "$classification_output" '/etc/NetworkManager/conf.d/90-m1s-wifi.conf' 'NN-prefixed ours classification'
assert_contains "$classification_output" '/etc/systemd/system/docker.service.d/m1s-dropin-orphan.conf' 'drop-in traversal'
assert_contains "$classification_output" '### FAIL: our backup families over retention bound (0)' 'within-bound backup does not fail'
assert_contains "$classification_output" '### INFO: our backup families within retention bound (1)' 'ours-backup family count'
assert_contains "$classification_output" '/etc/docker/daemon.json.bak.  (count 1, bound 5)' 'ours-backup classification'
assert_contains "$classification_output" '### REPORT ONLY: third-party, installer preserves (1)' 'third-party count'
assert_contains "$classification_output" '/etc/systemd/system/vendor-thing.service' 'third-party classification'
assert_contains "$classification_output" '### INFO: OS-generated (1)' 'OS-generated count'
assert_contains "$classification_output" '/etc/systemd/system/snap-example.mount' 'snap mount classification'
assert_not_contains "$classification_output" '/etc/systemd/system/m1s-managed.service' 'manifest-owned path must be skipped'
assert_not_contains "$classification_output" '/etc/systemd/system/docker.service.d/require-fullnode.conf' 'manifest-owned drop-in must be skipped'
assert_not_contains "$classification_output" '/etc/systemd/system/package-owned.service' 'package-owned path must be skipped'
assert_not_contains "$classification_output" 'third-party, installer preserves (2)' 'NN-prefixed ours must not become third-party'
pass 'all provenance classes, package ownership, manifest paths, and drop-ins are classified correctly'

group_c_root="$TEST_TMPDIR/group-c-root"
mkdir -p "$group_c_root/boot/extlinux" "$group_c_root/etc/default"
for path in \
  /boot/boot-logo.bmp.gz \
  /boot/boot.scr \
  /boot/config.ini \
  /boot/initrd.img-5.10.0-odroid-arm64 \
  /boot/initrd.img-6.1.0-odroid-arm64 \
  /boot/extlinux/extlinux.conf \
  /etc/default/console-setup \
  /etc/default/cpufrequtils \
  /etc/default/flash-kernel \
  /etc/default/gpufrequtils \
  /etc/default/keyboard \
  /etc/default/locale \
  /etc/default/mdadm; do
  : > "$group_c_root$path"
done
group_c_output_file="$TEST_TMPDIR/group-c.out"
group_c_status="$(run_check "$group_c_root" "$clean_systemd_query" "$group_c_output_file")"
group_c_output="$(<"$group_c_output_file")"
assert_eq 0 "$group_c_status" 'known OS-generated files and manifest paths must pass the gate'
assert_contains "$group_c_output" '### INFO: OS-generated (10)' 'explicit Group C allowlist count'
for path in \
  /boot/boot-logo.bmp.gz \
  /boot/boot.scr \
  /boot/initrd.img-5.10.0-odroid-arm64 \
  /boot/initrd.img-6.1.0-odroid-arm64 \
  /etc/default/console-setup \
  /etc/default/cpufrequtils \
  /etc/default/gpufrequtils \
  /etc/default/keyboard \
  /etc/default/locale \
  /etc/default/mdadm; do
  assert_contains "$group_c_output" "$path" "Group C OS-generated classification for $path"
done
for path in /boot/config.ini /boot/extlinux/extlinux.conf /etc/default/flash-kernel; do
  assert_not_contains "$group_c_output" "$path" "manifest-derived Group C path must be skipped for $path"
done
assert_contains "$group_c_output" 'gate-failing: 0 (orphan 0, backups 0, failed units 0)' 'Group C gate summary'
pass 'Group C files are covered only by exact OS rules or the derived script manifest'

group_b_root="$TEST_TMPDIR/group-b-root"
group_b_repo="$TEST_TMPDIR/group-b-repository"
mkdir -p "$group_b_root/boot/extlinux"
mkdir -p "$group_b_repo/scripts"
cp "$fixture_repo/scripts/m1s-backup-retention.sh" "$group_b_repo/scripts/m1s-backup-retention.sh"
cat > "$group_b_repo/scripts/fixture-installer.sh" <<'EOF'
#!/usr/bin/env bash
managed_boot_script="/boot/boot.scr"
managed_dtb="/boot/dtb"
managed_extlinux_conf="/boot/extlinux/extlinux.conf"
managed_fstab="/etc/fstab"
managed_hosts="/etc/hosts"
managed_avahi_conf="/etc/avahi/avahi-daemon.conf"
managed_docker_json="/etc/docker/daemon.json"
managed_dropin="/etc/systemd/system/docker.service.d/require-fullnode.conf"
DATA_DIR="/mnt/fullnode"
UMBREL_HOSTNAME="umbrel"
printf '127.0.1.1\t%s\n' "$UMBREL_HOSTNAME" >/dev/null
cat >/dev/null <<'DOCKER_JSON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "5"
  }
}
DOCKER_JSON
printf '%s\n' \
  "$managed_boot_script" \
  "$managed_dtb" \
  "$managed_extlinux_conf" \
  "$managed_fstab" \
  "$managed_hosts" \
  "$managed_avahi_conf" \
  "$managed_docker_json" \
  "$managed_dropin" \
  >/dev/null
EOF
for path in \
  /boot/boot.scr.bak \
  /boot/dtb.bak \
  /boot/boot.scr.pre-6.1-test-20260625T103211Z \
  /boot/extlinux/extlinux.conf.pre-6.1-test-20260625T103211Z \
  /boot/extlinux/extlinux.conf.pre-5.10-switch-20260721T120834Z \
  /boot/extlinux/extlinux.conf.pre-pci-nomsi-20260622T073123Z; do
  : > "$group_b_root$path"
done
group_b_output_file="$TEST_TMPDIR/group-b.out"
group_b_status="$(run_check "$group_b_root" "$clean_systemd_query" "$group_b_output_file" "$group_b_repo")"
group_b_output="$(<"$group_b_output_file")"
assert_eq 0 "$group_b_status" 'Group B residue must remain report-only'
assert_contains "$group_b_output" '### INFO: our backup families within retention bound (0)' 'bare bak files must not become managed retention families'
assert_contains "$group_b_output" '### REPORT ONLY: third-party, installer preserves (6)' 'Group B third-party count'
assert_contains "$group_b_output" '### INFO: OS-generated (0)' 'Group B must not be swallowed by OS rules'
for path in \
  /boot/boot.scr.bak \
  /boot/dtb.bak \
  /boot/boot.scr.pre-6.1-test-20260625T103211Z \
  /boot/extlinux/extlinux.conf.pre-6.1-test-20260625T103211Z \
  /boot/extlinux/extlinux.conf.pre-5.10-switch-20260721T120834Z \
  /boot/extlinux/extlinux.conf.pre-pci-nomsi-20260622T073123Z; do
  assert_contains "$group_b_output" "$path" "Group B visibility for $path"
done
pass 'Group B bare backups and pre-label leftovers remain visible as third-party residue'

orphan_only_root="$TEST_TMPDIR/orphan-only-root"
mkdir -p "$orphan_only_root/etc/systemd/system"
: > "$orphan_only_root/etc/systemd/system/m1s-only-orphan.service"
orphan_only_output_file="$TEST_TMPDIR/orphan-only.out"
orphan_only_status="$(run_check "$orphan_only_root" "$clean_systemd_query" "$orphan_only_output_file")"
orphan_only_output="$(<"$orphan_only_output_file")"
assert_eq 1 "$orphan_only_status" 'ours-orphan alone must fail the gate'
assert_contains "$orphan_only_output" 'gate-failing: 1 (orphan 1, backups 0, failed units 0)' 'ours-orphan-only gate summary'
pass 'ours-orphan alone fails the gate'

backup_only_root="$TEST_TMPDIR/backup-only-root"
mkdir -p "$backup_only_root/etc/docker"
for stamp in 2026072801 2026072802 2026072803 2026072804 2026072805; do
  : > "$backup_only_root/etc/docker/daemon.json.bak.$stamp"
done
backup_only_output_file="$TEST_TMPDIR/backup-only.out"
backup_only_status="$(run_check "$backup_only_root" "$clean_systemd_query" "$backup_only_output_file")"
backup_only_output="$(<"$backup_only_output_file")"
assert_eq 0 "$backup_only_status" 'ours-backup family at the bound must pass the gate'
assert_contains "$backup_only_output" '### FAIL: our backup families over retention bound (0)' 'at-bound backup failure count'
assert_contains "$backup_only_output" '### INFO: our backup families within retention bound (1)' 'at-bound backup info count'
assert_contains "$backup_only_output" '/etc/docker/daemon.json.bak.  (count 5, bound 5)' 'at-bound backup family detail'
assert_contains "$backup_only_output" 'gate-failing: 0 (orphan 0, backups 0, failed units 0)' 'at-bound backup gate summary'
pass 'ours-backup family exactly at the retention bound is informational'

boot_backup_root="$TEST_TMPDIR/boot-backup-root"
mkdir -p "$boot_backup_root/boot/extlinux" "$boot_backup_root/etc/default"
for stamp in 2026072801 2026072802 2026072803 2026072804 2026072805; do
  : > "$boot_backup_root/boot/config.ini.bak.$stamp"
  : > "$boot_backup_root/boot/extlinux/extlinux.conf.bak.$stamp"
  : > "$boot_backup_root/etc/default/flash-kernel.bak.$stamp"
done
boot_backup_output_file="$TEST_TMPDIR/boot-backup.out"
boot_backup_status="$(run_check "$boot_backup_root" "$clean_systemd_query" "$boot_backup_output_file")"
boot_backup_output="$(<"$boot_backup_output_file")"
assert_eq 0 "$boot_backup_status" 'boot backup families at the bound must pass the gate'
assert_contains "$boot_backup_output" '### INFO: our backup families within retention bound (3)' 'boot backup family count'
assert_contains "$boot_backup_output" '/boot/config.ini.bak.  (count 5, bound 5)' 'config.ini backup family detail'
assert_contains "$boot_backup_output" '/boot/extlinux/extlinux.conf.bak.  (count 5, bound 5)' 'extlinux backup family detail without overlap double-counting'
assert_contains "$boot_backup_output" '/etc/default/flash-kernel.bak.  (count 5, bound 5)' 'flash-kernel backup family detail'
assert_contains "$boot_backup_output" 'gate-failing: 0 (orphan 0, backups 0, failed units 0)' 'boot backup gate summary'
pass 'boot and flash-kernel backup families are each counted once against the derived bound'

broad_target_root="$TEST_TMPDIR/broad-target-root"
mkdir -p "$broad_target_root/etc/avahi"
for stamp in 2026072801 2026072802 2026072803 2026072804 2026072805; do
  : > "$broad_target_root/etc/fstab.bak.$stamp"
  : > "$broad_target_root/etc/fstab.bak.data-alias.$stamp"
done
: > "$broad_target_root/etc/passwd"
: > "$broad_target_root/etc/avahi/vendor-residue.conf"
broad_target_output_file="$TEST_TMPDIR/broad-target.out"
broad_target_status="$(run_check "$broad_target_root" "$clean_systemd_query" "$broad_target_output_file")"
broad_target_output="$(<"$broad_target_output_file")"
assert_eq 0 "$broad_target_status" 'targeted broad-dir backup families and dedicated-dir report-only residue must pass'
assert_contains "$broad_target_output" '### INFO: our backup families within retention bound (2)' 'broad-dir backup family count'
assert_contains "$broad_target_output" '/etc/fstab.bak.  (count 5, bound 5)' 'plain fstab backup family detail'
assert_contains "$broad_target_output" '/etc/fstab.bak.data-alias.  (count 5, bound 5)' 'data-alias fstab backup family detail'
assert_not_contains "$broad_target_output" '/etc/passwd' 'unrelated file in broad shared directory must not be scanned'
assert_contains "$broad_target_output" '### REPORT ONLY: third-party, installer preserves (1)' 'dedicated derived directory residue count'
assert_contains "$broad_target_output" '/etc/avahi/vendor-residue.conf' 'dedicated directory derived from fixture script must be fully scanned'
pass 'broad shared directories use targeted families while script-derived dedicated directories remain full scans'

over_bound_root="$TEST_TMPDIR/over-bound-root"
mkdir -p "$over_bound_root/etc/docker"
for stamp in 2026072801 2026072802 2026072803 2026072804 2026072805 2026072806; do
  : > "$over_bound_root/etc/docker/daemon.json.bak.$stamp"
done
over_bound_output_file="$TEST_TMPDIR/over-bound.out"
over_bound_status="$(run_check "$over_bound_root" "$clean_systemd_query" "$over_bound_output_file")"
over_bound_output="$(<"$over_bound_output_file")"
assert_eq 1 "$over_bound_status" 'ours-backup family over the bound must fail the gate'
assert_contains "$over_bound_output" '### FAIL: our backup families over retention bound (1)' 'over-bound backup failure count'
assert_contains "$over_bound_output" '/etc/docker/daemon.json.bak.  (count 6, bound 5, over 1)' 'over-bound backup family detail'
assert_contains "$over_bound_output" 'gate-failing: 1 (orphan 0, backups 1, failed units 0)' 'over-bound backup gate summary'
pass 'ours-backup family one over the retention bound fails once per family'

independent_families_root="$TEST_TMPDIR/independent-families-root"
mkdir -p "$independent_families_root/etc/docker"
for family_suffix in '' '.data-alias' '.update-repair'; do
  for stamp in 2026072801 2026072802 2026072803 2026072804 2026072805; do
    : > "$independent_families_root/etc/docker/daemon.json.bak${family_suffix}.$stamp"
  done
done
independent_families_output_file="$TEST_TMPDIR/independent-families.out"
independent_families_status="$(run_check "$independent_families_root" "$clean_systemd_query" "$independent_families_output_file")"
independent_families_output="$(<"$independent_families_output_file")"
assert_eq 0 "$independent_families_status" 'distinct at-bound backup families must not combine into a failure'
assert_contains "$independent_families_output" '### FAIL: our backup families over retention bound (0)' 'independent family failure count'
assert_contains "$independent_families_output" '### INFO: our backup families within retention bound (3)' 'independent family info count'
assert_contains "$independent_families_output" '/etc/docker/daemon.json.bak.  (count 5, bound 5)' 'plain backup family detail'
assert_contains "$independent_families_output" '/etc/docker/daemon.json.bak.data-alias.  (count 5, bound 5)' 'data-alias backup family detail'
assert_contains "$independent_families_output" '/etc/docker/daemon.json.bak.update-repair.  (count 5, bound 5)' 'update-repair backup family detail'
pass 'backup suffix families for one source are counted independently'

derived_bound_root="$TEST_TMPDIR/derived-bound-root"
mkdir -p "$derived_bound_root/etc/docker"
for stamp in 2026072801 2026072802 2026072803; do
  : > "$derived_bound_root/etc/docker/daemon.json.bak.$stamp"
done
write_retention_helper 2
derived_bound_fail_output_file="$TEST_TMPDIR/derived-bound-fail.out"
derived_bound_fail_status="$(run_check "$derived_bound_root" "$clean_systemd_query" "$derived_bound_fail_output_file")"
derived_bound_fail_output="$(<"$derived_bound_fail_output_file")"
assert_eq 1 "$derived_bound_fail_status" 'helper bound below the family count must fail the gate'
assert_contains "$derived_bound_fail_output" '/etc/docker/daemon.json.bak.  (count 3, bound 2, over 1)' 'lower helper bound detail'
write_retention_helper 3
derived_bound_pass_output_file="$TEST_TMPDIR/derived-bound-pass.out"
derived_bound_pass_status="$(run_check "$derived_bound_root" "$clean_systemd_query" "$derived_bound_pass_output_file")"
derived_bound_pass_output="$(<"$derived_bound_pass_output_file")"
assert_eq 0 "$derived_bound_pass_status" 'helper bound equal to the family count must pass the gate'
assert_contains "$derived_bound_pass_output" '/etc/docker/daemon.json.bak.  (count 3, bound 3)' 'raised helper bound detail'
write_retention_helper 5
pass 'detector verdict follows M1S_BACKUP_RETENTION_COUNT from the helper'

missing_helper_repo="$TEST_TMPDIR/missing-helper-repository"
missing_helper_root="$TEST_TMPDIR/missing-helper-root"
mkdir -p "$missing_helper_repo/scripts"
mkdir -p "$missing_helper_root"
cp "$fixture_repo/scripts/fixture-installer.sh" "$missing_helper_repo/scripts/fixture-installer.sh"
missing_helper_output_file="$TEST_TMPDIR/missing-helper.out"
missing_helper_status="$(run_check "$missing_helper_root" "$clean_systemd_query" "$missing_helper_output_file" "$missing_helper_repo")"
missing_helper_output="$(<"$missing_helper_output_file")"
assert_eq 2 "$missing_helper_status" 'missing retention helper must stop the detector'
assert_contains "$missing_helper_output" 'FATAL: cannot read backup retention helper' 'missing retention helper diagnostic'
pass 'retention-bound derivation failure is loud and does not guess a default'

missing_rule_path_repo="$TEST_TMPDIR/missing-rule-path-repository"
missing_rule_path_root="$TEST_TMPDIR/missing-rule-path-root"
cp -a "$fixture_repo" "$missing_rule_path_repo"
sed -i '/managed_avahi_conf/d' "$missing_rule_path_repo/scripts/fixture-installer.sh"
mkdir -p "$missing_rule_path_root"
missing_rule_path_output_file="$TEST_TMPDIR/missing-rule-path.out"
missing_rule_path_status="$(run_check "$missing_rule_path_root" "$clean_systemd_query" "$missing_rule_path_output_file" "$missing_rule_path_repo")"
missing_rule_path_output="$(<"$missing_rule_path_output_file")"
assert_eq 2 "$missing_rule_path_status" 'a settings rule path missing from the manifest must stop the detector'
assert_contains "$missing_rule_path_output" 'FATAL: settings-drift rule avahi-allow-interfaces references /etc/avahi/avahi-daemon.conf, which is absent from the derived manifest' 'settings rule manifest invariant diagnostic'
pass 'every settings-drift rule path is statically constrained by the derived manifest'

report_only_root="$TEST_TMPDIR/report-only-root"
mkdir -p "$report_only_root/etc/systemd/system"
: > "$report_only_root/etc/systemd/system/vendor-thing.service"
: > "$report_only_root/etc/systemd/system/snap-example.mount"
report_only_output_file="$TEST_TMPDIR/report-only.out"
report_only_status="$(run_check "$report_only_root" "$clean_systemd_query" "$report_only_output_file")"
report_only_output="$(<"$report_only_output_file")"
assert_eq 0 "$report_only_status" 'report-only residue must not fail the gate'
assert_contains "$report_only_output" 'gate-failing: 0' 'report-only gate result'
assert_contains "$report_only_output" 'report-only: third-party 1, os 1' 'report-only summary'
pass 'third-party and OS-generated files never fail the gate'

failed_units_root="$TEST_TMPDIR/failed-units-root"
mkdir -p "$failed_units_root"
failed_units_output_file="$TEST_TMPDIR/failed-units.out"
failed_units_status="$(run_check "$failed_units_root" "$failed_systemd_query" "$failed_units_output_file")"
failed_units_output="$(<"$failed_units_output_file")"
assert_eq 1 "$failed_units_status" 'failed systemd units must fail the gate'
assert_contains "$failed_units_output" 'broken-residue.service' 'failed systemd unit report'
assert_contains "$failed_units_output" 'failed units 1' 'failed systemd unit count'
pass 'failed systemd units fail the gate through the injected query'

active_allow_root="$TEST_TMPDIR/active-allow-root"
prepare_clean_settings "$active_allow_root"
printf 'allow-interfaces=wifi-wan0\n' >> "$active_allow_root/etc/avahi/avahi-daemon.conf"
mkdir -p "$active_allow_root/etc/systemd/system"
: > "$active_allow_root/etc/systemd/system/vendor-thing.service"
: > "$active_allow_root/etc/systemd/system/snap-example.mount"
active_allow_output_file="$TEST_TMPDIR/active-allow.out"
active_allow_status="$(run_check "$active_allow_root" "$clean_systemd_query" "$active_allow_output_file" "$fixture_repo" 0)"
active_allow_output="$(<"$active_allow_output_file")"
assert_eq 1 "$active_allow_status" 'active Avahi allow-interfaces must fail the gate'
assert_contains "$active_allow_output" '### FAIL: settings drift (1)' 'active allow settings-drift count'
assert_contains "$active_allow_output" 'expected: no active allow-interfaces' 'active allow expected value'
assert_contains "$active_allow_output" 'observed: allow-interfaces=wifi-wan0' 'active allow observed value'
assert_contains "$active_allow_output" 'reason: active interface pinning can exclude the live LAN and break umbrel.local' 'active allow reason'
assert_contains "$active_allow_output" 'report-only: third-party 1, os 1' 'settings drift preserves report-only counts'
assert_drift_messages_actionable "$active_allow_output" 'active allow drift message'
pass 'active allow-interfaces is actionable settings drift and report-only classes keep their meaning'

denied_lan_root="$TEST_TMPDIR/denied-lan-root"
prepare_clean_settings "$denied_lan_root"
printf '[server]\ndeny-interfaces=lan0\n' > "$denied_lan_root/etc/avahi/avahi-daemon.conf"
denied_lan_output_file="$TEST_TMPDIR/denied-lan.out"
denied_lan_status="$(run_check "$denied_lan_root" "$clean_systemd_query" "$denied_lan_output_file" "$fixture_repo" 0)"
denied_lan_output="$(<"$denied_lan_output_file")"
assert_eq 1 "$denied_lan_status" 'denying the live default-route interface must fail the gate'
assert_contains "$denied_lan_output" 'expected: deny-interfaces contains only present virtual bridges' 'denied LAN bridge expectation'
assert_contains "$denied_lan_output" 'expected: default-route interface lan0 is not denied' 'denied LAN route expectation'
assert_contains "$denied_lan_output" 'observed: deny-interfaces=lan0' 'denied LAN observed value'
assert_contains "$denied_lan_output" 'reason: denying the live LAN prevents Avahi from publishing umbrel.local there' 'denied LAN reason'
assert_drift_messages_actionable "$denied_lan_output" 'denied live LAN drift messages'
pass 'Avahi denial of the live default-route LAN is locked as gate-failing drift'

wrong_hostname_root="$TEST_TMPDIR/wrong-hostname-root"
prepare_clean_settings "$wrong_hostname_root"
printf 'not-umbrel\n' > "$wrong_hostname_root/runtime-hostname"
wrong_hostname_output_file="$TEST_TMPDIR/wrong-hostname.out"
wrong_hostname_status="$(run_check "$wrong_hostname_root" "$clean_systemd_query" "$wrong_hostname_output_file" "$fixture_repo" 0)"
wrong_hostname_output="$(<"$wrong_hostname_output_file")"
assert_eq 1 "$wrong_hostname_status" 'wrong hostname must fail the gate'
assert_contains "$wrong_hostname_output" 'expected: hostname=umbrel' 'hostname expected value'
assert_contains "$wrong_hostname_output" 'observed: hostname=not-umbrel' 'hostname observed value'
assert_contains "$wrong_hostname_output" 'reason: the managed hostname anchors the umbrel.local identity' 'hostname reason'
assert_drift_messages_actionable "$wrong_hostname_output" 'wrong hostname drift message'
pass 'wrong hostname is actionable settings drift'

wrong_hosts_root="$TEST_TMPDIR/wrong-hosts-root"
prepare_clean_settings "$wrong_hosts_root"
printf '127.0.0.1 localhost\n127.0.1.1 old-host\n' > "$wrong_hosts_root/etc/hosts"
wrong_hosts_output_file="$TEST_TMPDIR/wrong-hosts.out"
wrong_hosts_status="$(run_check "$wrong_hosts_root" "$clean_systemd_query" "$wrong_hosts_output_file" "$fixture_repo" 0)"
wrong_hosts_output="$(<"$wrong_hosts_output_file")"
assert_eq 1 "$wrong_hosts_status" 'wrong hosts mapping must fail the gate'
assert_contains "$wrong_hosts_output" 'expected: 127.0.1.1 maps exactly to umbrel' 'hosts expected value'
assert_contains "$wrong_hosts_output" 'observed: 127.0.1.1 maps to old-host' 'hosts observed value'
assert_contains "$wrong_hosts_output" 'reason: Debian host identity and local name resolution must agree' 'hosts reason'
assert_drift_messages_actionable "$wrong_hosts_output" 'wrong hosts drift message'
pass 'wrong /etc/hosts mapping is actionable settings drift'

wrong_docker_root="$TEST_TMPDIR/wrong-docker-root"
prepare_clean_settings "$wrong_docker_root"
cat > "$wrong_docker_root/etc/docker/daemon.json" <<'EOF'
{
  "log-driver": "local",
  "log-opts": {
    "max-size": "100m",
    "max-file": "1"
  }
}
EOF
wrong_docker_output_file="$TEST_TMPDIR/wrong-docker.out"
wrong_docker_status="$(run_check "$wrong_docker_root" "$clean_systemd_query" "$wrong_docker_output_file" "$fixture_repo" 0)"
wrong_docker_output="$(<"$wrong_docker_output_file")"
assert_eq 1 "$wrong_docker_status" 'wrong Docker log rotation must fail the gate'
assert_contains "$wrong_docker_output" 'expected: log-driver=json-file, max-size=10m, max-file=5' 'Docker expected values'
assert_contains "$wrong_docker_output" 'observed: log-driver=local, max-size=100m, max-file=1' 'Docker observed values'
assert_contains "$wrong_docker_output" 'reason: bounded json-file logs prevent Docker logs from exhausting the host disk' 'Docker reason'
assert_drift_messages_actionable "$wrong_docker_output" 'wrong Docker drift message'
pass 'wrong Docker log-rotation values are actionable settings drift'

wrong_dropin_root="$TEST_TMPDIR/wrong-dropin-root"
prepare_clean_settings "$wrong_dropin_root"
printf '[Unit]\nRequiresMountsFor=/var/lib/umbrel\n' \
  > "$wrong_dropin_root/etc/systemd/system/docker.service.d/require-fullnode.conf"
wrong_dropin_output_file="$TEST_TMPDIR/wrong-dropin.out"
wrong_dropin_status="$(run_check "$wrong_dropin_root" "$clean_systemd_query" "$wrong_dropin_output_file" "$fixture_repo" 0)"
wrong_dropin_output="$(<"$wrong_dropin_output_file")"
assert_eq 1 "$wrong_dropin_status" 'wrong Docker mount requirement must fail the gate'
assert_contains "$wrong_dropin_output" 'expected: RequiresMountsFor=/mnt/fullnode' 'Docker mount expected value'
assert_contains "$wrong_dropin_output" 'observed: RequiresMountsFor=/var/lib/umbrel' 'Docker mount observed value'
assert_contains "$wrong_dropin_output" 'reason: Docker starting without the data mount can write Umbrel data to the root filesystem' 'Docker mount reason'
assert_drift_messages_actionable "$wrong_dropin_output" 'wrong Docker mount drift message'
pass 'wrong Docker fullnode mount requirement is actionable settings drift'

dead_uuid_root="$TEST_TMPDIR/dead-uuid-root"
prepare_clean_settings "$dead_uuid_root"
printf 'UUID=REPLACED-SSD /mnt/fullnode ext4 defaults 0 0\n' > "$dead_uuid_root/etc/fstab"
dead_uuid_output_file="$TEST_TMPDIR/dead-uuid.out"
dead_uuid_status="$(run_check "$dead_uuid_root" "$clean_systemd_query" "$dead_uuid_output_file" "$fixture_repo" 0)"
dead_uuid_output="$(<"$dead_uuid_output_file")"
assert_eq 1 "$dead_uuid_status" 'unresolved fullnode UUID must fail the gate'
assert_contains "$dead_uuid_output" 'expected: UUID for /mnt/fullnode resolves to a present block device' 'fstab UUID expected value'
assert_contains "$dead_uuid_output" 'observed: UUID=REPLACED-SSD resolves to no present block device' 'fstab UUID observed value'
assert_contains "$dead_uuid_output" 'reason: a dead data-mount UUID leaves Umbrel storage unavailable after boot' 'fstab UUID reason'
assert_drift_messages_actionable "$dead_uuid_output" 'dead fstab UUID drift message'
pass 'an fstab UUID for a replaced SSD is actionable runtime drift'

clean_root="$TEST_TMPDIR/clean-root"
mkdir -p "$clean_root"
clean_output_file="$TEST_TMPDIR/clean.out"
clean_status="$(run_check "$clean_root" "$clean_systemd_query" "$clean_output_file")"
clean_output="$(<"$clean_output_file")"
assert_eq 0 "$clean_status" 'clean fake root must pass'
assert_contains "$clean_output" '### FAIL: settings drift (0)' 'clean settings-drift count'
assert_contains "$clean_output" 'gate-failing: 0 (orphan 0, backups 0, failed units 0)' 'clean gate summary'
assert_contains "$clean_output" 'settings-drift 0' 'clean gate settings-drift summary'
pass 'clean fake root has zero settings drift and exits zero'

printf '[residue] host residue tests complete\n'
