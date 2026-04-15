# Changelog

## 0.2.0

- Harden NVMe stability handling during Umbrel installation on ODROID M1S.
- Add conservative NVMe boot parameters for KLEVV/Realtek timeout mitigation.
- Install a self-heal fullnode mount guard that blocks root spillover, attempts remount, captures diagnostic snapshots, and reboots once before failing safe.
- Preserve guard state and captured evidence when the install script is run again.

## 0.1.0

- Initial public release of the ODROID M1S Umbrel install guide and install scripts.
