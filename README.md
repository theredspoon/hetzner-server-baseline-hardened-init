# Hetzner Ubuntu Server Baseline

Runbook and automation for turning a fresh Hetzner Ubuntu 24.04 server into a hardened, reusable baseline snapshot for later application deployment.

Target:
- Ubuntu 24.04 LTS
- Fresh Hetzner Cloud VPS
- Single-operator server baseline

This repo contains:
- [`RUNBOOK-hetzner-server-setup.md`](/Users/nim/Projects/hetzner-server-hardened-init/RUNBOOK-hetzner-server-setup.md): full manual procedure and rationale
- [`setup-hetzner-server.sh`](/Users/nim/Projects/hetzner-server-hardened-init/setup-hetzner-server.sh): automation for runbook sections 3–12 plus verification and snapshot workflow

## What The Script Does

The script automates:
- SSH hardening, including `AllowUsers`, root-password lock, and VS Code-compatible SSH tunneling settings
- package updates, unattended-upgrades, Docker origin, and `needrestart`
- UFW and fail2ban
- logwatch, auditd, and operator tools
- swap creation
- Docker install, local log driver, and weekly prune timer
- sysctl hardening
- postfix availability for local mail delivery
- restic installation
- hostname prompt during setup
- verification output for runbook section 14
- snapshot hygiene and Hetzner API-based snapshot creation

The script does not automate:
- initial root access and rescue-console recovery
- creation of the non-root sudo user
- application deployment
- SMTP relay credentials
- restic repository credentials
- application secrets, TLS keys, or DNS credentials

## Before You Run It

Complete runbook sections 1–2 first:
1. Create the server and establish SSH access.
2. Create a non-root user and add it to the `sudo` group.
3. Confirm you can log in as that non-root user and run `sudo`.

Important constraints:
- Run the script as the non-root sudo user, not `root`.
- The first positional argument must be that same username.
- The script is idempotent, so re-running is expected after reboots or partial completion.

## Copying The Script To A Server

Example:

```bash
scp /Users/nim/Projects/hetzner-server-hardened-init/setup-hetzner-server.sh <user>@<server-ip>:~
ssh <user>@<server-ip>
chmod +x ~/setup-hetzner-server.sh
```

You can also clone the repo on the server and run the script from the repo directory.

## Command Reference

Basic setup:

```bash
./setup-hetzner-server.sh <username>
```

Custom swap size:

```bash
./setup-hetzner-server.sh <username> 4
```

Verification only:

```bash
./setup-hetzner-server.sh <username> --verify
```

Snapshot workflow:

```bash
./setup-hetzner-server.sh <username> --snapshot ubuntu-24.04-hardened-init-baseline-$(date +%Y%m%d)
```

Allow loose `rp_filter` when intentional multi-path routing exists, such as Tailscale:

```bash
./setup-hetzner-server.sh <username> --verify --allow-rpfilter-loose
./setup-hetzner-server.sh <username> --snapshot ubuntu-24.04-hardened-init-baseline-$(date +%Y%m%d) --allow-rpfilter-loose
```

Do not use `--allow-rpfilter-loose` on a plain baseline server unless you intentionally configured multi-path routing.

## Recommended First-Time Flow

On a fresh server:

```bash
./setup-hetzner-server.sh <username>
```

During the run, expect:
- a sudo password prompt if sudo credentials are not cached
- package upgrades
- SSH restart after config validation
- Docker installation
- a hostname prompt showing the current hostname and optionally letting you change it

If the script detects a kernel update requiring reboot, it stops after printing a reboot gate. Reboot the server, reconnect, and run the same command again.

After the first full run:
1. Log out and back in so Docker group membership applies.
2. Set timezone to UTC if not already set:

```bash
sudo timedatectl set-timezone UTC
```

3. Run verification:

```bash
./setup-hetzner-server.sh <username> --verify
```

4. If verification is clean, prepare your Hetzner API token and run snapshot mode:

```bash
./setup-hetzner-server.sh <username> --snapshot ubuntu-24.04-hardened-init-baseline-$(date +%Y%m%d)
```

## What `--verify` Does

`--verify` is read-only. It checks or prints:
- timezone and hostname
- time sync status
- SSH directives and `AllowUsers`
- AppArmor, fail2ban, auditd, postfix
- unattended-upgrades timers and config
- `needrestart`
- Docker logging driver and prune timer
- restic installation
- sysctl hardening values
- forbidden snapshot contents such as `/etc/postfix/sasl_passwd`, `/etc/restic/env`, `.env` files in `/opt`, and private keys under `/root` and `/home`
- failed systemd units
- world-writable files on `/`

Behavior:
- `--verify` reports warnings but does not change system state.
- `--snapshot` runs `--verify` internally and hard-fails if any warnings are present.

## What `--snapshot` Does

`--snapshot <name>` performs:
1. verification
2. snapshot hygiene
3. interactive API token prompt
4. Hetzner API call to create a snapshot

Snapshot mode will block if:
- verification produced warnings
- forbidden files are found during hygiene
- the snapshot name is invalid
- Hetzner metadata cannot identify the server
- the Hetzner API rejects the request

Snapshot mode expects:
- you are running on the target Hetzner server
- `jq` is available
- your Hetzner API token has Read & Write permissions

During snapshot hygiene, the script:
- clears shell history
- clears apt caches
- prunes Docker builder cache
- regenerates `/etc/machine-id`
- removes the systemd random seed
- hard-fails if forbidden credentials, env files, or private keys are found

After the API call succeeds, the script deletes itself and the server powers off for snapshot creation.

## `rp_filter` Policy

Baseline expectation:
- primary interface `rp_filter = 1`

Allowed exception:
- `rp_filter = 2` only when intentional multi-path routing exists, for example Tailscale, subnet routing, multiple interfaces, or policy routing

Never acceptable:
- `rp_filter = 0`

If the host intentionally uses multi-path routing, use:

```bash
./setup-hetzner-server.sh <username> --verify --allow-rpfilter-loose
./setup-hetzner-server.sh <username> --snapshot ubuntu-24.04-hardened-init-baseline-$(date +%Y%m%d) --allow-rpfilter-loose
```

## Idempotency And Recovery

The script is designed to be re-run safely.

Examples:
- If the server reboots after package upgrades, re-run the same setup command.
- If some packages were already installed, the script skips them.
- If config files already match the expected state, the script leaves them unchanged.
- If Docker, fail2ban, auditd, or postfix are already enabled, the script verifies and continues.

The script also records changed files during setup and prints a diff-style change report at the end of a normal run.

## Post-Snapshot Expectations

The baseline snapshot must not include:
- `/etc/postfix/sasl_passwd`
- `/etc/restic/env`
- application secrets
- TLS private keys
- DNS provider credentials
- arbitrary `.env` files in `/opt`
- stray private SSH keys under `/root` or `/home`

These belong in later deployment or application-specific runbooks, not in the baseline image.

## Operator Notes

- SSH config is validated with `sshd -t` before restart.
- Docker group membership does not apply to the current shell until you log out and back in.
- The script prompts for hostname during the main setup run, but timezone remains a manual operator choice.
- The script summary at the end prints the exact follow-up `--verify` and `--snapshot` commands to use, including `--allow-rpfilter-loose` when applicable.
