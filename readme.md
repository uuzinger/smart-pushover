# SMART Pushover Monitor

A lightweight Ubuntu-friendly Bash script that monitors disk health using `smartctl` and sends **Pushover notifications** when SMART indicates trouble.

Designed for real servers, not laptops:
- Works correctly with **HBAs, backplanes, and SATA bridges**
- Automatically applies the correct `smartctl -d <type>` per disk
- Prevents alert spam with **per-device cooldowns**
- Fails loudly if alerting is misconfigured (no silent failures)
---

## Features

- Discovers disks via `smartctl --scan-open`
- Correctly handles:
  - SATA disks behind HBAs (`-d sat`)
  - NVMe devices (`-d nvme`)
- Alerts on:
  - SMART overall health failures
  - Critical SMART attributes:
    - `Reallocated_Sector_Ct`
    - `Current_Pending_Sector`
    - `Offline_Uncorrectable`
  - NVMe wear indicators:
    - `Percentage Used ≥ 90%`
    - `Available Spare ≤ 10%`
  - Non-empty SMART error logs (when supported)
- Notifications include:
  - Hostname
  - Device path
  - Device type
  - Model and serial number
- Cooldown logic prevents repeated alerts for the same issue

---

## Requirements

- Ubuntu (tested on modern LTS releases)
- Root privileges
- Packages:

```bash
sudo apt-get install -y smartmontools curl
```

- A Pushover account with:
  - User Key
  - Application Token

---

## Installation

### 1. Install the script

```bash
sudo install -m 0755 smart_pushover.sh /usr/local/sbin/smart_pushover.sh
```

### 2. Create the environment file

```bash
sudo nano /etc/smart_pushover.env
```

Example contents:

```bash
export PUSHOVER_USER_KEY="uXXXXXXXXXXXXXXXXXXXX"
export PUSHOVER_APP_TOKEN="aXXXXXXXXXXXXXXXXXXXX"

# Optional tuning
export COOLDOWN_SECONDS=21600   # 6 hours
export STATE_DIR=/var/tmp/smart_pushover_state
```

Secure the file (important):

```bash
sudo chown root:root /etc/smart_pushover.env
sudo chmod 600 /etc/smart_pushover.env
```

---

## Manual Test

Run once manually to verify everything works:

```bash
sudo bash -c 'source /etc/smart_pushover.env; /usr/local/sbin/smart_pushover.sh'
```

### Expected behavior

Healthy disks:

```text
OK: /dev/sda
OK: /dev/sdb
...
```

Unhealthy disks:
- Immediate Pushover notification
- Script output noting that an alert was sent

No notification means no problems.

---

## Cron Setup (Recommended)

Add an hourly cron job as root:

```bash
sudo crontab -e
```

```cron
0 * * * * /bin/bash -c 'source /etc/smart_pushover.env && /usr/local/sbin/smart_pushover.sh' >/dev/null 2>&1
```
---

## Device Detection

The script uses:

```bash
smartctl --scan-open
```

Example output:

```text
/dev/sda -d sat
/dev/sdb -d sat
/dev/nvme0 -d nvme
```
---

## Cooldown Logic

To prevent alert storms:
- Each unique **device + issue signature** creates a cooldown stamp
- Default cooldown: **6 hours**
- Controlled via `COOLDOWN_SECONDS`

This ensures:
- New problems alert immediately
- Repeated alerts for the *same issue* are suppressed
- Escalations still trigger alerts when the failure mode changes

---

## Failure Behavior (Intentional)

The script exits with an error if:
- Pushover credentials are missing or placeholders
- Required tools (`smartctl`, `curl`) are unavailable

Silent disk-monitoring failures are worse than noisy ones.

---

## Notes

- Must be run as **root** to access SMART data on many devices
- USB/SATA bridges and HBAs are fully supported
- NVMe wear thresholds follow common industry guidance

---

## Possible Enhancements

This script is intentionally minimal, but can be extended to:
- Map `/dev/sdX` → `/dev/disk/by-id` → physical bay
- Track SMART attribute trends over time
- Escalate alert priority as values increase
- Export JSON for LibreNMS or Prometheus
- Schedule and monitor SMART self-tests
