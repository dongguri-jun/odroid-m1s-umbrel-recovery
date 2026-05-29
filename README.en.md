# How to Install Umbrel on ODROID M1S

[한국어 안내서](README.md)

> **Unofficial guide / Disclaimer**
>
> This repository is **a non-commercial personal guide maintained by Dongguri**. It is not officially affiliated with BinariList Inc., Umbrel, ODROID, or Hardkernel.
>
> This repository's guides and scripts are released under the MIT License. Umbrel itself is separately licensed under the **PolyForm Noncommercial 1.0.0** license, so check Umbrel's non-commercial terms separately before using, operating, or supporting Umbrel or derivatives.
>
> The procedure in this guide **deletes all data on the storage device (SSD)**. Device damage or data loss may occur during installation. Before continuing, **back up any important data**. This guide is provided for free, and **you are responsible for the installation result**.
>
> **Do not unplug the power cable abruptly.** If you suddenly cut power while a Bitcoin node is running, Bitcoin data may become corrupted. To shut down, use **Settings → Shut down** in the Umbrel web UI, then wait until the **“Shutdown complete / It is now safe to disconnect power.”** screen appears. For details, see **11. Safe shutdown** below.

---

This guide explains how to install Umbrel on an ODROID M1S in a way that **non-technical users can follow step by step**.

This repository most commonly uses the following 6 files.

- `scripts/m1s-clean-install-umbrel.sh` — Umbrel installation script
- `scripts/m1s-initial-setup.sh` — initial setup script for account and hostname configuration
- `scripts/m1s-update-umbrel.sh` — update script for bringing an already-installed device up to the latest version
- `scripts/m1s-update-system-packages.sh` — helper for Ubuntu security/kernel-related package updates and reboot-if-needed handling
- `scripts/m1s-start-bitcoin-chainstate-rebuild.sh` — helper for starting a Bitcoin chainstate rebuild
- `scripts/m1s-check-bitcoin-recovery-status.sh` — helper for checking Bitcoin recovery status

These scripts have been tested on real ODROID M1S hardware.

The ODROID M1S is stable and relatively affordable.
However, it is not a very high-performance device, so heavy tasks or long download/sync workloads can take quite some time.

---

## 0. Important warning

This installation method **deletes all SSD data**.

That means:
- All data currently on the SSD will be deleted.
- Existing node data will not be preserved.
- The base Ubuntu system will remain installed.

Do not continue if you must preserve the SSD data.

---

## 1. What you need

You need the following items.

- **ODROID M1S board (8GB model strongly recommended, 4GB model not recommended)** (official ODROID store: https://www.hardkernel.com/)
- **Power cable**
- **Monitor**
- **HDMI-to-HDMI cable**
- **USB keyboard**
- **Wired internet connection (LAN cable / Ethernet cable)**
- **NVMe SSD of 2TB or larger**
- One computer or phone connected to the **same local network as the ODROID M1S**, so you can open the Umbrel web page after installation

Important:
- If possible, use the **8GB ODROID M1S model**.
- The **4GB model has too little RAM**, so it may not have enough headroom when running Umbrel and a Bitcoin node together.

Required:
- During installation, you must use a **wired network connection (LAN cable / Ethernet cable)**.
- **The ODROID M1S cannot use Wi-Fi**, so you must proceed in a wired network environment.

### Notes on SSD selection

The ODROID M1S can use NVMe SSDs.

Most NVMe SSDs can be used, but some SSDs have been reported to be unrecognized by the ODROID M1S or to disappear after reboot.  
The installation script in this repository automatically applies stability settings to reduce this type of SSD detection issue.

If possible, use an SSD that is known to work, such as:

- Crucial P3 / P3 Plus
- Kingston NV1
- PNY CS1031
- Samsung PM9A1
- Samsung 970 EVO
- Samsung 970 EVO Plus 1TB
- Western Digital SN550

The following SSDs have had issues reported on the ODROID M1S, so it is better to avoid them if possible.

- Silicon Power NVMe SSD
- Samsung 970 EVO Plus 2TB
- WD Green WDS480G3G0B

If you cannot find one of the recommended SSDs, do not worry too much.  
Most SSDs labeled **M.2 NVMe 2280 SSD** should work.
However, use an official SSD from a major brand rather than a very cheap no-name SSD.
- "M.2 = the physical SSD form factor"
- "NVMe = the communication protocol the SSD uses to transfer data, not ~~SATA~~"
- "2280 = the physical SSD size, not ~~2230~~ or ~~2242~~"

Note that `M.2 SATA` SSDs use a different interface and cannot be used.

For Bitcoin node use, an **SSD of 2TB or larger** is recommended.

---

## 2. Connect the hardware

Connect the hardware in this order.

1. Install the **NVMe SSD** into the ODROID M1S.
2. Connect the monitor with an **HDMI cable**.
3. Connect the **USB keyboard**.
4. Make sure to connect the **Ethernet cable**.
5. Finally, connect the **power cable**.

---

## 3. Check that Ubuntu Server is already installed

This guide works under the following conditions.

- Device: **Hardkernel ODROID-M1S**
- OS: **Ubuntu 20.04 / 22.04 / 24.04 Server**

Ubuntu must already be installed, and you must be able to log in.

If Ubuntu is not installed yet, install Ubuntu Server first, then continue with this guide.

---

## 4. Open the terminal

When you power on the ODROID M1S with a **monitor connected through HDMI**, Ubuntu Server will show a screen where you can enter commands.

This guide is written for a **Linux server environment (Ubuntu Server)**.

In other words, you do not need to look for a Terminal icon on a desktop screen. Instead, you can proceed directly from the **command input screen shown on the monitor after boot**.

The important part is to log in on the **black screen where you can type commands**, then enter the commands below in order.

Right after powering on the device, the login screen may not appear immediately.

On real hardware, it usually becomes ready for login after **about 1–3 minutes**.

From here, there are two cases.

### 4-1. If Ubuntu Server is already installed on the device

This guide basically assumes an **ODROID M1S with Ubuntu Server already installed**.

If Ubuntu Server is already installed, log in with the username and password created by whoever first set up the device.

The username and password may differ from device to device. Use the account information you received from the seller or installer. If you log in with a default or temporary account, it is strongly recommended that you create a new user account and password in step 7 after installation.

### 4-2. If you are setting up a new device and installed Ubuntu Server yourself

If this is a **new device** and you installed Ubuntu Server yourself first, ODROID devices can usually be logged into with the following default account.

```text
login: odroid
password: odroid
```

When entering the password, it is normal that nothing appears on the screen. Type the password and press **Enter**.

If you already created a **new user account** during the initial setup in step 7, use that new account and password instead of the default account from then on.

---

## 5. Prepare the repository

You need to download this repository onto the ODROID M1S.

> **Note — how to enter commands**
>
> Enter the commands below **one line at a time**. After typing one line, press **Enter** to run it. Wait until the command finishes and the terminal is ready for the next command before entering the next line.

**(1) Refresh the package list.**

```bash
sudo apt update
```

Press **Enter** after typing it. When the command finishes, the terminal will be ready for input again.

**(2) Install `git`.**

```bash
sudo apt install -y git
```

Press **Enter** after typing it. Wait until installation finishes.

**(3) Download the repository onto the ODROID M1S.**

```bash
git clone https://github.com/dongguri-jun/odroid-m1s-umbrel-recovery.git
```

Press **Enter** after typing it. Files will be downloaded over the network.

**(4) Move into the downloaded folder.**

```bash
cd odroid-m1s-umbrel-recovery
```

Press **Enter** after typing it. You are now ready to run the command in step 6.

### If `git clone` does not work

If you see something like this:

```text
Could not resolve host: github.com
```

Run the following commands one line at a time.

```bash
ping -c 3 github.com
curl -I https://github.com
sudo systemctl restart systemd-resolved
```

Then run the following commands again.

```bash
git clone https://github.com/dongguri-jun/odroid-m1s-umbrel-recovery.git
cd odroid-m1s-umbrel-recovery
```

---

## 6. Run the installation command

Now you only need to run **one command**. As in step 5, enter the line and press **Enter**.

```bash
sudo bash scripts/m1s-clean-install-umbrel.sh --release
```

When it runs, the script automatically performs the following tasks.

1. Cleans up existing app/container/node-related services
2. Formats the NVMe SSD
3. Mounts the SSD at `/mnt/fullnode`
4. Registers it in `/etc/fstab`
5. Installs Docker
6. Starts Umbrel
7. Prints basic health check information based on `umbrel.local` and the device IP

If a deletion warning appears during the process, type the confirmation phrase shown on the screen exactly as displayed.

In practice, you will be asked to type the following phrase.

```text
ERASE-EMMC-AND-FORMAT-SSD-AND-INSTALL-UMBREL
```

The phrase is long, so type it slowly and carefully without mistakes.

---

## 7. Initial setup (create an account / change hostname)

After step 6 finishes, you can **create your own user account and change the device name**.

This step is optional. You may skip it if you want to keep using the existing account.

However, if you do not create your own account and set a new password, you may keep using a default account, which can be **very insecure**.

So if possible, do not skip this step. It is **strongly recommended** that you create a new user account and password.

Run this **one command**.

```bash
sudo bash scripts/m1s-initial-setup.sh
```

The script will ask for the following items on screen.

1. **New username** — enter the name you will use when logging in.
2. **New password** — enter the password, then enter it again for confirmation.
3. **New hostname** — enter the device name. If you leave it blank, it will use `odroid`.

When the summary appears, type `y` to continue.

After setup finishes, instructions will appear on screen. Follow them in order.

1. Type `exit` to log out.
2. Log back in with the new account you just created.
3. If you want to delete the old account, type the deletion command shown on screen exactly as displayed.

---

## 8. Connect after installation

After installation finishes, open a browser on another computer or phone connected to the same network and first enter this address.

```text
http://umbrel.local
```

In most cases, this address opens Umbrel directly.

Right after installation finishes, the final part of the terminal output usually also shows information like this.

- LAN interface
- LAN IP
- `http://umbrel.local`
- `http://<device IP>`

So even if `umbrel.local` does not open, you can connect directly using the **device IP address shown in the terminal**.

Important:
- If **Tailscale or another VPN is enabled** on the device you are using to connect, it is recommended that you turn it off first.
- If one of these programs is running, `umbrel.local` may not open correctly or may point to the wrong address.

If `umbrel.local` does not open, first try the **device IP shown at the end of the terminal output**. If you still need to find the IP, use the **Fing app to check IP addresses**, then enter the address in your browser.

The Fing app can be downloaded for free from the **Google Play Store** and the **Apple App Store**.

If you see entries such as **Generic** or **unknown device** in the Fing list, try entering each displayed IP address in your browser one by one.

Eventually, you should find the IP address that opens the Umbrel screen.

For example:

```text
http://<device IP>
```

---

## 9. Create an Umbrel account

When the Umbrel screen opens in your browser, proceed in this order.

1. **Create an Umbrel account**
2. Set a password
3. Finish the basic setup

---

## 10. Install the Bitcoin node app

After creating your Umbrel account, install the **Bitcoin node app** from the App Store.

When installation starts, the progress indicator will move, but based on real-device testing, it may appear to stay at **99% for a long time**.

However, the following tasks may still be running in the background.

- Downloading Docker images
- Creating the Bitcoin container
- Creating the Tor container
- Starting Bitcoin Core header synchronization

So do not assume it has failed just because it says 99%. Depending on network speed and disk condition, it may take longer. **Take your time and let it continue while you do something else.**

Bitcoin Core also performs a lot of computation during **IBD (Initial Block Download)**, so the device may get hot for a while.

In real use, when synchronization takes a long time, placing **a small portable fan so it blows air over the top of the board** may help cool it faster.

Lower temperatures may help reduce throttling, so in some cases synchronization can become more stable and faster.

## 10-1. Recovering Bitcoin data

When the Bitcoin node suddenly stops or disconnects, proceed in the following order.

### 1) First, determine which recovery is appropriate

There are three recovery methods.

- **chainstate rebuild** — Keep block data and only rebuild chainstate (try this first)
- **reindex** — Keep blocks but rescan block index and chainstate more broadly
- **full resync** — Remove all data and download from scratch again (last resort)

If you are unsure, copy the Bitcoin/Umbrel error log into an AI chat and ask something like this:

```text
Looking at this error log,
1) chainstate rebuild
2) reindex
3) full resync
which recovery is appropriate?
And which command should I type in the Umbrel Terminal?
```

If possible, copy from where the error starts to the final message.

### 2) Run the recovery command (SSH)

First, follow **section 12 below** to bring the repository and scripts up to date, then pick the command that matches the recovery mode the AI recommended from the three options below.

**chainstate rebuild**

```bash
sudo bash scripts/m1s-start-bitcoin-chainstate-rebuild.sh
sudo bash scripts/m1s-check-bitcoin-recovery-status.sh
```

**reindex**

```bash
sudo bash scripts/m1s-start-bitcoin-reindex.sh
sudo bash scripts/m1s-check-bitcoin-recovery-status.sh
```

**full resync**

```bash
sudo bash scripts/m1s-start-bitcoin-full-resync.sh
sudo bash scripts/m1s-check-bitcoin-recovery-status.sh
```

### 3) If you are using the Umbrel web UI Terminal

The Umbrel web UI Terminal starts inside the Umbrel container, so you must enter the host shell first.

1. Log in to the Umbrel web UI.
2. Go to **Settings → Advanced settings → Terminal**.
3. When the terminal opens, enter this first.

```bash
sudo nsenter -t 1 -m -u -i -n -p -- bash
```

Once the prompt changes to `root@umbrel:/#`, you are on the host shell. Then follow **section 12 below** to bring the repository and scripts up to date, and then pick the command that matches the recovery mode the AI recommended from the three options below.

**chainstate rebuild**

```bash
sudo bash scripts/m1s-start-bitcoin-chainstate-rebuild.sh
sudo bash scripts/m1s-check-bitcoin-recovery-status.sh
```

**reindex**

```bash
sudo bash scripts/m1s-start-bitcoin-reindex.sh
sudo bash scripts/m1s-check-bitcoin-recovery-status.sh
```

**full resync**

```bash
sudo bash scripts/m1s-start-bitcoin-full-resync.sh
sudo bash scripts/m1s-check-bitcoin-recovery-status.sh
```

### Shared health check

After starting recovery, repeat the command below to check status.

During reindex, look at **Reindex blk file**, **Reindex file progress**, and **Current status** first.  
If these values go up when you run the same command again a few minutes later, the reindex is actually moving forward.

```bash
sudo bash scripts/m1s-check-bitcoin-recovery-status.sh
```

When run, the output looks like this.

```text
=== ODROID M1S Bitcoin recovery status ===
Script version:           0.5.5
Recovery mode:            reindex
Bitcoin config dir:       /mnt/fullnode/app-data/bitcoin/data/bitcoin
bitcoin.conf:             /mnt/fullnode/app-data/bitcoin/data/bitcoin/bitcoin.conf
umbrel-bitcoin.conf:      /mnt/fullnode/app-data/bitcoin/data/bitcoin/umbrel-bitcoin.conf
debug.log:                /mnt/fullnode/app-data/bitcoin/data/bitcoin/debug.log
State file:               /etc/umbrel-recovery/bitcoin-recovery.json
State file present:       1
Requested at:             2026-05-11T09:08:36.719946+00:00
Active request:           0
Last observed state:      recovery-in-progress
Include banner present:   0
Config reindex present:   0
Config chainstate present:0
Managed request block:    0
Log mode hint:            reindex
Runtime mode hint:        none
Recent startup evidence:  1
RPC getchainstates:       1
RPC getblockchaininfo:    1
Blocks / headers:         0 / 576166
Approx progress:          0.00%
Reindex blk file:         blk01743.dat / blk01799.dat
Reindex file progress:    96.89%
Last file load blocks:    250

Current status: recovery in progress

Recent Bitcoin error hints:
  2026-05-16T02:58:27Z [error] Fatal LevelDB error: IO error: /data/bitcoin/indexes/txindex/048611.ldb: Input/output error

=== System diagnostics ===
Uptime and load:
  19:42:10 up 3 days,  load average: 1.20, 1.05, 0.98

Memory usage:
  Mem:           7.6Gi       3.2Gi       1.1Gi       3.3Gi
  Swap:          4.0Gi       512Mi       3.5Gi

Active swap:
  NAME                    TYPE SIZE USED PRIO
  /mnt/fullnode/swapfile  file   4G 512M   -2

Docker service state:
  active
  active

Recent NVMe timeout snapshots:
  snapshot directory unavailable

=== Storage diagnostics ===
Data dir target:          /mnt/fullnode
Mount source:             /dev/nvme0n1p1
Mount filesystem:         ext4
Mount options:            rw,relatime
Parent block device:      /dev/nvme0n1

Disk space usage:
  Filesystem      Size  Used Avail Use% Mounted on
  /dev/nvme0n1p1  1.8T  870G  850G  51% /mnt/fullnode

Inode usage:
  Filesystem        Inodes IUsed     IFree IUse% Mounted on
  /dev/nvme0n1p1 122101760 98000 122003760    1% /mnt/fullnode

Block device summary:
  NAME        TYPE  SIZE FSTYPE MODEL           MOUNTPOINTS
  nvme0n1     disk  1.8T        Example NVMe
  └─nvme0n1p1 part  1.8T ext4                   /mnt/fullnode

Recent kernel storage hints:
  none visible in recent kernel logs, or kernel log access is restricted

Use this same command again later to watch the live progress estimate.
```

Each field means the following.

- Script version: version of this script
- **Recovery mode**: detected recovery mode (chainstate rebuild / reindex / full resync / unknown)
- Bitcoin config dir: directory containing Bitcoin Core config files
- bitcoin.conf: path to the main Bitcoin Core config file
- umbrel-bitcoin.conf: path to the Umbrel-generated Bitcoin config file
- debug.log: path to the Bitcoin Core runtime log file
- State file present: 1 if a recovery state file exists, 0 otherwise
- Requested at: timestamp when recovery was requested
- Active request: 1 if an unprocessed recovery request is still active, 0 otherwise
- Last observed state: last recorded recovery state
- Config reindex present: 1 if reindex=1 is found in the config files
- Config chainstate present: 1 if reindex-chainstate=1 is found in the config files
- Log mode hint: recovery mode inferred from debug.log
- Runtime mode hint: recovery mode inferred from live RPC/runtime signals
- Recent startup evidence: 1 if the log shows Bitcoin restarted after the request
- RPC getchainstates: whether the bitcoin-cli getchainstates call succeeded
- RPC getblockchaininfo: whether the bitcoin-cli getblockchaininfo call succeeded
- **Blocks / headers**: currently synced block count / total known header count
- **Approx progress**: approximate block sync progress percentage. During reindex, this value may stay at `0.00%` for a long time, so in that case it is more accurate to check **Reindex blk file** and **Reindex file progress** together.
- Reindex blk file: current `blkXXXXX.dat` file being re-read / last `blkXXXXX.dat` file present on disk
- Reindex file progress: approximate reindex position based on Bitcoin block files. If this value rises over time, the reindex is actually moving forward.
- Last file load blocks: number of blocks loaded from the most recent `blkXXXXX.dat` file
- **Current status**: human-readable summary of the current recovery state
- **Recent Bitcoin error hints**: filters the end of `debug.log` for recent LevelDB, txindex, chainstate, Fatal, and I/O error lines.
- **System diagnostics**: shows load, memory, swap, Docker service state, and whether prior NVMe timeout snapshots exist, so resource pressure or Docker-level problems can be considered too.
- **Storage diagnostics**: shows which device backs `/mnt/fullnode`, whether disk and inode space are available, which block device is involved, and, when available, NVMe/SMART health plus recent kernel storage hints.
- **Recent kernel storage hints**: if NVMe timeout, reset, I/O error, or EXT4 error appears here, the problem may be SSD/NVMe/filesystem-level rather than only a Bitcoin index issue. Copy the full output for diagnosis.

---

## 11. Safe shutdown

When turning off the ODROID M1S, **do not unplug the power cable abruptly**.

If you suddenly cut power while the Bitcoin node is running, Bitcoin data on the SSD may become corrupted. On the next boot, the Bitcoin app may spend a long time repairing data or may need to synchronize again.

To shut down, use the Umbrel web UI in this order.

```text
Settings → Shut down
```

On a Korean UI, it may appear like this.

```text
설정 → 종료
```

When you press the shutdown button, the safe-shutdown settings applied by this installation script first clean up the Bitcoin node app and Umbrel containers, and prevent Docker from immediately starting them again. When the process completes normally, the screen changes to the following message.

```text
Shutdown complete
It is now safe to disconnect power.
```

When you see this message, you may unplug the power cable even if the device itself does not appear to be fully powered off.

If the screen still only shows **“Shutting down...”** after more than 2 minutes, open the following address again in a new tab.

```text
http://umbrel.local
```

If the new tab cannot open the Umbrel screen, the Umbrel container has stopped. In that case, you may also unplug the power cable.

To use the device again, connect the power cable. During boot, the automatic recovery service restores Umbrel's autostart setting and starts Umbrel again.

---

## 12. Update an already-installed device to the latest version

This is how to bring an ODROID M1S that was already installed once up to the latest script version. Enter the following commands exactly as shown, from top to bottom.

```bash
cd /home/*/odroid-m1s-umbrel-recovery
sudo git -c safe.directory="$(pwd)" fetch origin
sudo git -c safe.directory="$(pwd)" reset --hard origin/main
sudo bash scripts/m1s-update-umbrel.sh --check
sudo bash scripts/m1s-update-umbrel.sh
```

What each line does:

1. `cd /home/*/odroid-m1s-umbrel-recovery` — moves into the repository folder downloaded during the first installation. The asterisk (`*`) means "automatically find any username," so you do not need to type the username manually.
2. `sudo git -c safe.directory="$(pwd)" fetch origin` — fetches the latest changes from the GitHub remote repository.
3. `sudo git -c safe.directory="$(pwd)" reset --hard origin/main` — resets the local files to match the latest GitHub `origin/main`. This also replaces the local updater script itself with the latest version.
4. `sudo bash scripts/m1s-update-umbrel.sh --check` — changes nothing and only shows the **currently installed version, latest version, and list of changes that will be applied**. If it is already up to date, it will show a message like "No migrations needed."
5. `sudo bash scripts/m1s-update-umbrel.sh` — actually applies the update. If it is already up to date, it exits without doing anything.

If the `--check` output says `Script version` is `0.5.6` or older and immediately exits with “No migrations needed,” that device does not have the auto-sync updater yet. In that case only, run the following two lines **once**, then run the 5-line updater flow above again.

```bash
sudo git -c safe.directory="$(pwd)" fetch origin
sudo git -c safe.directory="$(pwd)" reset --hard origin/main
```

During the update, the Umbrel screen may not open for a short time. The script first checks that the SSD is properly connected at `/mnt/fullnode`, then updates only the necessary parts while keeping the existing data location intact.

Internally, it applies the required steps from the currently installed version to the latest version in order. If a step fails, it records the steps that already succeeded and stops. After fixing the problem, you can safely run the same command again to continue.

Existing passwords, app data, and Bitcoin node data are not touched, and it is safe to run the update multiple times.

### 12-1. Optional: run the same update from inside the Umbrel web UI terminal (advanced)

This step is **optional**. The SSH method in step 12 is the default path and is the simplest approach.

However, if preparing an SSH environment is difficult, for example if you only have a phone or cannot install a separate terminal app, you can use the **terminal built into the Umbrel web UI** to do the same work.

The steps are as follows.

1. Log in to the Umbrel web UI.
2. Go to **Settings → Advanced settings → Terminal**. On a Korean UI, this may appear as **설정 → 고급 설정 → 터미널**.
3. When the terminal opens, first enter the following one-line command.

```bash
sudo nsenter -t 1 -m -u -i -n -p -- bash
```

This command enters the shell **outside the Umbrel container, on the ODROID M1S host**. In other words, it puts you in the same place as connecting directly by SSH.

The first time, you may see a password prompt like this.

```text
[sudo] password for umbrel:
```

Enter the **same password you use to log in to the Umbrel web UI**. It is normal that nothing appears while you type the password.

If the password is correct, the prompt changes to something like `root@umbrel:/#`. This means you are now in the host shell.

```text
root@umbrel:/#
```

From this state, enter the commands below exactly as shown. This is the same command set used in the SSH method.

```bash
cd /home/*/odroid-m1s-umbrel-recovery
sudo git -c safe.directory="$(pwd)" fetch origin
sudo git -c safe.directory="$(pwd)" reset --hard origin/main
sudo bash scripts/m1s-update-umbrel.sh --check
sudo bash scripts/m1s-update-umbrel.sh
```

When the work finishes, close the terminal window as usual. As with the SSH method, data, passwords, and apps are preserved.

Be careful about the following points.

- This method enters a shell with host-level permissions, so **do not type unknown commands other than the commands shown in this guide**. This has the same responsibility scope as connecting by SSH.
- This method may stop working if Umbrel or Docker images change in the future. If that happens, use the SSH method in step 12.

---

## 13. Run updates that may require a kernel/system reboot

Sometimes Ubuntu security updates or kernel-adjacent updates only fully apply after a reboot.

This does not delete Umbrel app data or Bitcoin node data. However, Umbrel and the Bitcoin node will stop temporarily during the update and reboot.

This repository includes a one-command helper for that job. The helper works in this order:

1. Refreshes the Ubuntu package list.
2. Checks currently running Docker containers.
3. Shows a warning when Bitcoin-related containers are running.
4. Gracefully stops running Docker containers.
5. Applies Ubuntu package upgrades.
6. Automatically reboots if the system says a reboot is required.
7. Starts the stopped containers again if no reboot is required.

If your Bitcoin node is doing IBD (Initial Block Download), block download, reindex, or recovery work, the script will stop the containers gracefully, but that work will still be interrupted. If possible, run this when those jobs are not actively in progress.

### 13-1. Direct terminal or SSH method

If you connected to the ODROID M1S by SSH, or logged in directly with a monitor and keyboard, enter the following commands from top to bottom.

```bash
cd /home/*/odroid-m1s-umbrel-recovery
sudo git -c safe.directory="$(pwd)" fetch origin
sudo git -c safe.directory="$(pwd)" reset --hard origin/main
sudo bash scripts/m1s-update-system-packages.sh
```

What each line does:

1. `cd /home/*/odroid-m1s-umbrel-recovery` — moves into the repository folder downloaded during the first installation.
2. `sudo git -c safe.directory="$(pwd)" fetch origin` — fetches the latest changes from the GitHub remote repository.
3. `sudo git -c safe.directory="$(pwd)" reset --hard origin/main` — resets local files to match the latest GitHub `origin/main` state.
4. `sudo bash scripts/m1s-update-system-packages.sh` — safely stops Docker containers, applies Ubuntu package updates, and automatically reboots if needed.

If a reboot happens, the SSH connection will disconnect. Wait about 1-3 minutes, then open this address again in a browser:

```text
http://umbrel.local
```

If `umbrel.local` does not open, check the ODROID M1S IP address in Fing or your router page, then open `http://<device IP>`.

### 13-2. Umbrel web UI Advanced Terminal method

If SSH is difficult, you can do the same work from the Terminal inside the Umbrel web UI.

The steps are as follows.

1. Log in to the Umbrel web UI.
2. Go to **Settings → Advanced settings → Terminal**. On a Korean UI, this may appear as **설정 → 고급 설정 → 터미널**.
3. When the terminal opens, first enter the following command to enter the host shell.

```bash
sudo nsenter -t 1 -m -u -i -n -p -- bash
```

When the prompt changes to something like `root@umbrel:/#`, enter the following commands in order.

```bash
cd /home/*/odroid-m1s-umbrel-recovery
sudo git -c safe.directory="$(pwd)" fetch origin
sudo git -c safe.directory="$(pwd)" reset --hard origin/main
sudo bash scripts/m1s-update-system-packages.sh
```

If the script reboots the device, the web terminal connection will disconnect. Wait about 1-3 minutes, then reconnect through `http://umbrel.local` or the device IP address.

Be careful about the following points.

- During reboot, the Umbrel web UI will not open. Wait a little and try again.
- If the Bitcoin node is doing IBD, download, recovery, or reindex work, it is better to run this after the work is in a stable state.
- This updates Ubuntu system packages. It is different from the repository script update in step 12, so you may need both procedures.

---

## 14. More detailed resources

After installation, if you want to learn more, see the following resources.

- **Official ODROID M1S wiki (Hardkernel)** — https://wiki.odroid.com/odroid-m1s/odroid-m1s
  - Official documentation for ODROID M1S hardware specifications, booting, Ubuntu installation, and related topics.
- **Umbrel OS user guide (PDF, Korean)** — https://philemon21.com/wp-content/uploads/2026/01/3.-%ED%92%80-%EB%85%B8%EB%93%9C-%EC%9A%B4%EC%98%81-%EA%B0%80%EC%9D%B4%EB%93%9C-v.2.1-2025.-9.-1.pdf
  - A Korean guide that may be useful after installation when operating Umbrel.
