#!/usr/bin/env bash
# =============================================================================
# setup-hetzner-server.sh
# Automates RUNBOOK-hetzner-server-setup.md sections 3–12
#
# Prerequisites (complete manually before running):
#   - Section 1: SSH key access established, connected as root or non-root user
#   - Section 2: Non-root user created and added to sudo group
#
# Usage:
#   ./setup-hetzner-server.sh <username> [swap_size_gb]
#   ./setup-hetzner-server.sh <username> --verify              # validation only
#   ./setup-hetzner-server.sh <username> --snapshot <name>     # verify + hygiene + snapshot
#
# Examples:
#   ./setup-hetzner-server.sh finless1strepair 2
#   ./setup-hetzner-server.sh finless1strepair --verify
#   ./setup-hetzner-server.sh finless1strepair --snapshot ubuntu-24.04-baseline-20260306
#
# The script is idempotent — safe to re-run after a reboot or partial failure.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# --- Parameters --------------------------------------------------------------

USERNAME="${1:-}"
SWAP_GB="2"
VERIFY_ONLY=false
SNAPSHOT_MODE=false
SNAPSHOT_NAME=""

if [[ $# -ge 2 ]]; then
    if [[ "$2" == "--verify" ]]; then
        VERIFY_ONLY=true
    elif [[ "$2" == "--snapshot" ]]; then
        SNAPSHOT_MODE=true
        if [[ -z "${3:-}" ]]; then
            echo "Usage: $0 <username> --snapshot <snapshot-name>" >&2
            echo "Error: --snapshot requires a snapshot name" >&2
            exit 1
        fi
        SNAPSHOT_NAME="$3"
    elif [[ "$2" =~ ^[0-9]+$ ]]; then
        SWAP_GB="$2"
    else
        echo "Usage: $0 <username> [swap_size_gb|--verify|--snapshot <name>]" >&2
        exit 1
    fi
fi

# --- Colours & logging -------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

log_info()    { echo -e "${BLUE}  ·${RESET} $*"; }
log_ok()      { echo -e "${GREEN}  ✓${RESET} $*"; }
log_warn()    { echo -e "${YELLOW}  ⚠${RESET} $*"; }
log_error()   { echo -e "${RED}  ✗${RESET} $*" >&2; }
log_section() { echo -e "\n${BOLD}${BLUE}── $* ──${RESET}"; }
die()         { log_error "$*"; cleanup_change_tracking; exit 1; }

# Track warnings for summary
WARNINGS=()
warn() { log_warn "$*"; WARNINGS+=("$*"); }

# Track applied changes and file diffs for end-of-run reporting
CHANGE_LOG=()
CHANGE_SNAPSHOT_DIR=""
declare -A FILE_SNAPSHOTS=()

record_change() { CHANGE_LOG+=("$*"); }

init_change_tracking() {
    CHANGE_SNAPSHOT_DIR=$(mktemp -d /tmp/hetzner-setup-changes.XXXXXX)
    log_info "Change tracking enabled: $CHANGE_SNAPSHOT_DIR"
}

track_file_before_change() {
    local file="$1"
    local snap

    [[ -n "${FILE_SNAPSHOTS[$file]+x}" ]] && return 0

    if sudo test -e "$file"; then
        snap="$CHANGE_SNAPSHOT_DIR/$(echo "$file" | tr '/' '_').before"
        sudo cp -a "$file" "$snap" || die "Failed to snapshot $file"
        FILE_SNAPSHOTS["$file"]="$snap"
    else
        FILE_SNAPSHOTS["$file"]="__ABSENT__"
    fi
}

cleanup_change_tracking() {
    if [[ -n "$CHANGE_SNAPSHOT_DIR" && -d "$CHANGE_SNAPSHOT_DIR" ]]; then
        sudo rm -rf "$CHANGE_SNAPSHOT_DIR" || true
    fi
}

# =============================================================================
# SNAPSHOT HYGIENE — Section 14 cleanup
# =============================================================================
run_hygiene() {
    log_section "Snapshot Hygiene"

    log_info "Clearing shell history..."
    history -c || true
    sudo sh -c 'history -c' || true
    sudo rm -f /root/.bash_history
    sudo rm -f "/home/$USERNAME/.bash_history"
    log_ok "Shell history cleared"

    log_info "Clearing apt cache..."
    sudo apt clean || true
    sudo rm -rf /var/lib/apt/lists/*
    log_ok "Apt cache cleared"

    log_info "Clearing Docker build cache..."
    docker builder prune -f 2>/dev/null || sudo docker builder prune -f 2>/dev/null || true
    log_ok "Docker build cache cleared"

    log_info "Regenerating machine-id for template image..."
    sudo rm -f /etc/machine-id
    sudo systemd-machine-id-setup
    log_ok "Machine-id regenerated (will be unique on next boot)"

    log_info "Removing random seed..."
    sudo rm -f /var/lib/systemd/random-seed
    log_ok "Random seed removed"

    log_info "Checking for credential files that should not be in snapshot..."
    local issues=()
    
    if sudo test -f /etc/postfix/sasl_passwd; then
        issues+=("/etc/postfix/sasl_passwd exists — must NOT be in snapshot")
        log_warn "/etc/postfix/sasl_passwd exists — must NOT be in snapshot"
    else
        log_ok "/etc/postfix/sasl_passwd absent"
    fi
    
    if sudo test -f /etc/restic/env; then
        issues+=("/etc/restic/env exists — must NOT be in snapshot")
        log_warn "/etc/restic/env exists — must NOT be in snapshot"
    else
        log_ok "/etc/restic/env absent"
    fi
    
    local env_files
    env_files=$(sudo find /opt \( -name "*.env" -o -name "env" \) 2>/dev/null -print0 2>/dev/null | xargs -0 -r ls -la 2>/dev/null || true)
    if [[ -n "$env_files" ]]; then
        issues+=("Env files found in /opt")
        log_warn "Env files found in /opt — review:"
        echo "$env_files"
    else
        log_ok "No env files in /opt"
    fi
    
    local priv_keys
    priv_keys=$(sudo find /root /home \( -name "id_rsa*" -o -name "id_ed25519*" \) 2>/dev/null || true)
    if [[ -n "$priv_keys" ]]; then
        issues+=("Private key files found")
        log_warn "Private key files found — review:"
        echo "$priv_keys"
    else
        log_ok "No private key files in /root or /home"
    fi

    if [[ ${#issues[@]} -gt 0 ]]; then
        echo
        log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_error "SNAPSHOT BLOCKED: Found ${#issues[@]} forbidden item(s)"
        log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        for issue in "${issues[@]}"; do
            log_error "  - $issue"
        done
        log_error "Remove these items before creating a snapshot."
        log_error "See RUNBOOK section 13: What Does NOT Belong in the Snapshot"
        die "Snapshot hygiene failed — cannot proceed with forbidden files present"
    fi

    log_ok "Snapshot hygiene complete — server ready for snapshot"
}

# =============================================================================
# HETZNER SNAPSHOT — Trigger via API
# =============================================================================
trigger_snapshot() {
    log_section "Hetzner Snapshot"

    # Check for jq (needed to parse metadata)
    if ! command -v jq &>/dev/null; then
        die "jq is required for snapshot mode. Install with: sudo apt install jq"
    fi

    # Get server ID from Hetzner metadata service
    log_info "Detecting server ID from Hetzner metadata..."
    local server_id
    server_id=$(curl -fsSL --max-time 5 http://169.254.169.254/hetzner/v1/metadata 2>/dev/null | jq -r '.instance-id' 2>/dev/null) || true
    
    if [[ -z "$server_id" || "$server_id" == "null" ]]; then
        die "Could not detect server ID from Hetzner metadata.\n       Are you running on a Hetzner Cloud server?"
    fi
    
    # Validate server_id is numeric
    if [[ ! "$server_id" =~ ^[0-9]+$ ]]; then
        die "Invalid server ID detected: $server_id"
    fi
    
    log_ok "Server ID: $server_id"

    # Use provided snapshot name
    log_info "Snapshot name: $SNAPSHOT_NAME"

    # Confirm before proceeding
    echo
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${YELLOW}  SNAPSHOT: $SNAPSHOT_NAME${RESET}"
    echo -e "${YELLOW}  WARNING: Server will POWER OFF for snapshot${RESET}"
    echo -e "${YELLOW}  SSH session will disconnect${RESET}"
    echo -e "${YELLOW}  Server will restart automatically when complete${RESET}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    read -r -p "Proceed with snapshot? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        die "Snapshot cancelled by user"
    fi

    # Trigger snapshot via API first
    log_info "Initiating snapshot via Hetzner API..."
    local response http_code
    response=$(curl -sSL \
        --max-time 30 \
        --no-location \
        -w "\n%{http_code}" \
        -H "Authorization: Bearer $HCLOUD_TOKEN" \
        -H "Content-Type: application/json" \
        -X POST \
        -d "{\"description\": \"$SNAPSHOT_NAME\", \"type\": \"snapshot\", \"labels\": {\"created\": \"$(date +%Y-%m-%d)\"}}" \
        "https://api.hetzner.cloud/v1/servers/$server_id/actions/create_image" 2>&1) || true
    
    # Extract HTTP code from last line
    http_code=$(echo "$response" | tail -n1)
    response=$(echo "$response" | sed '$d')
    
    # Check response codes
    case "$http_code" in
        201)
            log_ok "Snapshot initiated successfully!"
            ;;
        401)
            die "API authentication failed. Check your API token is valid."
            ;;
        403)
            die "API permission denied. Ensure token has Read & Write permissions."
            ;;
        404)
            die "Server not found. Check server ID: $server_id"
            ;;
        429)
            die "Rate limit exceeded. Wait a moment and try again."
            ;;
        *)
            die "Failed to initiate snapshot (HTTP $http_code).\nResponse: $response"
            ;;
    esac
    
    # Only delete script after API call succeeds
    log_info "Removing setup script before server powers off..."
    rm -f "$0"
    log_ok "Script removed"
    
    log_info "Server will power off, create snapshot, then restart."
    log_info "Monitor progress in Hetzner Cloud Console."
    
    echo
    echo -e "${GREEN}══════════════════════════════════════════════${RESET}"
    echo -e "${GREEN}  Snapshot process started${RESET}"
    echo -e "${GREEN}══════════════════════════════════════════════${RESET}"
}

# --- Preflight checks --------------------------------------------------------

preflight() {
    [[ -z "$USERNAME" ]] && die "Username required. Usage: $0 <username> [swap_size_gb|--verify|--snapshot <name>]"
    [[ "$EUID" -eq 0 ]] && die "Run as the non-root sudo user, not root directly."
    [[ "$(whoami)" == "$USERNAME" ]] \
        || die "Run this script as '$USERNAME', not as '$(whoami)'. Switch users first."
    id "$USERNAME" &>/dev/null || die "User '$USERNAME' does not exist — complete section 2 first."
    groups "$USERNAME" | grep -q sudo || die "User '$USERNAME' is not in the sudo group — complete section 2 first."

    # Confirm sudo access without prompting mid-script
    if ! sudo -n true 2>/dev/null; then
        log_info "Sudo password required:"
        sudo true || die "Could not obtain sudo access."
    fi

    log_ok "Preflight passed — user: $USERNAME, swap: ${SWAP_GB}G"
}

# --- Helpers -----------------------------------------------------------------

pkg_installed() { dpkg -l "$1" 2>/dev/null | grep -q "^ii"; }

apt_install() {
    local missing=()
    for pkg in "$@"; do
        pkg_installed "$pkg" || missing+=("$pkg")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        log_ok "Already installed: $(IFS=" "; echo "$*")"
        return
    fi
    log_info "Installing: ${missing[*]}"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" \
        || die "apt install failed for: ${missing[*]}"
    log_ok "Installed: ${missing[*]}"
    record_change "Installed packages: ${missing[*]}"
}

# Set a directive in sshd_config.
# Handles: already-correct, active with wrong value, commented-out, absent.
set_sshd_directive() {
    local key="$1" value="$2"
    local file="/etc/ssh/sshd_config"
    local full="${key} ${value}"

    if grep -qE "^${key} ${value}$" "$file"; then
        log_ok "sshd: $full (already set)"
        return
    fi

    track_file_before_change "$file"
    if grep -qE "^[#[:space:]]*${key}[[:space:]]" "$file"; then
        sudo sed -i -E "s|^[#[:space:]]*${key}[[:space:]].*|${full}|" "$file" \
            || die "Failed to set sshd directive: $key"
        log_ok "sshd: $full (updated)"
        record_change "Updated sshd directive: $full"
    else
        echo "$full" | sudo tee -a "$file" > /dev/null \
            || die "Failed to append sshd directive: $key"
        log_ok "sshd: $full (added)"
        record_change "Added sshd directive: $full"
    fi
}

# Append a line to a file only if not already present (exact string match)
append_if_absent() {
    local line="$1" file="$2"
    if grep -qF "$line" "$file"; then
        log_ok "Already in $file: $line"
    else
        echo "$line" | sudo tee -a "$file" > /dev/null \
            || die "Failed to append to $file"
        log_ok "Added to $file: $line"
    fi
}

# Ensure a root-owned file exactly matches expected content from stdin.
# This makes reruns convergent, not just "create if missing".
ensure_root_file_content() {
    local file="$1"
    local mode="${2:-644}"
    local label="${3:-$file}"
    local tmp
    tmp=$(mktemp)

    cat > "$tmp"

    track_file_before_change "$file"
    if sudo test -f "$file" && sudo cmp -s "$tmp" "$file"; then
        rm -f "$tmp"
        log_ok "$label already up to date"
        return
    fi

    sudo install -o root -g root -m "$mode" "$tmp" "$file" \
        || die "Failed to write $file"
    rm -f "$tmp"
    log_ok "$label written"
    record_change "Updated file content: $file"
}

# =============================================================================
# SECTION 3: SSH Hardening
# =============================================================================
s3_ssh_hardening() {
    log_section "3 · SSH Hardening"

    local cfg="/etc/ssh/sshd_config"

    set_sshd_directive "PermitRootLogin"               "no"
    set_sshd_directive "PasswordAuthentication"        "no"
    set_sshd_directive "PermitEmptyPasswords"          "no"
    set_sshd_directive "PubkeyAuthentication"          "yes"
    set_sshd_directive "ChallengeResponseAuthentication" "no"
    set_sshd_directive "X11Forwarding"                 "no"
    set_sshd_directive "AllowAgentForwarding"          "no"
    set_sshd_directive "AllowTcpForwarding"            "yes"
    set_sshd_directive "AllowStreamLocalForwarding"    "yes"
    set_sshd_directive "PermitOpen"                    "any"
    set_sshd_directive "MaxAuthTries"                  "3"
    set_sshd_directive "LoginGraceTime"                "30"

    # AllowUsers: ensure USERNAME is present.
    # Three cases:
    #   a) Username already in an active AllowUsers line → nothing to do
    #   b) An active AllowUsers line exists but doesn't include username → append username to that line
    #   c) No active AllowUsers line → insert one before the first Match block (or at end if none)
    # If multiple AllowUsers lines exist, warn and do not modify — requires manual review.
    #
    # Use awk token check: splits on whitespace and compares fields by == (exact match),
    # eliminating all regex boundary/anchoring edge cases (prefix, suffix, greedy .* matches).
    local allow_lines
    allow_lines=$(grep -cE '^[[:space:]]*AllowUsers[[:space:]]+' "$cfg" 2>/dev/null || true)
    allow_lines=${allow_lines:-0}

    if [[ "$allow_lines" -gt 1 ]]; then
        warn "sshd: multiple AllowUsers lines found in $cfg — not modifying. Ensure $USERNAME is listed."
    elif [[ "$allow_lines" -eq 1 ]]; then
        if awk -v u="$USERNAME" '
              $1 == "AllowUsers" { for (i=2; i<=NF; i++) if ($i == u) found=1 }
              END { exit(found ? 0 : 1) }
            ' "$cfg"; then
            log_ok "sshd: AllowUsers already includes $USERNAME"
        else
            track_file_before_change "$cfg"
            sudo sed -i -E "s|^([[:space:]]*AllowUsers[[:space:]].*)|\1 ${USERNAME}|" "$cfg" \
                || die "Failed to add $USERNAME to existing AllowUsers line"
            log_ok "sshd: $USERNAME appended to existing AllowUsers line"
            record_change "Updated AllowUsers to include: $USERNAME"
        fi
    else
        # Insert before the first Match block to avoid conditional scope ambiguity.
        # If no Match block exists, append at end of file.
        if grep -qE "^Match " "$cfg"; then
            track_file_before_change "$cfg"
            sudo sed -i "/^Match /i AllowUsers ${USERNAME}" "$cfg" \
                || die "Failed to insert AllowUsers before Match block"
            log_ok "sshd: AllowUsers ${USERNAME} inserted before first Match block"
            record_change "Inserted AllowUsers ${USERNAME} before Match block"
        else
            track_file_before_change "$cfg"
            echo "AllowUsers ${USERNAME}" | sudo tee -a "$cfg" > /dev/null \
                || die "Failed to append AllowUsers to $cfg"
            log_ok "sshd: AllowUsers ${USERNAME} (added)"
            record_change "Added AllowUsers ${USERNAME}"
        fi
    fi

    # Validate config before restart — if this fails, the current SSH session stays up
    sudo sshd -t || die "sshd_config validation failed — check $cfg. SSH was NOT restarted."

    sudo systemctl restart ssh || die "Failed to restart SSH"
    log_ok "SSH service restarted"
    record_change "Restarted service: ssh"

    # Lock root password — defence-in-depth against local escalation
    if sudo passwd -S root | grep -q " L "; then
        log_ok "Root password already locked"
    else
        sudo passwd -l root || die "Failed to lock root password"
        log_ok "Root password locked"
        record_change "Locked root password"
    fi

    log_info "SSH host key fingerprint (record in LOGBOOK):"
    ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
}

# =============================================================================
# SECTION 4: Package Updates & Unattended Upgrades
# =============================================================================
s4_package_updates() {
    log_section "4 · Package Updates & Unattended Upgrades"

    sudo apt-get update -qq || die "apt update failed"
    sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y || die "apt upgrade failed"
    log_ok "System packages up to date"

    apt_install ca-certificates

    # Enable unattended-upgrades non-interactively
    apt_install unattended-upgrades
    sudo DEBIAN_FRONTEND=noninteractive \
        dpkg-reconfigure --priority=low unattended-upgrades \
        || die "dpkg-reconfigure unattended-upgrades failed"
    log_ok "unattended-upgrades enabled"

    # --- Allowed-Origins: edit 50unattended-upgrades directly ---
    # Allowed-Origins is a list type. Override files do not extend it — they
    # replace the entire block. Modify the shipped file directly.
    local uu50="/etc/apt/apt.conf.d/50unattended-upgrades"

    # Uncomment the -updates origin if it's commented out.
    # Match any line containing ${distro_codename}-updates that starts with //,
    # regardless of quoting style or whitespace variation.
    if grep -qE '^[[:space:]]*"[^"]*\$\{distro_codename\}-updates"' "$uu50"; then
        log_ok "unattended-upgrades: -updates origin already active"
    elif grep -qE '^[[:space:]]*//.*\$\{distro_codename\}-updates' "$uu50"; then
        track_file_before_change "$uu50"
        sudo sed -i -E 's|^([[:space:]]*)//([[:space:]]*".*\$\{distro_codename\}-updates";)|\1\2|' "$uu50" \
            || die "Failed to uncomment -updates in $uu50"
        # Verify it took
        if grep -qE '^[[:space:]]*"[^"]*\$\{distro_codename\}-updates"' "$uu50"; then
            log_ok "unattended-upgrades: -updates origin uncommented"
            record_change "Enabled unattended-upgrades -updates origin"
        else
            warn "unattended-upgrades: attempted to uncomment -updates but result not confirmed — check $uu50"
        fi
    else
        warn "Could not find -updates line in $uu50 — may need manual addition"
    fi

    # Add Docker origin inside the Allowed-Origins block if not present
    local docker_origin='"origin=Docker,codename=${distro_codename},label=Docker CE";'
    if grep -qF 'Docker CE' "$uu50"; then
        log_ok "unattended-upgrades: Docker origin already present"
    else
        track_file_before_change "$uu50"
        # Insert before the closing }; of the Allowed-Origins block
        sudo sed -i "/^Unattended-Upgrade::Allowed-Origins {/,/^};/{
            s|^};|        ${docker_origin}\n};|
        }" "$uu50" || die "Failed to add Docker origin to $uu50"
        # Verify insertion landed
        if grep -qF 'Docker CE' "$uu50"; then
            log_ok "unattended-upgrades: Docker origin added"
            record_change "Added Docker origin to unattended-upgrades"
        else
            warn "unattended-upgrades: Docker origin insertion did not land — check $uu50 formatting"
        fi
    fi

    # --- Scalar settings: safe to write to override file ---
    # Scalar assignments in higher-numbered files override lower-numbered ones.
    local override="/etc/apt/apt.conf.d/51unattended-upgrades-local"
    ensure_root_file_content "$override" "644" "unattended-upgrades scalar override ($override)" << 'EOF'
// Cleanup
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Automatic reboot after kernel updates at 03:00 UTC
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";

// Mail root on error (relayed externally once postfix relay is configured)
Unattended-Upgrade::Mail "root";
Unattended-Upgrade::MailOnlyOnError "true";
EOF

    # --- needrestart ---
    local nr_conf="/etc/needrestart/needrestart.conf"
    # Target line — $'...' quoting lets us embed single-quotes without escaping gymnastics
    local nr_target=$'$nrconf{restart} = \'a\';'
    if [[ -f "$nr_conf" ]]; then
        if grep -qF "$nr_target" "$nr_conf"; then
            log_ok "needrestart already set to automatic"
        else
            track_file_before_change "$nr_conf"
            # Single-quoted sed pattern — no shell expansion of $ or { in program text
            sudo sed -i -E 's|^[[:space:]]*#?[[:space:]]*\$nrconf\{restart\}[[:space:]]*=.*|'"${nr_target}"'|' "$nr_conf"
            if grep -qF "$nr_target" "$nr_conf"; then
                log_ok "needrestart set to automatic (replaced)"
                record_change "Set needrestart restart mode to automatic"
            else
                # sed matched nothing (format differs) — append
                printf '%s\n' "$nr_target" | sudo tee -a "$nr_conf" > /dev/null
                log_ok "needrestart set to automatic (appended)"
                record_change "Appended needrestart restart mode to automatic"
            fi
        fi
    else
        warn "needrestart config not found at $nr_conf — skipping"
    fi

    # Reboot gate: if a kernel was upgraded, we must reboot before continuing
    if [[ -f /var/run/reboot-required ]]; then
        echo
        log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_warn "Kernel update installed — reboot required."
        log_warn "Reboot now, then re-run this script to continue."
        log_warn "All completed steps will be skipped (idempotent)."
        log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        print_change_report
        cleanup_change_tracking
        exit 0
    fi
}

# =============================================================================
# SECTION 5: Firewall — UFW
# =============================================================================
s5_firewall() {
    log_section "5 · Firewall — UFW"

    apt_install ufw

    sudo ufw --force default deny incoming  &>/dev/null || die "UFW: failed to set default deny incoming"
    sudo ufw --force default allow outgoing &>/dev/null || die "UFW: failed to set default allow outgoing"
    log_ok "UFW defaults: deny incoming, allow outgoing"
    record_change "Set UFW default policies: deny incoming, allow outgoing"

    if sudo ufw status verbose | grep -qE "^22/tcp.*LIMIT"; then
        log_ok "UFW: OpenSSH rate-limit rule already present"
    else
        sudo ufw limit OpenSSH || die "UFW: failed to add OpenSSH limit rule"
        log_ok "UFW: OpenSSH rate-limit rule added"
        record_change "Added UFW rule: limit OpenSSH"
    fi

    if sudo ufw status | grep -q "Status: active"; then
        log_ok "UFW already active"
    else
        sudo ufw --force enable || die "UFW: failed to enable"
        log_ok "UFW enabled"
        record_change "Enabled UFW"
    fi

    sudo ufw status verbose
}

# =============================================================================
# SECTION 6: Fail2ban
# =============================================================================
s6_fail2ban() {
    log_section "6 · Fail2ban"

    apt_install fail2ban

    if ! sudo systemctl is-enabled --quiet fail2ban 2>/dev/null; then
        sudo systemctl enable fail2ban &>/dev/null || die "Failed to enable fail2ban"
        record_change "Enabled service: fail2ban"
    else
        sudo systemctl enable fail2ban &>/dev/null || die "Failed to enable fail2ban"
    fi

    if sudo systemctl is-active --quiet fail2ban; then
        log_ok "fail2ban already running"
    else
        sudo systemctl start fail2ban || die "Failed to start fail2ban"
        log_ok "fail2ban started"
        record_change "Started service: fail2ban"
    fi

    # Give fail2ban a moment to initialise jails
    sleep 2

    if sudo fail2ban-client status sshd &>/dev/null; then
        log_ok "fail2ban sshd jail is active"
    else
        warn "fail2ban sshd jail not listed — check /etc/fail2ban/jail.conf"
    fi
}

# =============================================================================
# SECTION 7: Monitoring & Auditing
# =============================================================================
s7_monitoring() {
    log_section "7 · Monitoring & Auditing"

    # logwatch
    apt_install logwatch

    if [[ -f /etc/cron.daily/00logwatch ]]; then
        log_ok "logwatch cron present"
    else
        warn "logwatch cron not found at /etc/cron.daily/00logwatch"
    fi

    sudo mkdir -p /etc/logwatch/conf
    local lw_conf="/etc/logwatch/conf/logwatch.conf"
    if grep -q "^Detail = Med" "$lw_conf" 2>/dev/null; then
        log_ok "logwatch detail level already set to Med"
    else
        track_file_before_change "$lw_conf"
        echo "Detail = Med" | sudo tee "$lw_conf" > /dev/null \
            || die "Failed to write logwatch config"
        log_ok "logwatch detail level set to Med"
        record_change "Set logwatch detail level to Med"
    fi

    # auditd
    apt_install auditd

    local rules_file="/etc/audit/rules.d/10-ubuntu-base.rules"
    ensure_root_file_content "$rules_file" "640" "auditd rules file ($rules_file)" << 'AUDIT_RULES'
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
AUDIT_RULES

    if ! sudo systemctl is-enabled --quiet auditd 2>/dev/null; then
        sudo systemctl enable auditd &>/dev/null || die "Failed to enable auditd"
        record_change "Enabled service: auditd"
    else
        sudo systemctl enable auditd &>/dev/null || die "Failed to enable auditd"
    fi

    # Correct order: load rules first, then restart so auditd reads them cleanly
    sudo augenrules --load > /dev/null || die "augenrules --load failed"

    if sudo systemctl is-active --quiet auditd; then
        sudo systemctl restart auditd || die "Failed to restart auditd"
        log_ok "auditd restarted with updated rules"
        record_change "Restarted service: auditd"
    else
        sudo systemctl start auditd || die "Failed to start auditd"
        log_ok "auditd started"
        record_change "Started service: auditd"
    fi

    local rule_count
    rule_count=$(sudo auditctl -l 2>/dev/null | wc -l || echo "0")
    log_ok "auditd active (${rule_count} rule lines)"

    # Warn if kernel audit was disabled at boot — rare on cloud images but fatal to auditing
    if grep -q 'audit=0' /proc/cmdline 2>/dev/null; then
        warn "Kernel audit disabled (audit=0 in /proc/cmdline) — auditd is running but will not log events"
    fi

    # Diagnostics & operator toolkit
    apt_install htop curl jq lsof ncdu rsync bash-completion git netcat-openbsd
}

# =============================================================================
# SECTION 8: Swap
# =============================================================================
s8_swap() {
    log_section "8 · Swap (${SWAP_GB}G)"

    if swapon --show | grep -q "/swapfile"; then
        log_ok "Swapfile already active"
    elif [[ -f /swapfile ]]; then
        log_warn "Swapfile exists but not active — activating"
        sudo swapon /swapfile || die "swapon failed"
        log_ok "Swapfile activated"
        record_change "Activated existing swapfile"
    else
        # Check available disk space before allocating
        local avail_gb needed
        avail_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
        needed=$(( SWAP_GB + 2 ))
        if [[ -z "$avail_gb" ]]; then
            warn "Could not determine available disk space — proceeding without space check"
        elif (( avail_gb < needed )); then
            die "Insufficient disk space for swap: ${avail_gb}G available, need ${needed}G (swap + 2G buffer)"
        fi
        log_info "Disk space: ${avail_gb}G available — proceeding with ${SWAP_GB}G swap"

        sudo fallocate -l "${SWAP_GB}G" /swapfile || die "fallocate failed"
        sudo chmod 600 /swapfile
        sudo mkswap /swapfile  || die "mkswap failed"
        sudo swapon /swapfile  || die "swapon failed"
        log_ok "Swapfile created and activated (${SWAP_GB}G)"
        record_change "Created and activated swapfile (${SWAP_GB}G)"
    fi

    if grep -q "^/swapfile " /etc/fstab; then
        log_ok "Swapfile already in /etc/fstab"
    else
        track_file_before_change "/etc/fstab"
        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab > /dev/null \
            || die "Failed to add swapfile to /etc/fstab"
        log_ok "Swapfile entry added to /etc/fstab"
        record_change "Added /swapfile entry to /etc/fstab"
    fi

    log_info "Memory after swap:"
    free -h
}

# =============================================================================
# SECTION 9: Docker
# =============================================================================
s9_docker() {
    log_section "9 · Docker"

    if command -v docker &>/dev/null; then
        log_ok "Docker already installed: $(docker --version)"
    else
        log_info "Installing Docker via get.docker.com"
        curl -fsSL https://get.docker.com | sudo sh || die "Docker install script failed"
        log_ok "Docker installed"
        record_change "Installed Docker via get.docker.com"
    fi

    if id -nG "$USERNAME" | grep -qw docker; then
        log_ok "User $USERNAME already in docker group"
    else
        sudo usermod -aG docker "$USERNAME" || die "Failed to add $USERNAME to docker group"
        log_ok "User $USERNAME added to docker group (log out/in required for effect)"
        record_change "Added user to docker group: $USERNAME"
    fi

    if ! sudo systemctl is-enabled --quiet docker 2>/dev/null; then
        record_change "Enabled service: docker"
    fi
    if ! sudo systemctl is-active --quiet docker; then
        record_change "Started service: docker"
    fi
    sudo systemctl enable --now docker &>/dev/null || die "Failed to enable Docker"
    log_ok "Docker enabled and started"

    # Log rotation — merge log-driver into daemon.json rather than overwriting,
    # so any other settings already present are preserved.
    # jq is available: installed in s7 (diagnostics toolkit) which runs before this.
    local daemon_json="/etc/docker/daemon.json"
    if [[ -f "$daemon_json" ]] && jq -e '."log-driver" == "local"' "$daemon_json" &>/dev/null; then
        log_ok "Docker log driver already set to local"
    else
        track_file_before_change "$daemon_json"
        local tmp
        tmp=$(mktemp)
        # Temporary EXIT cleanup trap — ensures tmp is removed if die() calls exit 1.
        # (RETURN traps don't fire on exit; EXIT traps do.)
        # This script sets no other EXIT trap, so set + clear is safe.
        # If any other EXIT trap is added elsewhere, this trap - EXIT will clear it;
        # switch to a chained/preserved handler at that point.
        trap 'rm -f "$tmp"' EXIT
        if [[ -f "$daemon_json" ]]; then
            # Fail fast if existing file is not valid JSON — do not silently clobber.
            jq empty "$daemon_json" 2>/dev/null \
                || die "$daemon_json exists but is not valid JSON — inspect before proceeding"
            # Merge: preserve existing settings, add/overwrite log-driver only.
            # daemon.json is 644 — no sudo needed for read; sudo only for the final move.
            jq '. + {"log-driver": "local"}' "$daemon_json" > "$tmp" \
                || die "jq merge of $daemon_json failed"
        else
            echo '{"log-driver": "local"}' > "$tmp"
        fi
        sudo mv "$tmp" "$daemon_json" \
            || die "Failed to write $daemon_json"
        trap - EXIT  # tmp consumed; clear the cleanup trap
        sudo chmod 644 "$daemon_json"
        sudo systemctl restart docker || die "Docker restart failed after log driver change"
        log_ok "Docker log driver set to local"
        record_change "Set Docker logging driver to local"
        record_change "Restarted service: docker"
    fi

    local actual_driver
    actual_driver=$(sudo docker info --format '{{.LoggingDriver}}' 2>/dev/null || echo "unknown")
    [[ "$actual_driver" == "local" ]] \
        && log_ok "Verified: Docker logging driver = local" \
        || warn "Docker logging driver = $actual_driver (expected local)"

    # Prune systemd units
    local prune_svc="/etc/systemd/system/docker-prune.service"
    local prune_tmr="/etc/systemd/system/docker-prune.timer"

    ensure_root_file_content "$prune_svc" "644" "docker-prune.service" << 'EOF'
[Unit]
Description=Docker system prune
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/docker system prune -f --filter "until=168h"
EOF

    ensure_root_file_content "$prune_tmr" "644" "docker-prune.timer" << 'EOF'
[Unit]
Description=Weekly Docker system prune

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable docker-prune.timer &>/dev/null || die "Failed to enable docker-prune.timer"
    sudo systemctl start  docker-prune.timer || die "Failed to start docker-prune.timer"
    log_ok "docker-prune.timer enabled and started"
    record_change "Enabled and started timer: docker-prune.timer"
}

# =============================================================================
# SECTION 10: Kernel Hardening — sysctl
# =============================================================================
s10_kernel_hardening() {
    log_section "10 · Kernel Hardening — sysctl"

    local sysctl_file="/etc/sysctl.d/99-hardening.conf"

    ensure_root_file_content "$sysctl_file" "644" "sysctl hardening file ($sysctl_file)" << 'EOF'
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

    sudo sysctl --system > /dev/null || die "sysctl --system failed"
    log_ok "sysctl rules applied"
    record_change "Applied sysctl settings"

    # Verify individual values
    local syncookies suid_dumpable
    syncookies=$(sysctl -n net.ipv4.tcp_syncookies)
    suid_dumpable=$(sysctl -n fs.suid_dumpable)

    [[ "$syncookies"    -eq 1 ]] && log_ok "net.ipv4.tcp_syncookies = 1"   || log_error "net.ipv4.tcp_syncookies = $syncookies (expected 1)"
    [[ "$suid_dumpable" -eq 0 ]] && log_ok "fs.suid_dumpable = 0"           || log_error "fs.suid_dumpable = $suid_dumpable (expected 0)"

    # Per-interface rp_filter
    local iface
    iface=$(ip route 2>/dev/null | awk '/default/{print $5; exit}')
    if [[ -n "$iface" ]]; then
        local rp
        rp=$(sysctl -n "net.ipv4.conf.${iface}.rp_filter" 2>/dev/null || echo "error")
        if [[ "$rp" -eq 0 ]]; then
            warn "net.ipv4.conf.${iface}.rp_filter = 0 — reverse path filtering disabled, spoofing protection off"
        else
            log_ok "net.ipv4.conf.${iface}.rp_filter = $rp (1=strict, 2=loose/cloud — both acceptable)"
        fi
    else
        warn "Could not detect primary interface for rp_filter verification"
    fi
}

# =============================================================================
# SECTION 11: Outbound Email — postfix relay
# =============================================================================
s11_postfix() {
    log_section "11 · Outbound Email — postfix relay"

    # postfix is installed by default on Hetzner Ubuntu 24.04.
    # Ensure it is present, enabled, and running. SASL relay credentials
    # are configured post-deployment — do not snapshot with credentials in place.
    apt_install postfix

    if ! sudo systemctl is-enabled --quiet postfix 2>/dev/null; then
        sudo systemctl enable postfix &>/dev/null || die "Failed to enable postfix"
        record_change "Enabled service: postfix"
    else
        sudo systemctl enable postfix &>/dev/null || die "Failed to enable postfix"
    fi

    if sudo systemctl is-active --quiet postfix; then
        log_ok "postfix already running"
    else
        sudo systemctl start postfix || die "Failed to start postfix"
        log_ok "postfix started"
        record_change "Started service: postfix"
    fi

    local version
    version=$(postconf -d mail_version 2>/dev/null || echo "unknown")
    log_ok "postfix ready (${version})"
    log_info "Relay credentials (relayhost, sasl_passwd) configured post-deployment."
}

# =============================================================================
# SECTION 12: Backups — restic
# =============================================================================
s12_backups() {
    log_section "12 · Backups — restic"

    apt_install restic

    local version
    version=$(restic version 2>/dev/null | head -1 || echo "unknown")
    log_ok "restic installed: $version"
    log_info "Object Storage credentials and repository init are post-deployment."
}

# =============================================================================
# HOSTNAME PROMPT
# =============================================================================
prompt_hostname() {
    log_section "Hostname"

    local current_hostname new_hostname
    current_hostname=$(hostnamectl --static 2>/dev/null || hostname 2>/dev/null || echo "unknown")

    echo "  Current hostname: ${BOLD}${current_hostname}${RESET}"
    read -r -p "  Change hostname now? [y/N] " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Hostname unchanged"
        return
    fi

    read -r -p "  New hostname: " new_hostname
    [[ -n "$new_hostname" ]] || die "Hostname cannot be empty"
    [[ "$new_hostname" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$|^[a-zA-Z0-9]$ ]] \
        || die "Invalid hostname. Use letters, numbers, dots, and hyphens only."

    if [[ "$new_hostname" == "$current_hostname" ]]; then
        log_ok "Hostname already set to $new_hostname"
        return
    fi

    sudo hostnamectl set-hostname "$new_hostname" || die "Failed to set hostname"
    log_ok "Hostname set to $new_hostname"
    record_change "Set hostname: $new_hostname"
}

# =============================================================================
# CHANGE REPORT
# =============================================================================
print_change_report() {
    local file
    local -a changed_files=()

    echo
    echo -e "${BOLD}${BLUE}── Change Report ──${RESET}"

    if [[ ${#CHANGE_LOG[@]} -eq 0 ]]; then
        echo "  No state changes recorded."
    else
        echo "  State changes applied:"
        for entry in "${CHANGE_LOG[@]}"; do
            echo "    - $entry"
        done
    fi

    for file in "${!FILE_SNAPSHOTS[@]}"; do
        local before
        before="${FILE_SNAPSHOTS[$file]}"
        if [[ "$before" == "__ABSENT__" ]]; then
            if sudo test -e "$file"; then
                changed_files+=("$file")
            fi
        else
            if ! sudo cmp -s "$before" "$file"; then
                changed_files+=("$file")
            fi
        fi
    done

    if [[ ${#changed_files[@]} -eq 0 ]]; then
        echo "  File diffs: none"
        return
    fi

    echo
    echo "  File diffs:"
    while IFS= read -r file; do
        local before
        before="${FILE_SNAPSHOTS[$file]}"
        echo
        echo "  >>> $file"
        if [[ "$before" == "__ABSENT__" ]]; then
            sudo diff -u /dev/null "$file" || true
        else
            sudo diff -u "$before" "$file" || true
        fi
    done < <(printf '%s\n' "${changed_files[@]}" | sort -u)
}

# =============================================================================
# VERIFY — Run validation checks from section 14 and print results
# =============================================================================
run_verify() {
    log_section "Verification (section 14)"

    echo
    log_info "── Timezone & Hostname ──"
    local timezone hostname
    timezone=$(timedatectl show --property=Timezone --value 2>/dev/null || timedatectl | grep "Time zone" | awk '{print $3}')
    hostname=$(hostnamectl --static 2>/dev/null || hostname)
    echo "  Timezone: ${timezone:-unknown}"
    echo "  Hostname: ${hostname:-unknown}"
    [[ "$timezone" == "UTC" ]] || warn "Timezone is $timezone, expected UTC"
    [[ -n "$hostname" && "$hostname" != "localhost" ]] || warn "Hostname not set or is localhost"

    echo
    log_info "── Time sync status ──"
    timedatectl status || true

    echo
    log_info "── SSH Hardening Checks ──"
    local sshd_cfg="/etc/ssh/sshd_config"
    grep -qE "^PermitRootLogin no" "$sshd_cfg" && log_ok "PermitRootLogin no" || warn "PermitRootLogin not set to no"
    grep -qE "^PasswordAuthentication no" "$sshd_cfg" && log_ok "PasswordAuthentication no" || warn "PasswordAuthentication not set to no"
    grep -qE "^AllowTcpForwarding yes" "$sshd_cfg" && log_ok "AllowTcpForwarding yes" || warn "AllowTcpForwarding not set to yes"
    grep -qE "^MaxAuthTries 3" "$sshd_cfg" && log_ok "MaxAuthTries 3" || warn "MaxAuthTries not set to 3"
    if awk -v u="$USERNAME" '
          $1 == "AllowUsers" { for (i=2; i<=NF; i++) if ($i == u) found=1 }
          END { exit(found ? 0 : 1) }
        ' "$sshd_cfg"; then
        log_ok "AllowUsers includes $USERNAME"
    else
        warn "AllowUsers does not include $USERNAME"
    fi

    echo
    log_info "── AppArmor status ──"
    if sudo systemctl is-active --quiet apparmor; then
        log_ok "AppArmor is active"
    else
        warn "AppArmor is not active"
    fi
    sudo systemctl --no-pager status apparmor || true

    echo
    log_info "── apt timers ──"
    if systemctl list-timers --all 2>/dev/null | grep -q 'apt-daily'; then
        log_ok "apt timers present"
    else
        warn "apt timers not found"
    fi
    systemctl list-timers | grep apt || true

    echo
    log_info "── Failed systemd units ──"
    sudo systemctl --no-pager --failed || true

    echo
    log_info "── UFW status ──"
    sudo ufw status verbose || true

    echo
    log_info "── Listening ports ──"
    sudo ss -tulpn || true

    echo
    log_info "── Fail2ban sshd jail ──"
    if sudo fail2ban-client status sshd >/dev/null 2>&1; then
        log_ok "fail2ban sshd jail is active"
    else
        warn "fail2ban sshd jail is not active"
    fi
    sudo fail2ban-client status sshd || true

    echo
    log_info "── logwatch cron ──"
    [[ -f /etc/cron.daily/00logwatch ]] && log_ok "logwatch cron present" || warn "logwatch cron not found"

    echo
    log_info "── Unattended-upgrades config ──"
    local uu50="/etc/apt/apt.conf.d/50unattended-upgrades"
    local uu51="/etc/apt/apt.conf.d/51unattended-upgrades-local"
    
    # Check -updates origin is uncommented (active)
    if grep -qE '^[[:space:]]*"[^"#/]*\$\{distro_codename\}-updates"' "$uu50" 2>/dev/null; then
        log_ok "-updates origin enabled"
    else
        warn "-updates origin not enabled (check for commented line)"
    fi
    
    # Check Docker origin
    grep -qF 'Docker CE' "$uu50" && log_ok "Docker origin enabled" || warn "Docker origin not enabled"
    
    # Check cleanup settings (in 51unattended-upgrades-local)
    log_info "  Cleanup & reboot settings:"
    grep -qF 'Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";' "$uu51" \
        && log_ok "  Remove-Unused-Kernel-Packages enabled" \
        || warn "  Remove-Unused-Kernel-Packages not enabled"
    grep -qF 'Unattended-Upgrade::Remove-New-Unused-Dependencies "true";' "$uu51" \
        && log_ok "  Remove-New-Unused-Dependencies enabled" \
        || warn "  Remove-New-Unused-Dependencies not enabled"
    grep -qF 'Unattended-Upgrade::Remove-Unused-Dependencies "true";' "$uu51" \
        && log_ok "  Remove-Unused-Dependencies enabled" \
        || warn "  Remove-Unused-Dependencies not enabled"
    grep -qF 'Unattended-Upgrade::Automatic-Reboot "true";' "$uu51" \
        && log_ok "  Automatic-Reboot enabled" \
        || warn "  Automatic-Reboot not enabled"
    grep -qF 'Unattended-Upgrade::Automatic-Reboot-Time "03:00";' "$uu51" \
        && log_ok "  Automatic-Reboot-Time set to 03:00" \
        || warn "  Automatic-Reboot-Time not set to 03:00"
    grep -qF 'Unattended-Upgrade::Mail "root";' "$uu51" \
        && log_ok '  Mail set to "root"' \
        || warn '  Mail not set to "root"'
    grep -qF 'Unattended-Upgrade::MailOnlyOnError "true";' "$uu51" \
        && log_ok "  MailOnlyOnError enabled" \
        || warn "  MailOnlyOnError not enabled"

    echo
    log_info "── needrestart mode ──"
    local nr_conf="/etc/needrestart/needrestart.conf"
    if [[ -f "$nr_conf" ]]; then
        grep -qF "\$nrconf{restart} = 'a'" "$nr_conf" && log_ok "needrestart set to automatic" || warn "needrestart not set to automatic"
    else
        warn "needrestart config not found"
    fi

    echo
    log_info "── auditd status ──"
    if sudo systemctl is-active --quiet auditd; then
        log_ok "auditd is active"
    else
        warn "auditd is not active"
    fi
    local audit_rule_count
    audit_rule_count=$(sudo auditctl -l 2>/dev/null | wc -l || echo "0")
    echo "  audit rule count: $audit_rule_count"
    if [[ "$audit_rule_count" =~ ^[0-9]+$ ]] && (( audit_rule_count > 0 )); then
        log_ok "auditd rules loaded"
    else
        warn "auditd rules not loaded or unreadable"
    fi

    echo
    log_info "── Docker configuration ──"
    # docker group membership may not apply in current session — fall back to sudo
    local drv
    drv=$(docker info --format '{{.LoggingDriver}}' 2>/dev/null \
        || sudo docker info --format '{{.LoggingDriver}}' 2>/dev/null \
        || echo "unavailable")
    echo "  logging driver: $drv"
    [[ "$drv" == "local" ]] || warn "Docker log driver is '$drv', expected 'local'"
    
    log_info "  docker-prune timer:"
    systemctl list-timers docker-prune.timer 2>/dev/null | grep -v "NEXT\|timer" || warn "docker-prune.timer not active"

    echo
    log_info "── Postfix status ──"
    sudo systemctl is-active postfix &>/dev/null && log_ok "postfix is active" || warn "postfix is not active"

    echo
    log_info "── Restic installation ──"
    command -v restic &>/dev/null && log_ok "restic installed: $(restic version 2>/dev/null | head -1)" || warn "restic not installed"

    echo
    log_info "── Memory & disk ──"
    free -h
    df -h

    echo
    log_info "── sysctl hardening values ──"
    local syncookies suid_dumpable
    syncookies=$(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null || echo "error")
    suid_dumpable=$(sysctl -n fs.suid_dumpable 2>/dev/null || echo "error")
    echo "  net.ipv4.tcp_syncookies = $syncookies"
    echo "  fs.suid_dumpable = $suid_dumpable"
    [[ "$syncookies" == "1" ]] || warn "net.ipv4.tcp_syncookies = $syncookies, expected 1"
    [[ "$suid_dumpable" == "0" ]] || warn "fs.suid_dumpable = $suid_dumpable, expected 0"

    echo
    log_info "── Per-interface rp_filter ──"
    local iface
    iface=$(ip route 2>/dev/null | awk '/default/{print $5; exit}')
    if [[ -n "$iface" ]]; then
        local rp_filter
        rp_filter=$(sysctl -n "net.ipv4.conf.${iface}.rp_filter" 2>/dev/null || echo "error")
        echo "  net.ipv4.conf.${iface}.rp_filter = $rp_filter"
        case "$rp_filter" in
            1)
                log_ok "Primary interface rp_filter is strict (1)"
                ;;
            2)
                warn "net.ipv4.conf.${iface}.rp_filter = 2 (loose mode). Acceptable only when intentional multi-path routing is configured, such as Tailscale."
                ;;
            0)
                warn "net.ipv4.conf.${iface}.rp_filter = 0, expected 1 for the base image and never 0"
                ;;
            *)
                warn "net.ipv4.conf.${iface}.rp_filter = $rp_filter, expected 1 for the base image or 2 only for intentional multi-path routing"
                ;;
        esac
    else
        warn "Could not detect primary interface for rp_filter check"
    fi

    echo
    log_info "── World-writable files (review any results) ──"
    sudo find / -xdev -type f -perm -0002 2>/dev/null || true

    echo
    log_info "── Enabled systemd units (review for unexpected entries) ──"
    sudo systemctl --no-pager list-unit-files --state=enabled || true

    echo
    log_info "── SSH host fingerprint ──"
    ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub || true

    echo
    log_info "── Credential file checks ──"
    if sudo test -f /etc/postfix/sasl_passwd; then
        warn "/etc/postfix/sasl_passwd exists — must not be present in snapshot"
    else
        log_ok "/etc/postfix/sasl_passwd absent"
    fi
    if sudo test -f /etc/restic/env; then
        warn "/etc/restic/env exists — must not be present in snapshot"
    else
        log_ok "/etc/restic/env absent"
    fi
    local env_files
    env_files=$(sudo find /opt \( -name "*.env" -o -name "env" \) 2>/dev/null -print0 \
        | xargs -0 -r ls -la 2>/dev/null || true)
    if [[ -n "$env_files" ]]; then
        warn "Env files found in /opt"
        echo "$env_files"
    else
        log_ok "No env files found in /opt"
    fi

    echo
    log_info "── Private key file scan (/root and /home) ──"
    local priv_keys
    priv_keys=$(sudo find /root /home \( -name "id_rsa*" -o -name "id_ed25519*" \) 2>/dev/null || true)
    if [[ -n "$priv_keys" ]]; then
        warn "Private key files found"
        echo "$priv_keys"
    fi
}

# =============================================================================
# SUMMARY
# =============================================================================
print_summary() {
    local script_cmd snapshot_hint
    script_cmd="$0 $USERNAME"
    snapshot_hint="$0 $USERNAME --snapshot ubuntu-24.04-hardened-init-baseline-$(date +%Y%m%d)"

    echo
    echo -e "${BOLD}${GREEN}══════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}  Setup complete${RESET}"
    echo -e "${BOLD}${GREEN}══════════════════════════════════════════════${RESET}"

    if [[ ${#WARNINGS[@]} -gt 0 ]]; then
        echo
        echo -e "${YELLOW}  Warnings to review:${RESET}"
        for w in "${WARNINGS[@]}"; do
            echo -e "  ${YELLOW}⚠${RESET}  $w"
        done
    fi

    echo
    echo "  Remaining manual steps before snapshot:"
    echo "    1. Log out and back in (docker group takes effect)"
    echo "    2. Set timezone:   sudo timedatectl set-timezone UTC"
    echo "    3. Run verify:     ${script_cmd} --verify"
    echo "    4. Prepare Hetzner API token (Read & Write permissions)"
    echo "    5. Run snapshot:   ${snapshot_hint}"
    echo
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    echo
    echo -e "${BOLD}Hetzner Server Setup — $(date)${RESET}"
    echo -e "User: ${BOLD}${USERNAME}${RESET}  |  Swap: ${BOLD}${SWAP_GB}G${RESET}"
    echo

    preflight

    if [[ "$VERIFY_ONLY" == true ]]; then
        run_verify
        exit 0
    fi

    if [[ "$SNAPSHOT_MODE" == true ]]; then
        log_section "SNAPSHOT MODE"
        
        # Validate snapshot name
        if [[ ${#SNAPSHOT_NAME} -gt 255 ]]; then
            die "Snapshot name too long (max 255 characters)"
        fi
        if [[ ! "$SNAPSHOT_NAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then
            die "Snapshot name contains invalid characters. Use only: a-z, A-Z, 0-9, ., _, -"
        fi
        
        # Prompt for API token (not passed as parameter to avoid shell history)
        echo
        echo -e "${BLUE}Enter Hetzner API token (input will be hidden):${RESET}"
        echo "  Get your token from: https://console.hetzner.cloud/ → Security → API Tokens"
        echo "  Required permissions: Read & Write"
        echo
        read -rs -p "API Token: " HCLOUD_TOKEN
        echo
        
        if [[ -z "$HCLOUD_TOKEN" ]]; then
            die "API token is required for snapshot mode"
        fi
        
        # Clear token from memory after use, also ensure cleanup on exit
        trap 'unset HCLOUD_TOKEN 2>/dev/null; cleanup_change_tracking 2>/dev/null || true' EXIT
        
        log_info "Running verification checks before snapshot..."
        
        # Run verify but capture if there are issues
        WARNINGS=()
        run_verify
        
        # Check if there were warnings during verify
        if [[ ${#WARNINGS[@]} -gt 0 ]]; then
            echo
            log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            log_error "SNAPSHOT BLOCKED: Verification found ${#WARNINGS[@]} warning(s)"
            log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            for warning in "${WARNINGS[@]}"; do
                log_error "  - $warning"
            done
            die "Snapshot verification failed — fix the issues above and retry."
        fi
        
        log_ok "Verification passed"
        
        # Run hygiene - hard-fails on credential issues
        run_hygiene
        
        # Trigger snapshot via API
        trigger_snapshot
        
        exit 0
    fi

    init_change_tracking
    
    # Ensure cleanup on interrupt or termination
    trap 'log_warn "Interrupted - cleaning up..."; cleanup_change_tracking; exit 130' INT TERM
    
    s3_ssh_hardening
    s4_package_updates
    s5_firewall
    s6_fail2ban
    s7_monitoring
    s8_swap
    s9_docker
    s10_kernel_hardening
    s11_postfix
    s12_backups
    prompt_hostname

    print_change_report
    print_summary
    cleanup_change_tracking
}

main
