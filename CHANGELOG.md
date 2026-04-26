# Changelog

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
