# Changelog

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
