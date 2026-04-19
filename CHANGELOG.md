# Changelog

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
