# Changelog

## 0.5.32

- Fix installed apps staying stopped after an interrupted update. If an update was cut short after it had already stopped your apps, for example because the process was killed or the device rebooted mid-update, a later update run could finish and report success while leaving those apps switched off. Every update run now ends by restarting each installed app, except ones you deliberately stopped from the Umbrel interface. This affected published versions 0.5.25 through 0.5.31.

## 0.5.31

- Fix the Bitcoin recovery status check reporting `Bitcoin container: unavailable`, zero RPC checks, and unavailable sync progress even while the Bitcoin app was running. The check now finds the running app and reports its live progress. This affected published versions 0.5.18 through 0.5.30.
- Fix reindex progress fields remaining `unknown` or empty during an active reindex. They now show Bitcoin Core's reported block-file and percentage progress while keeping compatibility with earlier log formats. This affected published versions 0.5.4 through 0.5.30.

## 0.5.30

- Repair existing 0.5.28 and 0.5.29 installations where the Umbrel page opened but showed a generic error instead of onboarding or the home screen. The updater now restores the required authorization for the managed shutdown-screen import map and restarts Umbrel so the repaired web UI is loaded.
- Fix the system package updater reporting success even when Umbrel recreated its own system containers after the update. It now waits for those containers to return before reporting completion.
- Keep verification tests from reaching the host Docker service, and keep their temporary command-output files inside each test's own temporary directory.

## 0.5.29

- Fix raw-disk installs failing with `This disk is currently in use` at `sfdisk`, even though every preceding cleanup check reported the disk as released. systemd was silently remounting the target between the last check and the partition write.
- Hold Docker, its socket, the fullnode mount guard, and the Umbrel autostart unit down with runtime-only masks for the destructive storage window, reload systemd after the fstab rewrite so stale generated mount units cannot be revived, and stop the generated mount and swap units through systemd before the existing unmount and swapoff fallbacks.
- Refuse to write a new partition table unless the target disk passes the same exclusive-open check `sfdisk` itself relies on, reporting the remaining mount, swap, and holder diagnostics when it does not.
- Leave Docker stopped when a raw-disk install aborts before the SSD is ready, so Umbrel data cannot be written to the eMMC root filesystem instead of the SSD.
- Fix `umbrel.local` going silently unreachable after the network path changes. The installer used to pin mDNS to the interface present at install time, so moving between Wi-Fi and Ethernet, swapping a network adapter, or a renamed interface left the address published nowhere while the device IP kept working.
- Stop pinning mDNS to a single interface. Avahi now only excludes the Docker bridges that are actually present, so it follows whatever interface currently carries the LAN.
- Repair stale mDNS interface pins on existing installations during the update, without stopping Docker or Umbrel.
- Separate installer health checks into our own misconfiguration, which now fails the install, and external mDNS problems such as client VPNs or routers that block multicast, which stay advisory because the guides already document the device-IP fallback.
- Keep only the five most recent backups per configuration file. Repeated installs and updates previously left an unbounded number of timestamped copies, which made it hard to tell which backup of a critical file such as `/etc/fstab` was the last known good one.
- Add `scripts/check-host-residue.sh`, which reports files and settings on the host that neither the operating system nor these scripts are responsible for, including configuration values that have drifted away from what the running system actually needs.
- Make the updater compatibility matrix execute each named refusal boundary against the real updater instead of asserting on its label, and fail the suite if any of those boundaries stops refusing.

## 0.5.28

- Warn when the host differs from the validated ODROID M1S, Ubuntu 22.04, and Linux 5.10.x profile while allowing every script to continue.
- Fold the shutdown completion delivery and runtime-state reconciliation work into the release so the safe-shutdown path stays aligned.
- Extend release and regression coverage for version consistency, public metadata scrubbing, the support-policy fixture files, and the public update-command block used in the guides.

## 0.5.27 (unreleased)

- Reconcile shutdown completion delivery with live runtime state so the completion screen and the underlying container state agree while the node is stopping.
- Keep the unreleased shutdown path changes scoped to runtime-state reconciliation only.

## 0.5.26

- Restore the documented existing-device login guidance after an unintended documentation edit.
- Add a no-op `0.5.25_to_0.5.26` updater history step so existing installations can record this guide correction without changing Umbrel data.

## 0.5.25

- Upgrade the managed Dockur Umbrel stack to the exact 1.7.4 arm64 image and converge Tor to 0.4.9.11 on the running system.
- Harden the in-place updater so failed replacements roll back to the previous live image and install state is recorded from verified runtime Docker data.
- Keep the public one-line fresh install path and the existing five-line update path unchanged in both Korean and English guides.
- Add shell test coverage so the documented command UX, updater invariants, and release notes stay aligned.

## 0.5.24

- Normalize the Korean README Bitcoin recovery subsection headings from `1)` / `2)` style to the repository's `12-1` / `12-2` numbered heading style.
- Add a no-op `0.5.23_to_0.5.24` updater history step so existing installations can record this guide update without changing Umbrel data.

## 0.5.23

- Reorder the Korean README system-package update section so the Umbrel web Terminal path is presented first as the recommended method, followed by SSH/direct terminal as the advanced path.
- Add a no-op `0.5.22_to_0.5.23` updater history step so existing installations can record this guide update without changing Umbrel data.

## 0.5.22

- Rework the Korean README flow so operational script updates appear as their own section before Bitcoin recovery, making it clearer that installed devices should periodically pull the latest maintenance scripts.
- Make the web Terminal path the recommended route for operational script updates and Bitcoin recovery, while keeping SSH/direct terminal commands as the advanced path.
- Move Bitcoin recovery health checks before recovery commands and instruct users to share both health-check output and Bitcoin/Umbrel error logs when asking AI which recovery mode to use.
- Add a no-op `0.5.21_to_0.5.22` updater history step so existing installations can record this guide update without changing Umbrel data.

## 0.5.21

- Keep the public fresh-install path aligned with the validated fixed-hostname setup: initial setup no longer asks for a hostname, keeps `umbrel` for `umbrel.local`, and normalizes the Debian-style `127.0.1.1` hosts entry.
- Harden fresh-install package-manager lock handling by waiting for existing apt/dpkg locks, pausing active Ubuntu apt automation during installer apt operations, restoring previously active units on exit, and warning users not to delete lock files or kill package-manager processes.
- Validate the exact public README install flow from a fresh GitHub clone on ODROID M1S hardware: `git clone`, `cd odroid-m1s-umbrel-recovery`, and `sudo bash scripts/m1s-clean-install-umbrel.sh --release`, followed by post-install and controlled-reboot health checks.
- Add a no-op `0.5.20_to_0.5.21` updater history step so already-installed hosts can record this validation release without changing Umbrel data.

## 0.5.20

- Harden the public update command flow in the Korean and English guides, plus generated release notes, by fetching directly from the official GitHub repository URL and resetting to `FETCH_HEAD` instead of trusting a device-local `origin` remote.
- Pin the fresh-install Umbrel image to the same validated `dockurr/umbrel:1.7.3` arm64 digest already used by the updater, and install Docker through Docker's official Ubuntu apt repository/keyring path instead of piping the remote convenience script into root shell.
- Tighten destructive and publish-time safeguards: full-resync Bitcoin data deletion now asserts the target stays under the detected Bitcoin config directory before `rm -rf --`, and publish/release helpers run a public metadata scrub for private IPs, MAC addresses, and optional local denylist tokens.
- Add a no-op `0.5.19_to_0.5.20` updater history step so already-installed hosts can record the hardening release without changing Umbrel data.
- Keep the initial setup flow aligned with the fresh install `umbrel.local` access path by removing the hostname prompt and keeping the host hostname fixed to `umbrel`.

## 0.5.19

- Add an updater migration that removes leftover Incus/LXD packages, services, containers, snap data, and eMMC app-layer remnants from already-installed ODROID M1S Umbrel hosts, matching the fresh install cleanup policy while preserving `/mnt/fullnode` Umbrel data.
- Keep the cleanup idempotent and dry-run visible: the updater only purges installed legacy Incus apt packages, tolerates already-missing services and containers, and post-checks that Incus/LXD apt packages are absent after the migration.

## 0.5.18

- Add a guarded `/data` bind-mount alias for `/mnt/fullnode` and recreate the top-level Umbrel container with `/data:/data`, fixing the Umbrel Files `/Apps` realpath mismatch that could show `[escapes-base] '/Apps' escapes '/mnt/fullnode/app-data'` on Docker-based ODROID M1S installs.
- Keep `/mnt/fullnode` as the canonical physical NVMe mount while making `/data` a strict alias only: the updater refuses to proceed if `/data` is a symlink, a non-directory, non-empty while unmounted, or mounted to anything other than `/mnt/fullnode`.
- Update fresh installs to use the same `/data:/data` wrapper-container mount so new devices can open app data from Files without the previous symlink escape check.

## 0.5.17

- Make the Umbrel in-place updater stop running Umbrel app containers gracefully before recreating the top-level system container, instead of assuming only the `umbrel` container needs lifecycle handling.
- Reuse the `m1s-update-system-packages.sh` style stop/start pattern in `m1s-update-umbrel.sh`: capture the currently running non-`umbrel` containers, stop them with a 300-second timeout before the 1.7.3 refresh, then attempt to restart or warn about recreated/missing containers after the new system container is healthy.
- Add a no-op `0.5.16_to_0.5.17` migration step so existing hosts can record the new updater behavior without forcing another host mutation when the image is already current.
- Extend updater verifier coverage for the new app-container stop/restart helpers and their critical ordering relative to the top-level `umbrel` container refresh.

## 0.5.16

- Change the in-place updater's pinned Umbrel system image from `dockurr/umbrel:1.5.0` to the validated `dockurr/umbrel:1.7.3` arm64 digest so managed ODROID M1S hosts can move to the newer runtime without switching to a fresh install path.
- Add a guarded `0.5.15_to_0.5.16` migration step that snapshots `installed.json`, `fstab`, Docker inspect output, mount state, and the top-level `/mnt/fullnode` tree before recreating only the top-level `umbrel` container.
- Re-apply and verify the safe-to-unplug shutdown patch after the 1.7.3 container refresh, because recreating the top-level Umbrel container wipes in-container modifications.
- Extend verifier coverage so the updater's image pin, migration triplet, and migration history all stay in sync with the new 1.7.3 upgrade path.

## 0.5.15

- Make `m1s-update-umbrel.sh` self-heal a missing `/mnt/fullnode` fstab entry from `installed.json` before planning migrations, so the existing update command can recover from mount drift without adding a new user-facing option.
- Keep `--check` non-mutating: it now reports the planned `/mnt/fullnode` fstab repair while leaving both the real fstab and any test fstab copy untouched.
- Harden fresh-install fstab cleanup so legacy `/mnt/nvme` removal cannot delete an unrelated `/mnt/fullnode` entry unless that entry points to the selected target partition or its pre-format UUID.
- Add updater regression coverage for the self-healing check path and verify the behavior on real ODROID M1S hardware using an fstab copy with `/mnt/fullnode` intentionally removed.

## 0.5.14

- Remove stale legacy `/mnt/nvme` entries during fresh-install fstab cleanup, closing the real-device path where an old NVMe UUID lingered in `/etc/fstab`, triggered a boot-time device timeout, and survived an otherwise healthy `0.5.13` install.
- Keep the cleanup narrowly scoped by matching the legacy mountpoint field itself, so canonical `/mnt/fullnode`, root, boot, existing target mounts, and current swap entries stay untouched while old ODROID/RaspiBlitz-era `/mnt/nvme` remnants are dropped automatically.
- Validate the fix on real ODROID M1S hardware (`better`) after publish: `/mnt/fullnode -> /dev/nvme0n1p1` stayed mounted and both the device IP and `umbrel.local` returned `200 OK` after the stale entry was removed.

## 0.5.13

- Add `m1s-update-system-packages.sh`, a one-command helper for Ubuntu/security/kernel-adjacent package updates that refreshes apt with an apt lock timeout, warns about running Bitcoin-related containers, gracefully stops running Docker containers before package upgrades, repairs/checks dpkg/apt state, cleans apt package cache after successful checks, reboots only when `/var/run/reboot-required` is present, and restarts containers when no reboot is needed.
- Document the new kernel/system package update flow in the Korean and English guides, including both direct terminal/SSH and Umbrel Advanced Terminal paths plus the Bitcoin IBD/download/reindex interruption warning.
- Add a no-op updater history step and verifier coverage so existing installations can record the new helper release without host mutation.

## 0.5.12

- Extend `m1s-check-bitcoin-recovery-status.sh` with non-destructive diagnostics for remote troubleshooting: recent Bitcoin error hints, Bitcoin container state, system load/memory/swap, Docker service state, existing NVMe timeout snapshots, `/mnt/fullnode` mount details, disk and inode usage, block-device summary, available NVMe/SMART health output, and recent kernel storage error hints without repeating the same mount data twice. The checker now still prints system/storage diagnostics when the Bitcoin app config directory is missing.
- Add a no-op updater history step for existing installations so devices can record the new diagnostic-helper release without changing host state.

## 0.5.11

- Add an explicit MIT License file for this repository's guides and scripts while keeping Umbrel's separate PolyForm Noncommercial license boundary clear in the public guides.
- Clean up the Korean and English update instructions by removing stale duplicate three-line updater explanations and fixing Korean wording typos in the current five-line flow.
- Make release-note real-device validation wording opt-in so documentation-only or metadata-only releases do not overstate hardware validation.
- Bring `m1s-initial-setup.sh` into the same script version and verifier checks as the other public helper scripts.

## 0.5.10

- Move generated dev-tracker state to `.local/dev-tracker.md` so public metadata no longer names private tracker or shared-memory paths.
- Remove device access details from the tracker bootstrap template, keeping MAC addresses, private IPs, SSH users, and internal access-note paths out of public files.
- Add a no-op updater history step for existing installations so version tracking remains linear without changing host state.

## 0.5.9

- Include the raw NVMe disk path itself in the SSD-holder scan so stale `docker compose` / Umbrel processes that reopen `/dev/nvme0n1` are treated as killable blockers before repartitioning.
- Re-run SSD-holder cleanup immediately before `sfdisk` on raw-disk installs, closing the real-device path where NVMe recovery succeeded but a late `/data` compose holder still triggered `This disk is currently in use`.
- Extend installer regression coverage for raw-disk holders and the final pre-`sfdisk` cleanup guard.

## 0.5.8

- Extend the fresh installer NVMe recovery ladder with a device-level PCI remove + rescan step after the global PCI rescan fails, based on real-device ODROID M1S validation where `echo 1 > /sys/bus/pci/devices/0000:01:00.0/remove` followed by `/sys/bus/pci/rescan` revived a `CSTS=0x0` NVMe probe failure without manual reseating.
- Add installer regression coverage for the new device-level PCI recovery path, including a dry-run assertion and a short-circuit test that proves the installer can continue without escalating to boot-time mitigation when the PCI remove + rescan recovers visibility.

## 0.5.7

- Make `scripts/m1s-update-umbrel.sh` refresh its own repository from `origin/main` before planning or applying migrations, so users can keep running the same updater command without separate `git fetch` / `git reset` steps.
- Re-execute the freshly synced updater once when the repository changed, then continue with `--skip-sync` to avoid loops while still using the latest published script logic.
- Simplify the Korean and English update guide sections to the three commands users need on `0.5.7` and newer, while documenting the one-time manual sync required for devices whose local updater is still `0.5.6` or older.
- Unify the update command flow in both README.md and README.en.md so sections 12 and 12-1 explicitly include `git fetch origin && git reset --hard origin/main` upfront, removing the conditional branch that confused users on older local scripts. Users on any version now run the same 5-line command set.

## 0.5.6

- Remove the real-device validation coverage note from the public Korean and English recovery guides so the health-check section stays focused on what the user should actually type and read during recovery.
- Clarify the reindex-progress interpretation text in both guides so users know to trust `Reindex blk file`, `Reindex file progress`, and `Current status` when the generic RPC progress field remains at `0.00%` for a long time.

## 0.5.5

- Add `scripts/m1s-start-bitcoin-chainstate-rebuild.sh`, a host-side Umbrel helper that safely records a temporary `reindex-chainstate=1` request in the custom `bitcoin.conf` section, refuses prune-mode or conflicting full-reindex configs, and automatically restarts the live Bitcoin app container so the public flow stays at `start + check`.
- Keep `scripts/m1s-request-bitcoin-chainstate-rebuild.sh` only as a compatibility wrapper that points older instructions to the new `m1s-start-bitcoin-chainstate-rebuild.sh` entrypoint.
- Add `scripts/m1s-check-bitcoin-chainstate-rebuild.sh`, a conservative status checker that separates `request recorded`, `started`, `in progress`, and `no active rebuild visible` states using local state/config evidence plus bounded `debug.log` hints and live `bitcoin-cli` RPC when the Bitcoin app container is reachable.
- Extend script verification and unit tests for the simplified chainstate helper flow, and document both the SSH path and the README 12-1 style Umbrel web UI Terminal path in Korean and English guides.

## 0.5.4

- Add `README.en.md`, a full English translation of the Korean ODROID M1S Umbrel installation guide for non-Korean readers.
- Keep the English guide public-safe by omitting vendor-specific setup details and hardcoded account paths while preserving the general login, install, update, Tailscale, and safe-shutdown instructions.
- Link the English guide from the Korean `README.md` so users can choose their preferred language from the top of the repository page.

## 0.5.3

- Remove ODROID M1S PWM fan overlay settings from `/boot/config.ini` during fresh installs so new Umbrel-only devices do not keep booting with the loud default PWM fan profile.
- Add a `0.5.2_to_0.5.3` updater migration that applies the same PWM cleanup on existing installs and fails closed if `overlay_profile=pwm`, `[overlay_pwm]`, or `pwm1`/`pwm2` overlay entries remain afterward.
- Keep the cleanup tightly scoped to the observed PWM fan config pattern, preserving unrelated overlay lines while backing up the original boot config before any mutation.

## 0.5.2

- Drop the reviewed host-port firewall experiment and simplify the ODROID host network model to match Umbrel Home more closely: if UFW is active, the installer and updater now disable it instead of trying to maintain per-app allow rules.
- Keep Docker/netfilter behavior untouched while removing the extra generated firewall artifact, approval workflow, and host-port reconciliation logic that made the ODROID path more complex than Umbrel Home.
- Use the `0.5.1_to_0.5.2` updater history step to converge existing devices on the simpler Umbrel-style host firewall posture without requiring manual terminal firewall work.

## 0.5.1

- Automatically allow the Umbrel Tailscale web UI port (`8240/tcp`) when UFW is active, fixing the real-device failure where the Tailscale app container listened correctly but browser access from another LAN device timed out.
- Keep the firewall change tightly scoped: the installer and updater do not enable UFW and only add the required Tailscale web UI allow rule when UFW is already enforcing inbound policy.
- Add updater migration coverage so existing `0.5.0` installs receive the same Tailscale firewall compatibility fix without reinstalling or touching app data.

## 0.5.0

- Ship an ODROID M1S `fstrim.service` compatibility drop-in through both the fresh installer and the in-place updater so Ubuntu 22.04 aarch64 hosts stop losing weekly TRIM to the upstream `SystemCallFilter=` / `SIGSYS` failure mode.
- Keep the change tightly scoped to the affected host class: the new helper installs the drop-in only on Ubuntu 22.04 and treats a one-shot `systemctl start fstrim.service` failure as a warning instead of turning SSD housekeeping into an installer hard-fail.
- Add a `0.4.18_to_0.5.0` updater history step and extend verifier / migration tests so the new TRIM compatibility path is tracked, checked, and kept idempotent for existing installs.

## 0.4.18

- Follow up on the `0.4.17` installer release with CI-only compatibility fixes that do not change the intended installer flow on ODROID M1S hardware.
- Fix the installer's `wait_for_umbrel_container()` helper so GitHub Actions ShellCheck no longer fails on optional-argument warnings while preserving the same 30x2s polling behavior.
- Make the tracker-sync regression test branch-agnostic so it passes on both the local `public-clean` branch and GitHub Actions runs on `main`.
- Bring installer, updater, verifier expectations, migration history, and version metadata forward to `0.4.18`. Existing hosts get a no-op `0.4.17_to_0.4.18` history step; the runtime installer behavior is unchanged from the `0.4.17` hot path.

## 0.4.17

- Fix the installer's safe-shutdown post-step to wait for the top-level `umbrel` container after restart, instead of calling a missing helper during the real-device shutdown-patch path.
- Fix full reinstall handling on already-installed NVMe targets by using a `swapon` query form that works on the ODROID M1S host image. This lets the installer detect `/mnt/fullnode/swapfile`, deactivate it, and unmount `/dev/nvme0n1p1` cleanly before repartitioning.
- Verify the installer end-to-end on a real ODROID M1S that initially reproduced the public NVMe cold-boot failure class: first boot missed the NVMe target, the installer applied the NVMe mitigation and rebooted once, `nvme0n1` reappeared after reboot, and the destructive reinstall completed to a running Umbrel with `/dev/nvme0n1p1 -> /mnt/fullnode`, active Avahi aliasing, recorded install state, and working HTTP responses from both `http://umbrel.local` and the device IP.
- Bring installer, updater, verifier expectations, migration history, and version metadata forward to `0.4.17`. Existing hosts get a no-op `0.4.16_to_0.4.17` history step; the real behavior changes are in the fresh installer.

## 0.4.16

- Add target-scoped SSD busy-process cleanup to the fresh installer. After known app/container services are stopped, the installer now collects only PIDs holding the selected NVMe SSD or its mount paths, sends SIGTERM first, and escalates to SIGKILL only for remaining non-protected SSD holders.
- Preserve host control-plane processes while cleaning old SSD holders: SSH/session ancestors, systemd, networking, resolver, DBus, cron, apt/dpkg, and the installer itself are excluded from automatic termination.
- Retry unmount after automatic SSD process cleanup and improve final failure guidance with `fuser` and `journalctl -k` commands for cases that still remain busy.
- Treat Umbrel container start failure as a hard installer failure instead of continuing as if the install succeeded. The installer now stops before hostname/mDNS/install-state recording and prints Docker log/retry guidance.
- Fail closed if the installer cannot prove the ODROID M1S is booted from eMMC (`mmcblk*`) before formatting an NVMe target. The previous explicit-target `CONFIRM-TARGET` fallback is removed so user confirmation alone cannot bypass root/system disk safety.
- Bring installer, updater, verifier expectations, migration history, and version metadata forward to `0.4.16`. Existing hosts get a no-op `0.4.15_to_0.4.16` history step; fresh-installer busy-device handling, Umbrel start hard-fail, and stricter eMMC-root/NVMe-target gating are the real behavior changes.

## 0.4.15

- Restrict the fresh installer to NVMe SSD targets only. Interactive disk selection now lists only non-root `nvme*` disks, instead of showing every non-root block device and asking the user to override a non-NVMe warning.
- Reject explicit non-NVMe `--target-partition` inputs with a hard error instead of a warning-only path. This removes the easiest accidental-data-loss branch where a USB or other auxiliary disk could be formatted by mistake.
- Add installer regression coverage for NVMe-only candidate filtering and explicit non-NVMe target rejection.
- Bring installer, updater, verifier expectations, migration history, and version metadata forward to `0.4.15`. Existing hosts get a no-op `0.4.14_to_0.4.15` history step; fresh-installer target filtering is the real behavior change.

## 0.4.14

- Fix the fresh installer's interactive storage selection prompts so user aborts are handled consistently. A normal terminal `Ctrl-C` now exits through a SIGINT trap with status 130, and web-terminal style `Ctrl-C` input (`0x03`) is no longer treated as an invalid menu choice.
- Add explicit `q` / `quit` / `exit` escape handling to destructive confirmation prompts, including the NVMe selector, non-NVMe override prompt, root-disk fallback confirmation, and final erase confirmation.
- Add an installer regression test that stubs `lsblk` and verifies both Ctrl-C control-character input and `q` exit the NVMe selector without printing `Invalid selection`.
- Bring updater migration history to 0.4.14 with no data mutation for already-installed hosts; this release changes fresh installer behavior only.

## 0.4.13

- README only. Unify the SSH update path (section 12) and the new Umbrel web UI terminal path (section 12-1) onto the same five-line command set so the user does not need to know their host username, home directory, or local clone state.
- Replace `cd ~/odroid-m1s-umbrel-recovery` with `cd /home/*/odroid-m1s-umbrel-recovery`, removing the need for the user to type their host account name.
- Replace `git pull` with `sudo git -c safe.directory='*' fetch origin` + `sudo git -c safe.directory='*' reset --hard origin/main` so that any prior local edits or stale files in the recovery clone do not block the update path. Update is run-from-scratch every time, against `origin/main` exactly.
- Add an optional section 12-1 describing how to run the same five-line command set from inside Umbrel's built-in **Settings → Advanced settings → Terminal**, by entering the host shell with `sudo nsenter -t 1 -m -u -i -n -p -- bash` first. The procedure after that is identical to section 12. No script changes; this is a documentation-only release.

## 0.4.12

- Change the safe shutdown patch to stop the top-level `umbrel` container after a delay instead of killing only the `umbreld` process. This keeps the native Umbrel frontend state machine untouched while making the final connection loss more browser-neutral.
- Keep Docker autostart suppression and boot-time restore behavior unchanged: shutdown still flips `restart=no`, and the restore service still re-enables `restart=always` and starts the container on the next power-on.
- Add a `0.4.11_to_0.4.12` migration and verifier/test updates for the new delayed container-stop shutdown path.

## 0.4.11

- Restore Umbrel's original frontend shutdown bundle behavior after the experimental deterministic completion timer caused the web UI to show an error page before login in some browsers.
- Keep the backend safe shutdown patch only: Docker restart is disabled first, then `umbreld` is stopped after a delay, and boot restore re-enables normal autostart.
- Add a `0.4.10_to_0.4.11` stabilization migration that removes the frontend cache-bust URL and restores the original shutdown UI condition if it was patched.

## 0.4.10

- Cache-bust Umbrel's patched frontend entrypoint in `index.html` so Safari loads the shutdown-completion UI patch instead of reusing the already cached `index-7c0be990.js` bundle.
- Add a `0.4.9_to_0.4.10` migration and verifier checks for the cache-busted script URL.

## 0.4.9

- Patch Umbrel's bundled shutdown UI so the completion screen appears on a deterministic timer after `shutting-down` begins, instead of depending on Safari to report a failed backend poll. This fixes the observed Safari behavior where the screen stayed on **종료 중...** even after the container had safely exited.
- Keep the backend safe shutdown behavior from `0.4.8`: Docker restart is disabled first, then `umbreld` is stopped after a delay, and boot restore still re-enables `restart=always`.
- Add a `0.4.8_to_0.4.9` migration and verifier checks for the UI patch.

## 0.4.8

- Delay the final `umbreld` stop in the safe shutdown patch so Umbrel's own web UI has time to enter `shutting-down`, lose the server connection cleanly, and show the Korean completion screen: **종료 완료 / 이제 디바이스 전원을 분리해도 좋습니다.**
- Add a `0.4.7_to_0.4.8` migration so devices that already received the first safe shutdown patch are upgraded instead of being skipped as current.
- Strengthen shutdown patch verification to require both the Docker restart-policy disable step and the delayed `pkill` command.

## 0.4.7

- Make Umbrel's web UI shutdown path safe for Docker-based ODROID M1S installs. The installer and updater now patch Umbrel's `shutdown()` implementation so it disables the top-level `umbrel` container restart policy before stopping Umbrel, preventing Docker from immediately bringing the stack back up.
- Add `m1s-umbrel-autostart.service`, a boot-time restore service that re-enables `restart=always` and starts the `umbrel` container after power is connected again. This keeps the user-facing flow simple: use **Settings → Shut down**, wait for Umbrel to stop, unplug power, then plug power back in later to start normally.
- Extend updater postchecks and script verification to require the safe shutdown patch, restart-policy restore service, and correct ordering between disabling restart, stopping Umbrel, restoring restart, and starting Umbrel.

## 0.4.6

- Replace the updater's version-jump patch list with a durable step-by-step migration runner. Updates now record `applied_steps`, `in_progress_step`, `failed_step`, and `last_error` in `/etc/umbrel-recovery/installed.json`, so failed updates stop without falsely marking the host as current and reruns skip completed steps.
- Add explicit migration steps from `0.1.0` through `0.4.6`, including no-op history steps for documentation/verification-only releases, while keeping the user-facing command unchanged.
- Pin the updater's Umbrel system image refresh to the verified `dockurr/umbrel:1.5.0` digest instead of `latest` for reproducible updates.
- Extend verification to enforce migration state fields, check/dry-run ordering, failure recording, and final-version recording only after the migration loop completes.
- Add bash unit tests for migration planning, state transitions, failure recording, installed-version detection, step skipping, and CLI flag parsing; the strict verifier now runs these tests in CI.

## 0.4.5

- Add a data-preserving Umbrel system container refresh to the updater. Existing installs now pull `dockurr/umbrel:latest` and recreate only the top-level `umbrel` container when the image changes, while preserving `/mnt/fullnode:/data`, app data, and Bitcoin data.
- Harden the refresh path with preflight checks for the live `/mnt/fullnode` NVMe mount, the existing `umbrel` container's `/data` bind mount, and the Docker socket bind mount before any container stop/remove operation is allowed.
- Extend script verification with updater-specific invariants for the new refresh path, including canonical Docker run flags and mount-safety ordering.

## 0.4.4

- Fix installer heredoc quoting in the NVMe boot-parameter and fstab update paths, preventing dry-run-only validation from missing real execution failures.
- Add a strict script verification gate with `bash -n`, ShellCheck, version consistency checks, unsafe heredoc wrapper detection, installer safety invariants, updater destructive-command bans, and GitHub Actions integration.

## 0.4.3

- Add a plain-language SSD selection guide to the README, including known-good NVMe examples, models with reported ODROID M1S issues, and a warning that M.2 SATA SSDs are not supported.

## 0.4.2

- Ensure `pciutils`, `nvme-cli`, and `smartmontools` are installed when enabling the passive NVMe timeout snapshotter, so captured evidence includes PCIe details, NVMe controller identity, NVMe SMART, and SMART data when available.
- Bring the updater to `0.4.2` so devices that already received `0.4.1` can add the diagnostic tools without reinstalling.

## 0.4.1

- Add a passive NVMe timeout diagnostic snapshotter. It runs silently via a systemd timer and only captures evidence when kernel storage warnings appear, storing `/proc/cmdline`, mount state, `lsblk`, `lspci`, `nvme`/SMART data, and filtered kernel logs under `/var/lib/nvme-timeout-snapshot/snapshots/`.
- Bring the updater to `0.4.1` so existing `0.4.0` installs can receive the same passive diagnostic collector without reinstalling or interrupting non-developer users.

## 0.4.0

- Fix a false failure in `wait_for_apt_locks()`. The installer previously exited early on healthy systems because `fuser` returns status `1` when no process is holding the apt/dpkg lock, which interacted badly with `set -euo pipefail`.
- Patch `/boot/extlinux/extlinux.conf` in addition to `flash-kernel` defaults so the NVMe/PCIe stability parameters (`nvme_core.default_ps_max_latency_us=0`, `pcie_aspm=off`, `pcie_port_pm=off`) actually reach the running kernel on ODROID M1S images whose u-boot reads extlinux.conf as the authoritative cmdline source.
- Detect the real LAN interface via the default route and bind `avahi-daemon`'s `allow-interfaces` to it dynamically instead of hard-coding `eth0`. The `avahi-publish-umbrel` alias publisher now picks its IP from the same LAN interface and re-registers it via `exec` to avoid a stale child after IP changes.
- Rewrite `allow-interfaces` if it is already present but points at the wrong interface, instead of silently leaving drift in place.
- Enforce hostname `umbrel` during install and update. This makes `umbrel.local` an Avahi-native announcement (much stronger than the alias-only path), which noticeably reduces intermittent `umbrel.local` resolution failures. The update path rewrites the `/etc/hosts` `127.0.1.1` line so it matches the new hostname.
- Add a post-install health summary that reports LAN interface, LAN IP, data-mount state, Docker service, Umbrel container, Avahi state, the `umbrel.local` resolver result, and HTTP reachability by both hostname and IP. Hard-fail on missing mount, inactive Docker, or missing Umbrel container; warn on soft failures such as `umbrel.local` not answering locally.
- Drop stale `/mnt/ssd` fstab entries that historically caused emergency-mode boots, and register the Umbrel data mount with `nofail,x-systemd.device-timeout=10s` so a transient SSD stall no longer blocks boot.
- Add `/etc/apt/apt.conf.d/52m1s-no-auto-reboot` to disable `unattended-upgrades` automatic reboot and automatic-reboot-with-users. Security updates still install, but the node will not silently reboot itself.
- Configure Docker JSON-file log rotation via `/etc/docker/daemon.json` (`max-size=10m`, `max-file=5`) so long-running containers do not fill the root or data disk with log history.
- Create a 4G swapfile at `/mnt/fullnode/swapfile` (with `nofail` fstab entry) to reduce OOM risk on 8GB boards during Bitcoin IBD and similar memory-heavy workloads.
- Bring `scripts/m1s-update-umbrel.sh` to parity with the installer so existing installs moving from `0.2.0`/`0.3.0` to `0.4.0` receive the same avahi/extlinux/hostname/no-auto-reboot/Docker log rotation/swapfile changes idempotently.
- Verify the installer end-to-end on a real ODROID M1S (clean install flow) and the updater end-to-end on two separate M1S devices, including one running a live Bitcoin node with ~868 GB of block data. The bitcoin stack was stopped with a long graceful-timeout before the updater restarted Docker, and the chainstate/blocks directories were confirmed intact after the run.

## 0.3.0

- Fix intermittent `umbrel.local` connectivity caused by avahi-daemon advertising Docker veth interfaces. The installer now sets `allow-interfaces=eth0` in `/etc/avahi/avahi-daemon.conf`, so mDNS only responds on the real LAN interface.
- Wait for `unattended-upgrades` (and any other apt/dpkg holder) to finish before touching packages. On freshly installed Ubuntu Server this previously caused the Docker install step to fail midway with a dpkg lock error.
- Record installation metadata to `/etc/umbrel-recovery/installed.json` (version, timestamp, image, data directory, target partition).
- Add `scripts/m1s-update-umbrel.sh`, an idempotent in-place updater for hosts that were already installed with an earlier version. The updater never formats disks, never deletes user data, and never recreates the Umbrel container. Run `sudo bash scripts/m1s-update-umbrel.sh --check` to preview what would change.
- When `installed.json` is missing, the updater heuristically infers the previous version (for example, 0.2.0 is inferred from the presence of `fullnode-mount-guard.service`) so existing installations can upgrade without reinstalling.
- Add `--version` flag to the install script.

## 0.2.0

- Harden NVMe stability handling during Umbrel installation on ODROID M1S.
- Add conservative NVMe boot parameters for KLEVV/Realtek timeout mitigation.
- Install a self-heal fullnode mount guard that blocks root spillover, attempts remount, captures diagnostic snapshots, and reboots once before failing safe.
- Preserve guard state and captured evidence when the install script is run again.

## 0.1.0

- Initial public release of the ODROID M1S Umbrel install guide and install scripts.
