# RUNBOOK: Hetzner Ubuntu Server Setup

> **Runbook:** A reusable step-by-step procedure. Follow this when setting up a new server. Replace placeholders like `<username>`, `<ip>`, `<key-name>` with actual values, then record them in the corresponding LOGBOOK file.

## Use Case

This runbook produces a hardened, clone-safe Ubuntu 24.04 LTS base image for a Hetzner VPS (tested on CX23, 4GB RAM). It is designed for single-operator servers running a small number of Dockerized services with no public user registration.

**Scope:** Base OS hardening, package automation, firewall, intrusion prevention, monitoring hooks, container runtime, and backup infrastructure. No application-specific configuration is included. Application deployment is handled by separate runbooks that build on this base snapshot.

**Not suited for:** Multi-tenant servers, servers requiring PCI/HIPAA/SOC2 compliance, high-traffic public services, or environments requiring rootless Docker or mandatory access control beyond AppArmor.

---

## 1. Initial Access

### Preferred path — SSH key added at provisioning

Add your public key in Hetzner Cloud Console before creating the server. Hetzner injects it into `/root/.ssh/authorized_keys` at boot. Connect directly:

```bash
ssh root@<ip>
```

No password is set or emailed in this case.

### Recovery path — SSH key forgotten at provisioning

**If you have the root password** (Hetzner emails it when a server is created without an SSH key):

```bash
ssh root@<ip>
```

Enter the password when prompted. Then add your public key on the server:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo '<your-public-key>' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

**If you don't have the root password:**

Open Hetzner Cloud Console → select the server → click the console icon (top right) to open the browser-based VNC console. If you need to reset the root password first, go to the server's Rescue tab → Reset Root Password. Log in via VNC, then add your public key as above.

Once key access is confirmed, proceed to section 2. Root password locking is handled there after the non-root user is set up.

---

## 2. Non-Root User Setup

```bash
adduser <username>
usermod -aG sudo <username>
```

Copy SSH key to new user:
```bash
mkdir -p /home/<username>/.ssh
cp ~/.ssh/authorized_keys /home/<username>/.ssh/
chown -R <username>:<username> /home/<username>/.ssh
chmod 700 /home/<username>/.ssh
chmod 600 /home/<username>/.ssh/authorized_keys
```

Verify sudo works:
```bash
sudo whoami  # should return: root
```

Lock the root password — root login is already blocked via SSH but locking the password adds defense-in-depth against local escalation:
```bash
sudo passwd -l root
```

---

## 3. SSH Hardening

Apply hardened SSH configuration. Security posture should be explicit and declarative, not dependent on implied defaults:

```bash
sudo nano /etc/ssh/sshd_config
```

Set or confirm the following directives (uncomment and edit as needed):
```
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
MaxAuthTries 3
LoginGraceTime 30
AllowUsers <username>
```

`AllowUsers` explicitly restricts SSH to the named user(s). Prevents any future system or service account from being able to log in even if it somehow acquired a key.

Restart SSH (Ubuntu 24.04 uses `ssh` not `sshd`):
```bash
sudo systemctl restart ssh
```

**Note:** `AllowTcpForwarding no` blocks SSH tunneling. If a specific application requires SSH port forwarding later, re-enable explicitly for that use case. `LoginGraceTime` may need to be increased if automated SSH scripts or CI/CD are added.

Record the server's SSH host key fingerprint in the LOGBOOK — used to verify identity on future connections:
```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

---

## 4. Package Updates

```bash
sudo apt update && sudo apt upgrade -y
sudo reboot  # if kernel was updated
```

Verify `ca-certificates` is installed — required for HTTPS connections from apt and curl:
```bash
dpkg -l ca-certificates || sudo apt install -y ca-certificates
```

Enable unattended upgrades:
```bash
sudo dpkg-reconfigure --priority=low unattended-upgrades
# Select: Yes
```

Configure cleanup and automatic reboot in `/etc/apt/apt.conf.d/50unattended-upgrades`. Find and uncomment these lines:

```
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}:${distro_codename}-updates";    // uncomment this line
    ...
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
Unattended-Upgrade::Mail "root";
Unattended-Upgrade::MailOnlyOnError "true";
```

`Mail "root"` routes failure notifications to the local root mailbox. Once postfix relay is configured post-deployment, these will be forwarded externally automatically.

Also add this line to the `Allowed-Origins` block:
```
"origin=Docker,codename=${distro_codename},label=Docker CE";
```

Verify timers are active after configuration:
```bash
systemctl list-timers | grep apt-daily
```

### needrestart — Automatic Service Restart

Ubuntu 24.04 ships with `needrestart`, which detects services that need restarting after library updates. Default interactive mode blocks or falls back to list-only in unattended context. Set it to automatic:

```bash
sudo nano /etc/needrestart/needrestart.conf
```

Find and replace:
```
#$nrconf{restart} = 'i';
```
with:
```
$nrconf{restart} = 'a';
```

---

## 5. Firewall — ufw (Uncomplicated Firewall)

Set default policies explicitly — deny all inbound, allow all outbound. These are Ubuntu defaults but declaring them makes intent clear and protects against accidental profile changes:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw limit OpenSSH
sudo ufw enable
sudo ufw status verbose
```

`ufw limit` rate-limits repeated connection attempts at the firewall layer, complementing fail2ban — UFW throttles immediately, fail2ban bans after threshold.

**Note on Docker:** Docker bypasses ufw by default — it writes iptables rules directly. Containers that expose ports with `-p` will be publicly accessible regardless of ufw rules. Use `--network internal` or explicit iptables rules if containers should not be publicly exposed.

---

## 6. Fail2ban — Intrusion Prevention

Monitors log files and temporarily bans IPs that show repeated failed login attempts.

```bash
sudo apt install fail2ban -y
sudo systemctl enable fail2ban
sudo systemctl start fail2ban
```

Verify the SSH jail is active:
```bash
sudo fail2ban-client status sshd
```

The output should show an active jail with a `Journal matches` line. If the jail isn't listed, fail2ban is running but not monitoring SSH.

---

## 7. Monitoring & Auditing

### logwatch — Daily Log Summarizer

Parses system logs daily and writes a human-readable summary. Read it manually when needed — useful for spotting anomalies after an incident.

```bash
sudo apt install -y logwatch
# Mail configuration: Local only
# Mail name: <hostname>
```

Verify it works:
```bash
sudo logwatch --detail Med --range today
```

Configure detail level:
```bash
sudo mkdir -p /etc/logwatch/conf
sudo nano /etc/logwatch/conf/logwatch.conf
```

Add this line, then save (Ctrl+O) and exit (Ctrl+X):
```
Detail = Med
```

Valid values: `Low`, `Med`, `High`, or a number 0–10.

### auditd — Linux Kernel Audit System

Records system-level events at the kernel level — file modifications, privilege escalations, sudo usage, kernel module loading. Provides a forensic trail if the server is ever compromised.

```bash
sudo apt install -y auditd
sudo systemctl enable auditd
sudo systemctl start auditd
```

Custom Ubuntu-compatible ruleset (STIG ruleset skipped — designed for RHEL/SELinux, incompatible with Ubuntu/AppArmor):

```bash
sudo tee /etc/audit/rules.d/10-ubuntu-base.rules << 'EOF'
# Delete all existing rules
-D

# Set buffer size
-b 8192

# Ignore errors
-i

# Monitor authentication files
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k identity
-w /etc/sudoers.d/ -p wa -k identity

# Monitor SSH configuration
-w /etc/ssh/sshd_config -p wa -k sshd

# Monitor login/logout
-w /var/log/faillog -p wa -k logins
-w /var/log/lastlog -p wa -k logins

# Monitor sudo usage
-w /usr/bin/sudo -p x -k sudo_usage

# Monitor cron
-w /etc/cron.d/ -p wa -k cron
-w /etc/crontab -p wa -k cron

# Monitor network configuration
-w /etc/hosts -p wa -k network
-w /etc/network/ -p wa -k network

# Monitor ufw
-w /etc/ufw/ -p wa -k firewall

# Privilege escalation
-a always,exit -F arch=b64 -S setuid -F a0=0 -F exe=/usr/bin/su -F key=privilege_escalation
-a always,exit -F arch=b64 -S setresuid -F a0=0 -F exe=/usr/bin/sudo -F key=privilege_escalation

# Kernel modules
-w /sbin/insmod -p x -k modules
-w /sbin/rmmod -p x -k modules
-w /sbin/modprobe -p x -k modules

EOF
sudo augenrules --load
```

Verify rules loaded:
```bash
sudo auditctl -l
sudo systemctl status auditd
```

`failure 1` in the status output is expected — it means log-and-continue on errors, set by `-i` in the ruleset.

### Diagnostics & Operator Toolkit

```bash
sudo apt install -y \
    htop \
    curl \
    jq \
    lsof \
    ncdu \
    rsync \
    bash-completion \
    git \
    netcat-openbsd
```

`ncdu` — interactive disk usage browser (`ncdu /var/log`, arrow keys to navigate). `rsync` — efficient file transfer and backup operations. `bash-completion` — tab completion for apt, git, systemctl, and other tools. `git` — version control; also used by some deployment workflows. `netcat-openbsd` — TCP/UDP debugging, port testing (`nc -zv <host> <port>`).


---

## 8. Swap

Virtual memory on disk — safety net for memory spikes. Prevents OOM (out-of-memory) kills when RAM is exhausted.

```bash
sudo fallocate -l <size>G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

Verify:
```bash
free -h
# Swap line should show expected total, 0B used
```

Consistently high swap usage = need more RAM or tune application memory settings.

---

## 9. Docker — Container Runtime

Runs applications in isolated containers.

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker <username>
sudo systemctl enable --now docker
```

Log out and back in for group membership to take effect. Verify:
```bash
docker run --rm hello-world
docker builder prune -f
docker image prune -f
```

`--rm` removes the container on exit. `docker builder prune -f` removes build cache; `docker image prune -f` removes dangling image layers left by the hello-world pull.

**Note:** Docker group membership is root-equivalent on the host. Acceptable on a single-user server with locked-down SSH. For multi-user servers, consider rootless mode.

### Docker Log Rotation

Without explicit limits, Docker container logs grow unbounded and silently fill disk. Use the `local` driver — handles rotation natively with no additional configuration:

```bash
sudo nano /etc/docker/daemon.json
```

Add:
```json
{
  "log-driver": "local"
}
```

```bash
sudo systemctl restart docker
```

### Docker Housekeeping

Unused images, stopped containers, and dangling layers accumulate silently and consume disk. A systemd timer runs safe cleanup weekly:

```bash
sudo tee /etc/systemd/system/docker-prune.service << 'EOF'
[Unit]
Description=Docker system prune
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/docker system prune -f --filter "until=168h"
EOF

sudo tee /etc/systemd/system/docker-prune.timer << 'EOF'
[Unit]
Description=Weekly Docker system prune

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable docker-prune.timer
sudo systemctl start docker-prune.timer
```

The `--filter "until=168h"` flag limits pruning to resources unused for at least 7 days, protecting recently pulled images. 

What this prune does and does not remove:
- ✓ Removes stopped containers unused for 7+ days
- ✓ Removes unused images unused for 7+ days
- ✓ Removes unused networks
- ✓ Removes build cache
- ✗ Does NOT remove volumes (volumes require explicit `docker volume prune` and should only be done deliberately)
- ✗ Does NOT touch running containers

Verify timer is scheduled:
```bash
sudo systemctl list-timers docker-prune.timer
```

### Docker Policy

- Pin explicit major versions (or major.minor for stateful services) in production. Do NOT use `:latest` except where automated update tooling (e.g. Watchtower) is explicitly configured to manage it, and only for services where that tradeoff is documented.
- Do NOT mount `/var/run/docker.sock` into containers unless strictly required. Any container with socket access is host-root-equivalent.

---

## 10. Kernel Hardening — sysctl

Network-level hardening with no performance overhead:

```bash
sudo tee /etc/sysctl.d/99-hardening.conf << 'EOF'
# IP spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Disable ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# TCP SYN flood protection
net.ipv4.tcp_syncookies = 1

# Prevent privileged process memory leaking to core dumps
fs.suid_dumpable = 0
EOF
sudo sysctl --system
```

Verify applied:
```bash
sysctl net.ipv4.tcp_syncookies fs.suid_dumpable
# Should return 1 for both
```

---

## 11. Outbound Email Alerting — postfix relay

Logwatch and unattended-upgrades write to `/var/mail/root` by default — invisible unless you SSH in. Postfix is installed by default on Ubuntu and handles local mail delivery. Configure it as a satellite relay to forward to an external mailbox post-deployment.

Ensure postfix is installed and running (automated by the setup script):
```bash
sudo apt install -y postfix
sudo systemctl enable --now postfix
postconf -d mail_version
```

**Relay credentials configuration is post-deployment.** Configure `/etc/postfix/sasl_passwd` with your SMTP provider credentials and run `sudo postmap /etc/postfix/sasl_passwd`. Store SMTP credentials in Bitwarden — use an app password, not your account password. See the application runbook for the full relay config block.

---

## 12. Backups

The base server image has no persistent application data — backups are the responsibility of each application's runbook. However, the backup tooling belongs in the base image so it's available when needed.

### Install restic

```bash
sudo apt install -y restic
```

**Object Storage credentials, repository initialization, and backup scripts are post-deployment.** See the application runbook for configuration. The pattern: `source /etc/restic/env`, run backup, ping healthchecks.io on success.

**Note:** Test restoration before relying on any backup. A backup you have never restored from is not a backup you can trust.

---

## 13. What Does NOT Belong in the Snapshot

The snapshot is a template image. The following must be configured post-deployment, never baked in:

- SMTP relay credentials (`/etc/postfix/sasl_passwd`)
- Healthchecks.io ping URLs
- Backup credentials (`/etc/restic/env`)
- TLS certificates and private keys
- Application secrets and API keys
- DNS provider credentials
- Any user-specific SSH keys beyond the operator bootstrap key

If any of these are found during snapshot hygiene, abort and clean before proceeding. The snapshot hygiene block (section 14) includes explicit existence checks for `/etc/postfix/sasl_passwd` and `/etc/restic/env`.

**Backup gate:** A server with persistent application data must not enter production without a tested backup mechanism, a restore procedure, and monitoring of backup job success via Healthchecks.io.

---

## 14. Pre-Snapshot Checklist

### Verify configuration

- [ ] SSH: confirm `PermitRootLogin no`, `AllowTcpForwarding no`, `MaxAuthTries 3`, `AllowUsers <username>` in sshd_config
- [ ] Verify time sync: `timedatectl status` — `systemd-timesyncd` should be active
- [ ] Verify AppArmor is active: `sudo systemctl status apparmor`
- [ ] Verify auditd is running: `sudo systemctl status auditd`
- [ ] Verify fail2ban sshd jail is active: `sudo fail2ban-client status sshd`
- [ ] Verify logwatch cron is present: `ls /etc/cron.daily/00logwatch`
- [ ] Verify unattended-upgrades timers are active: `systemctl list-timers | grep apt`
- [ ] Verify unattended-upgrades cleanup, reboot, Docker origin, and `-updates` are configured in `50unattended-upgrades` (Caddy origin is added in the OpenClaw runbook)
- [ ] Verify needrestart is set to automatic mode in `/etc/needrestart/needrestart.conf`
- [ ] Verify Docker log driver is `local` in `/etc/docker/daemon.json`
- [ ] Verify Docker housekeeping timer is active: `sudo systemctl list-timers docker-prune.timer`
- [ ] Verify sysctl hardening applied: `sysctl net.ipv4.tcp_syncookies fs.suid_dumpable` should return `1` for both
- [ ] Verify postfix is running: `sudo systemctl is-active postfix`
- [ ] Verify restic is installed: `which restic`
- [ ] Set timezone: `sudo timedatectl set-timezone UTC`
- [ ] Set hostname: `sudo hostnamectl set-hostname <hostname>`
- [ ] Record SSH host key fingerprint in LOGBOOK: `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`

### Validation command block

Run and confirm clean output:
```bash
sudo systemctl --failed
sudo ufw status verbose
sudo ss -tulpn
sudo fail2ban-client status sshd
sudo auditctl -l | wc -l
docker info | grep -i "logging driver"
free -h
df -h
sudo find / -xdev -type f -perm -0002 2>/dev/null
sysctl net.ipv4.conf.$(ip route | awk '/default/{print $5; exit}').rp_filter
# Should return 1 — confirms rp_filter applies to the primary interface, not just the defaults
sudo systemctl list-unit-files --state=enabled
# Review for unexpected enabled services before freezing image
```

### Snapshot hygiene

```bash
# Clear shell history (both in-memory and on-disk)
history -c
sudo sh -c 'history -c'
sudo rm -f /root/.bash_history
sudo rm -f /home/<username>/.bash_history

# Clear apt cache and package index (first apt update post-deploy will rebuild lists)
sudo apt clean
sudo rm -rf /var/lib/apt/lists/*

# Clear Docker build cache
docker builder prune -f

# Regenerate machine-id (snapshot will be used as template image)
sudo rm -f /etc/machine-id
sudo systemd-machine-id-setup
# Do NOT reboot between this step and taking the snapshot —
# a reboot regenerates machine-id on the live system, defeating the purpose

# Remove systemd random seed (new instance should generate its own entropy)
sudo rm -f /var/lib/systemd/random-seed

# Confirm no credentials were accidentally written before snapshot
sudo test -f /etc/postfix/sasl_passwd && echo "WARNING: /etc/postfix/sasl_passwd exists — remove before snapshot" || echo "OK"
sudo test -f /etc/restic/env && echo "WARNING: /etc/restic/env exists — remove before snapshot" || echo "OK"
sudo find /opt -name "*.env" -o -name "env" 2>/dev/null -print0 | xargs -0 -r ls -la
# Review any results — no credential files should be present

# Check for accidentally stored private keys
sudo find /root /home -name "id_rsa*" -o -name "id_ed25519*" 2>/dev/null
```

Take the Hetzner snapshot immediately after hygiene steps. Label it with date and OS version.
