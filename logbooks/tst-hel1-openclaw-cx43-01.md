# Server Logbook: tst-hel1-openclaw-cx43-01

**Location:** Hetzner Cloud (HEL1)  
**Type:** CX43 (4 vCPU, 16 GB RAM)  
**OS:** Ubuntu 24.04 LTS  
**Created:** 2026-03-06  
**User:** finless1strepair  

---

## Hardening Procedure Results

**Date:** Fri Mar 6 02:28:03 PM UTC 2026  
**Script:** setup-hetzner-server.sh  
**Swap:** 2G

```
  ✓ Preflight passed — user: finless1strepair, swap: 2G
  · Change tracking enabled: /tmp/hetzner-setup-changes.8lpBk6
```

---

### Section 3: SSH Hardening

| Setting | Status |
|---------|--------|
| PermitRootLogin no | ✓ already set |
| PasswordAuthentication no | ✓ already set |
| PermitEmptyPasswords no | ✓ already set |
| PubkeyAuthentication yes | ✓ already set |
| ChallengeResponseAuthentication no | ✓ updated |
| X11Forwarding no | ✓ already set |
| AllowAgentForwarding no | ✓ already set |
| AllowTcpForwarding yes | ✓ already set |
| AllowStreamLocalForwarding yes | ✓ already set |
| PermitOpen any | ✓ already set |
| MaxAuthTries 3 | ✓ already set |
| LoginGraceTime 30 | ✓ already set |
| AllowUsers finless1strepair | ✓ added |

**Changes:**
- SSH service restarted
- Root password locked

**SSH Host Key Fingerprint (ED25519):**
```
256 SHA256:UGoYMWpydaxirxqCwMP4KpgayRXKM8c9nvazZWa0QtQ root@tst-hel1-openclaw-cx43-01 (ED25519)
```

---

### Section 4: Package Updates & Unattended Upgrades

- ✓ System packages up to date
- ✓ ca-certificates installed
- ✓ unattended-upgrades enabled
- ✓ -updates origin active
- ✓ Docker origin present
- ✓ Unattended-upgrades scalar override configured
- ✓ needrestart set to automatic

**Packages upgraded:**
- curl (8.5.0-2ubuntu10.7)
- docker-ce (5:29.3.0-1)
- docker-ce-cli (5:29.3.0-1)
- docker-ce-rootless-extras (5:29.3.0-1)
- docker-compose-plugin (5.1.0-1)
- docker-model-plugin (1.1.8-1)
- libcurl3t64-gnutls (8.5.0-2ubuntu10.7)
- libcurl4t64 (8.5.0-2ubuntu10.7)
- linux-tools-common (6.8.0-101.101)
- python3-software-properties (0.99.49.4)
- software-properties-common (0.99.49.4)

**Kept back:** linux-image-virtual

---

### Section 5: Firewall (UFW)

```
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), deny (routed)
New profiles: skip

To                         Action      From
--                         ------      ----
22/tcp (OpenSSH)           LIMIT IN    Anywhere
22/tcp (OpenSSH (v6))      LIMIT IN    Anywhere (v6)
```

---

### Section 6: Fail2ban

- ✓ fail2ban installed and running
- ✓ sshd jail active

---

### Section 7: Monitoring & Auditing

**logwatch:**
- ✓ Installed
- ✓ Cron present
- ✓ Detail level: Med

**auditd:**
- ✓ Installed
- ✓ Rules file: `/etc/audit/rules.d/10-ubuntu-base.rules`
- ✓ 19 rule lines active

**Operator Toolkit:**
- htop, curl, jq, lsof, ncdu, rsync, bash-completion, git, netcat-openbsd

---

### Section 8: Swap

```
               total        used        free      shared  buff/cache   available
Mem:            15Gi       1.4Gi        11Gi       4.8Mi       2.4Gi        13Gi
Swap:          2.0Gi          0B       2.0Gi
```

- ✓ Swapfile active (2G)
- ✓ Entry in /etc/fstab

---

### Section 9: Docker

- ✓ Docker 29.3.0 installed
- ✓ User `finless1strepair` in docker group
- ✓ Docker enabled and started
- ✓ Log driver: local
- ✓ docker-prune.timer enabled (weekly)

---

### Section 10: Kernel Hardening (sysctl)

- ✓ sysctl hardening rules applied
- ✓ net.ipv4.tcp_syncookies = 1
- ✓ fs.suid_dumpable = 0
- ✓ net.ipv4.conf.eth0.rp_filter = 1 (strict mode)

---

### Section 11: Outbound Email (Postfix)

- ✓ Postfix 3.8.6 installed and running
- Relay credentials configured post-deployment

---

### Section 12: Backups (Restic)

- ✓ restic 0.16.4 installed
- Object Storage credentials and repository init are post-deployment

---

## Change Report

**State changes applied:**
1. Updated sshd directive: ChallengeResponseAuthentication no
2. Added AllowUsers finless1strepair
3. Restarted service: ssh
4. Locked root password
5. Updated file content: `/etc/apt/apt.conf.d/51unattended-upgrades-local`
6. Set UFW default policies: deny incoming, allow outgoing
7. Restarted service: auditd
8. Enabled and started timer: docker-prune.timer
9. Applied sysctl settings

**File diffs:**

`/etc/apt/apt.conf.d/51unattended-upgrades-local`:
```diff
-// Mail root on error (forwarded externally once msmtp is configured)
+// Mail root on error (relayed externally once postfix relay is configured)
```

`/etc/ssh/sshd_config`:
```diff
-#       ChallengeResponseAuthentication no
+ChallengeResponseAuthentication no
 #       AllowUsers finless1strepair
+AllowUsers finless1strepair
```

---

## Post-Hardening Checklist

- [x] Hardening script completed
- [ ] Log out and back in (docker group takes effect)
- [ ] Set timezone: `sudo timedatectl set-timezone UTC`
- [ ] Set hostname: `sudo hostnamectl set-hostname tst-hel1-openclaw-cx43-01`
- [ ] Run verify: `~/setup-hetzner-server.sh finless1strepair --verify`
- [ ] Delete script: `rm ~/setup-hetzner-server.sh`
- [ ] Run snapshot hygiene (section 14 of runbook)
- [ ] Take snapshot in Hetzner console

---

## Notes

- Server baseline created from Hetzner Ubuntu 24.04 image
- SSH key-based authentication only
- UFW firewall active with rate-limited SSH
- Automatic security updates enabled
- Weekly Docker cleanup scheduled
