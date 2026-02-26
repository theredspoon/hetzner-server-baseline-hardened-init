# Hetzner Ubuntu Server Baseline

Runbook and automation script for hardening a fresh Hetzner Ubuntu 24.04 server into a reusable base snapshot. The snapshot serves as the starting point for application deployments.

**Target:** Ubuntu 24.04 LTS on a fresh VPS (2 vCPU, ≥4GB RAM recommended) [tested on Hetzner Cloud]

---

## Repo contents

| File | Description |
|---|---|
| `RUNBOOK-hetzner-server-setup.md` | Step-by-step procedure, sections 1–14 |
| `setup-hetzner-server.sh` | Automates sections 3–12 of the runbook |

---

## What the script configures

| Section | What it does |
|---|---|
| 3 | SSH hardening — disables root login/password auth, keeps agent forwarding off, enables TCP forwarding for VS Code SSH tunneling; sets AllowUsers, MaxAuthTries, LoginGraceTime; locks root password |
| 4 | Package updates, unattended-upgrades with Docker and -updates origins, needrestart automatic mode |
| 5 | UFW firewall — default deny incoming, rate-limit SSH |
| 6 | Fail2ban — SSH jail |
| 7 | logwatch, auditd with Ubuntu ruleset, operator toolkit (htop, curl, jq, lsof, ncdu, rsync, git) |
| 8 | Swap file (default 2G, configurable) |
| 9 | Docker with local log driver, weekly prune timer |
| 10 | Kernel hardening via sysctl — rp_filter, SYN cookies, suid_dumpable |
| 11 | Postfix — confirms running for local mail delivery; relay credentials are post-deployment |
| 12 | restic — installed; repository credentials are post-deployment |

Sections 1–2 (initial access, user creation) are manual prerequisites. Section 13 is informational. Section 14 is the pre-snapshot checklist.

---

## Usage

### Prerequisites

Complete sections 1–2 of the runbook manually:
1. Boot the server and establish SSH key access
2. Create a non-root user and add to the sudo group

### Run

Copy the script to the server and run it as the non-root sudo user:

```bash
scp setup-hetzner-server.sh <user>@<server-ip>:~
ssh <user>@<server-ip>
chmod +x ~/setup-hetzner-server.sh
~/setup-hetzner-server.sh <username> [swap_size_gb]
```

Default swap size is 2G. To use a different size:

```bash
~/setup-hetzner-server.sh <username> 4
```

### Verify

Run without making changes to print the current state of all hardened components:

```bash
~/setup-hetzner-server.sh <username> --verify
```

### Idempotency

The script is safe to re-run. Every step checks current state before acting — already-correct configuration is skipped. If a kernel upgrade triggers a reboot gate mid-run, reboot and re-run; completed steps will be skipped automatically.

---

## Snapshot procedure

After the script completes, follow the manual steps printed in the summary:

```bash
sudo timedatectl set-timezone UTC
sudo hostnamectl set-hostname <hostname>
~/setup-hetzner-server.sh <username> --verify
rm ~/setup-hetzner-server.sh
```

Then complete section 14 of the runbook (snapshot hygiene) and take the snapshot from the Hetzner console.

Suggested label: `ubuntu-24.04-baseline-YYYYMMDD`

---

## Post-snapshot configuration

The following are intentionally excluded from the snapshot and configured during application deployment:

- Postfix relay credentials (`/etc/postfix/sasl_passwd`)
- Restic repository credentials (`/etc/restic/env`)
- TLS certificates and private keys
- Application secrets and API keys
- DNS provider credentials

---

## Notes

- `rp_filter` on the primary interface will show `2` (loose mode) on Hetzner servers — the cloud networking stack sets this and it cannot be overridden from the guest. Mode 2 still provides spoofing protection. The script treats 1 and 2 as both acceptable and only warns on 0.
- The script never removes packages that ship with the stock Hetzner Ubuntu 24.04 image.
- SSH is restarted at the end of section 3 on every run. `sshd -t` validates the config before any restart — a broken config will abort with an error rather than dropping your session.
