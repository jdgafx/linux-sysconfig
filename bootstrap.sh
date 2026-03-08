#!/usr/bin/env bash
###############################################################################
# bootstrap.sh — Single-command new machine setup
#
# This is the ONLY thing you need to run on a fresh Debian/Ubuntu install.
# It installs rclone, downloads your backup from Google Drive, and runs
# the full restore automatically.
#
# Usage (from fresh install):
#   curl -fsSL https://raw.githubusercontent.com/jdgafx/linux-sysconfig/main/bootstrap.sh | bash
#
# Or if you have the file:
#   bash bootstrap.sh
#
# Or with a local backup file:
#   bash bootstrap.sh /path/to/linux-sysconfig-*.tar.zst
###############################################################################
set -uo pipefail

# --- Colors & Styles ---------------------------------------------------------
RST='\033[0m'
BOLD='\033[1m'; DIM='\033[2m'; ITALIC='\033[3m'; UNDER='\033[4m'
RED='\033[0;31m';    LRED='\033[1;31m'
GREEN='\033[0;32m';  LGREEN='\033[1;32m'
YELLOW='\033[1;33m'; GOLD='\033[0;33m'
BLUE='\033[0;34m';   LBLUE='\033[1;34m'
PURPLE='\033[0;35m'; LPURPLE='\033[1;35m'
CYAN='\033[0;36m';   LCYAN='\033[1;36m'
WHITE='\033[1;37m';  GRAY='\033[0;90m'
BG_BLUE='\033[44m';  BG_GREEN='\033[42m'; BG_RED='\033[41m'

# --- Logging Setup -----------------------------------------------------------
BOOTSTRAP_START=$(date +%s)
LOGDIR="${HOME}/.cache/sysconfig-bootstrap"
mkdir -p "$LOGDIR"
LOGFILE="${LOGDIR}/bootstrap-$(date +%Y%m%d-%H%M%S).log"
touch "$LOGFILE"

# Tee all output to logfile while preserving terminal colors
exec > >(tee -a "$LOGFILE") 2>&1

log()     { echo -e "  ${GREEN}${BOLD}  ✓${RST}  $*"; }
info()    { echo -e "  ${CYAN}${BOLD}  ℹ${RST}  $*"; }
warn()    { echo -e "  ${YELLOW}${BOLD}  ⚠${RST}  $*"; }
err()     { echo -e "  ${RED}${BOLD}  ✗${RST}  $*"; }
step()    { echo -e "\n  ${LBLUE}${BOLD}━━━ $* ━━━${RST}"; }
detail()  { echo -e "  ${GRAY}    $*${RST}"; }

# --- Stats Tracking ----------------------------------------------------------
STATS_PKGS=0; STATS_TOOLS=0; STATS_CONFIGS=0; STATS_REPOS=0
STATS_ERRORS=0; STATS_WARNINGS=0

# --- Terminal Width ----------------------------------------------------------
TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
[ "$TERM_WIDTH" -gt 100 ] && TERM_WIDTH=100

hr() {
    echo -e "  ${GRAY}$(printf '─%.0s' $(seq 1 $((TERM_WIDTH - 4))))${RST}"
}

GDRIVE_FOLDER="Linux-Sysconfig-Backups"
WORK_DIR="/tmp/sysconfig-bootstrap-$$"
LOCAL_BACKUP="${1:-}"

# =============================================================================
#  SPLASH SCREEN
# =============================================================================
clear 2>/dev/null || true
echo ""
echo -e "${CYAN}"
cat <<'ART'

         ██╗     ██╗███╗   ██╗██╗   ██╗██╗  ██╗
         ██║     ██║████╗  ██║██║   ██║╚██╗██╔╝
         ██║     ██║██╔██╗ ██║██║   ██║ ╚███╔╝
         ██║     ██║██║╚██╗██║██║   ██║ ██╔██╗
         ███████╗██║██║ ╚████║╚██████╔╝██╔╝ ██╗
         ╚══════╝╚═╝╚═╝  ╚═══╝ ╚═════╝╚═╝  ╚═╝

ART
echo -e "${RST}"
echo -e "${WHITE}${BOLD}  ╔══════════════════════════════════════════════════════════════════╗${RST}"
echo -e "${WHITE}${BOLD}  ║${RST}  ${LCYAN}${BOLD}S Y S C O N F I G   B O O T S T R A P${RST}   ${DIM}v3.1${RST}             ${WHITE}${BOLD}║${RST}"
echo -e "${WHITE}${BOLD}  ║${RST}  ${DIM}One Command${RST} ${GRAY}·${RST} ${DIM}Full Environment${RST} ${GRAY}·${RST} ${DIM}Any Distro${RST}                ${WHITE}${BOLD}║${RST}"
echo -e "${WHITE}${BOLD}  ╚══════════════════════════════════════════════════════════════════╝${RST}"
echo ""
hr
echo ""
echo -e "  ${BOLD}What this will set up:${RST}"
echo ""
echo -e "    ${CYAN}◆${RST} ${BOLD}System${RST}       Packages, repos, keyrings, kernel config"
echo -e "    ${CYAN}◆${RST} ${BOLD}Dev Tools${RST}    Node/NVM, Bun, Python, Claude Code, OpenCode"
echo -e "    ${CYAN}◆${RST} ${BOLD}Desktop${RST}      KDE Plasma panels, themes, shortcuts, Wayland"
echo -e "    ${CYAN}◆${RST} ${BOLD}Boot${RST}         systemd-boot + dracut (UEFI boot manager)"
echo -e "    ${CYAN}◆${RST} ${BOLD}Security${RST}     SSH keys, git credentials, API keys"
echo -e "    ${CYAN}◆${RST} ${BOLD}Repos${RST}        All ~/dev git repos (full depth clone)"
echo -e "    ${CYAN}◆${RST} ${BOLD}Browsers${RST}     Chrome + Canary bookmarks, prefs, extensions"
echo -e "    ${CYAN}◆${RST} ${BOLD}Configs${RST}      Dotfiles, shell, rclone, fish, gh, terminals"
echo ""
hr
echo ""
echo -e "  ${DIM}Hostname:  ${RST}${BOLD}$(hostname)${RST}"
echo -e "  ${DIM}User:      ${RST}${BOLD}$(whoami)${RST}"
echo -e "  ${DIM}Distro:    ${RST}${BOLD}$(lsb_release -ds 2>/dev/null || cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"' || echo 'unknown')${RST}"
echo -e "  ${DIM}Kernel:    ${RST}${BOLD}$(uname -r)${RST}"
echo -e "  ${DIM}Time:      ${RST}${BOLD}$(date '+%Y-%m-%d %H:%M:%S %Z')${RST}"
echo -e "  ${DIM}Log:       ${RST}${BOLD}${LOGFILE}${RST}"
echo ""
hr

# =============================================================================
#  STEP 0: PERMISSIONS
# =============================================================================
step "STEP 1/7 — Checking Permissions"

if [ "$(id -u)" -eq 0 ]; then
    log "Running as root"
    SUDO=""
else
    SUDO="sudo"
    info "Checking sudo access..."
    if ! $SUDO -v 2>/dev/null; then
        err "sudo access required. Please run with sudo or enter your password."
        exit 1
    fi
    log "sudo access confirmed"
fi

# =============================================================================
#  STEP 1: BOOTSTRAP DEPENDENCIES
# =============================================================================
step "STEP 2/7 — Installing Bootstrap Dependencies"

BOOTSTRAP_PKGS="curl wget git zstd ca-certificates gnupg"
info "Installing: ${BOLD}${BOOTSTRAP_PKGS}${RST}"

if command -v apt-get &>/dev/null; then
    $SUDO apt-get update -qq 2>/dev/null || true
    $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y $BOOTSTRAP_PKGS 2>/dev/null
elif command -v dnf &>/dev/null; then
    $SUDO dnf install -y $BOOTSTRAP_PKGS 2>/dev/null
elif command -v yum &>/dev/null; then
    $SUDO yum install -y $BOOTSTRAP_PKGS 2>/dev/null
elif command -v pacman &>/dev/null; then
    $SUDO pacman -Sy --noconfirm --needed $BOOTSTRAP_PKGS 2>/dev/null
elif command -v zypper &>/dev/null; then
    $SUDO zypper install -y $BOOTSTRAP_PKGS 2>/dev/null
elif command -v apk &>/dev/null; then
    $SUDO apk add $BOOTSTRAP_PKGS 2>/dev/null
else
    err "No supported package manager found (apt, dnf, yum, pacman, zypper, apk)"
    exit 1
fi || {
    err "Failed to install basic dependencies"
    exit 1
}
STATS_PKGS=$((STATS_PKGS + $(echo $BOOTSTRAP_PKGS | wc -w)))
log "Base dependencies ready"

# =============================================================================
#  STEP 2: RCLONE
# =============================================================================
step "STEP 3/7 — Setting Up Rclone"

if ! command -v rclone &>/dev/null; then
    info "Installing rclone..."
    curl -fsSL https://rclone.org/install.sh | $SUDO bash || {
        err "rclone installation failed"
        exit 1
    }
    STATS_TOOLS=$((STATS_TOOLS + 1))
fi
log "rclone $(rclone version --check 2>/dev/null | head -1 || echo 'installed')"

# =============================================================================
#  STEP 3: GOOGLE DRIVE
# =============================================================================
if [ -z "$LOCAL_BACKUP" ]; then
    step "STEP 4/7 — Connecting to Google Drive"

    if ! rclone listremotes 2>/dev/null | grep -q "gdrive:"; then
        echo ""
        info "rclone needs to authenticate with Google Drive."
        echo -e "    ${DIM}This will open a browser window for OAuth login.${RST}"
        echo -e "    ${DIM}If you're on a headless machine, use: ${CYAN}rclone config${RST}"
        echo ""

        rclone config create gdrive drive || {
            echo ""
            warn "Auto-config failed. Running interactive setup..."
            echo -e "    ${YELLOW}Choose: New remote -> name: gdrive -> type: drive -> follow prompts${RST}"
            rclone config
        }
    fi

    if ! rclone lsd gdrive: &>/dev/null 2>&1; then
        err "Cannot access Google Drive. Please run: rclone config reconnect gdrive:"
        exit 1
    fi
    log "Google Drive connected"

    # --- Find and download latest backup ---
    step "STEP 5/7 — Downloading Latest Backup"

    info "Searching ${BOLD}gdrive:${GDRIVE_FOLDER}/${RST}..."

    LATEST=$(rclone lsf "gdrive:${GDRIVE_FOLDER}/" --files-only 2>/dev/null | \
        grep "linux-sysconfig-.*\.tar\.zst\(\.age\)\?" | grep -v '\-dev-data' | sort -r | head -1)

    if [ -z "$LATEST" ]; then
        err "No backup found in gdrive:${GDRIVE_FOLDER}/"
        echo -e "    Available files:"
        rclone ls "gdrive:${GDRIVE_FOLDER}/" 2>/dev/null || echo "      (empty or folder doesn't exist)"
        echo ""
        echo -e "    If you have a local backup, run: ${CYAN}bash bootstrap.sh /path/to/backup.tar.zst${RST}"
        exit 1
    fi

    log "Found: ${BOLD}${LATEST}${RST}"
    LATEST_SIZE=$(rclone ls "gdrive:${GDRIVE_FOLDER}/${LATEST}" 2>/dev/null | awk '{printf "%.1f MB", $1/1048576}')
    detail "Size: ${LATEST_SIZE}"

    mkdir -p "$WORK_DIR"

    DL_START=$(date +%s)
    info "Downloading backup..."
    rclone copy "gdrive:${GDRIVE_FOLDER}/${LATEST}" "$WORK_DIR" --progress --transfers=8 || {
        err "Download failed"
        exit 1
    }
    DL_END=$(date +%s)
    DL_SECS=$((DL_END - DL_START))
    BACKUP_FILE="$WORK_DIR/$LATEST"
    BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    log "Downloaded: ${BOLD}${BACKUP_SIZE}${RST} in ${DL_SECS}s"

    # Also download restore.sh from Drive if available
    rclone copy "gdrive:${GDRIVE_FOLDER}/restore.sh" "$WORK_DIR" 2>/dev/null || true
else
    BACKUP_FILE="$LOCAL_BACKUP"
    if [ ! -f "$BACKUP_FILE" ]; then
        err "Backup file not found: $BACKUP_FILE"
        exit 1
    fi
    BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    log "Using local backup: ${BOLD}${BACKUP_FILE}${RST} (${BACKUP_SIZE})"
fi

# =============================================================================
#  STEP 5: GET RESTORE SCRIPT
# =============================================================================
step "STEP 6/7 — Preparing Restore Script"

RESTORE_SCRIPT=""

# Check if downloaded from Drive
if [ -f "$WORK_DIR/restore.sh" ]; then
    RESTORE_SCRIPT="$WORK_DIR/restore.sh"
    log "Using restore.sh from Google Drive"
fi

# Try to get from GitHub (preferred — always latest)
if [ -z "$RESTORE_SCRIPT" ]; then
    info "Downloading restore.sh from GitHub..."
    mkdir -p "$WORK_DIR"
    curl -fsSL "https://raw.githubusercontent.com/jdgafx/linux-sysconfig/main/restore.sh" \
        -o "$WORK_DIR/restore.sh" 2>/dev/null && RESTORE_SCRIPT="$WORK_DIR/restore.sh"
fi

# Extract from backup as last resort
if [ -z "$RESTORE_SCRIPT" ]; then
    warn "Extracting restore.sh from backup..."
    tar -I zstd -xf "$BACKUP_FILE" -C "$WORK_DIR" --wildcards "*/restore.sh" 2>/dev/null || true
    RESTORE_SCRIPT=$(find "$WORK_DIR" -name "restore.sh" -type f | head -1)
fi

if [ -z "$RESTORE_SCRIPT" ] || [ ! -f "$RESTORE_SCRIPT" ]; then
    err "Could not find restore.sh anywhere!"
    echo "    Please download it manually from: https://github.com/jdgafx/linux-sysconfig"
    exit 1
fi

chmod +x "$RESTORE_SCRIPT"
log "restore.sh ready"

# --- Decrypt if encrypted ----------------------------------------------------
if [[ "$BACKUP_FILE" == *.age ]]; then
    step "Decrypting Backup"
    DECRYPTED="${BACKUP_FILE%.age}"

    if ! command -v age &>/dev/null && ! command -v gpg &>/dev/null; then
        info "Installing age for decryption..."
        if command -v apt-get &>/dev/null; then
            $SUDO apt-get install -y age 2>/dev/null
        elif command -v dnf &>/dev/null; then
            $SUDO dnf install -y age 2>/dev/null
        elif command -v pacman &>/dev/null; then
            $SUDO pacman -S --noconfirm age 2>/dev/null
        elif command -v apk &>/dev/null; then
            $SUDO apk add age 2>/dev/null
        fi
    fi

    if command -v age &>/dev/null; then
        if [ -n "${BACKUP_PASSPHRASE:-}" ]; then
            printf '%s\n' "$BACKUP_PASSPHRASE" | \
                script -q /dev/null -c "age -d -o '$DECRYPTED' '$BACKUP_FILE'" >/dev/null 2>&1
        else
            age -d -o "$DECRYPTED" "$BACKUP_FILE"
        fi
    elif command -v gpg &>/dev/null; then
        if [ -n "${BACKUP_PASSPHRASE:-}" ]; then
            echo "$BACKUP_PASSPHRASE" | gpg --batch --yes --passphrase-fd 0 -d -o "$DECRYPTED" "$BACKUP_FILE"
        else
            gpg -d -o "$DECRYPTED" "$BACKUP_FILE"
        fi
    else
        err "Backup is encrypted but neither age nor gpg is available"
        exit 1
    fi

    BACKUP_FILE="$DECRYPTED"
    log "Decrypted successfully"
fi

# =============================================================================
#  STEP 6: FULL RESTORE
# =============================================================================
step "STEP 7/7 — Launching Full Restore"

echo ""
echo -e "  ${WHITE}${BOLD}┌─────────────────────────────────────────────────────┐${RST}"
echo -e "  ${WHITE}${BOLD}│${RST}  ${LCYAN}This will install all packages, dev tools,${RST}         ${WHITE}${BOLD}│${RST}"
echo -e "  ${WHITE}${BOLD}│${RST}  ${LCYAN}configs, repos, and desktop environment.${RST}           ${WHITE}${BOLD}│${RST}"
echo -e "  ${WHITE}${BOLD}│${RST}  ${DIM}Runs as root (sudo). Takes 10-30 minutes.${RST}         ${WHITE}${BOLD}│${RST}"
echo -e "  ${WHITE}${BOLD}└─────────────────────────────────────────────────────┘${RST}"
echo ""

RESTORE_START=$(date +%s)

if [ "$(id -u)" -eq 0 ]; then
    bash "$RESTORE_SCRIPT" "$BACKUP_FILE"
else
    $SUDO bash "$RESTORE_SCRIPT" "$BACKUP_FILE"
fi

EXIT_CODE=$?
RESTORE_END=$(date +%s)

# =============================================================================
#  CLEANUP & FINAL REPORT
# =============================================================================
rm -rf "$WORK_DIR"

BOOTSTRAP_END=$(date +%s)
TOTAL_SECS=$((BOOTSTRAP_END - BOOTSTRAP_START))
RESTORE_SECS=$((RESTORE_END - RESTORE_START))
TOTAL_MIN=$((TOTAL_SECS / 60))
TOTAL_SEC=$((TOTAL_SECS % 60))

echo ""
hr

if [ $EXIT_CODE -eq 0 ]; then
    echo ""
    echo -e "${LGREEN}"
    cat <<'ART'
      ███████╗██╗   ██╗ ██████╗ ██████╗███████╗███████╗███████╗
      ██╔════╝██║   ██║██╔════╝██╔════╝██╔════╝██╔════╝██╔════╝
      ███████╗██║   ██║██║     ██║     █████╗  ███████╗███████╗
      ╚════██║██║   ██║██║     ██║     ██╔══╝  ╚════██║╚════██║
      ███████║╚██████╔╝╚██████╗╚██████╗███████╗███████║███████║
      ╚══════╝ ╚═════╝  ╚═════╝ ╚═════╝╚══════╝╚══════╝╚══════╝
ART
    echo -e "${RST}"
    echo -e "${WHITE}${BOLD}  ╔══════════════════════════════════════════════════════════════════╗${RST}"
    echo -e "${WHITE}${BOLD}  ║${RST}  ${LGREEN}${BOLD}B O O T S T R A P   C O M P L E T E${RST}                         ${WHITE}${BOLD}║${RST}"
    echo -e "${WHITE}${BOLD}  ║${RST}  ${DIM}Your dev machine is fully configured!${RST}                       ${WHITE}${BOLD}║${RST}"
    echo -e "${WHITE}${BOLD}  ╚══════════════════════════════════════════════════════════════════╝${RST}"
else
    echo ""
    echo -e "${YELLOW}${BOLD}  ╔══════════════════════════════════════════════════════════════════╗${RST}"
    echo -e "${YELLOW}${BOLD}  ║${RST}  ${YELLOW}${BOLD}COMPLETED WITH WARNINGS${RST}                                      ${YELLOW}${BOLD}║${RST}"
    echo -e "${YELLOW}${BOLD}  ║${RST}  ${DIM}Most errors are non-blocking — check log for details.${RST}      ${YELLOW}${BOLD}║${RST}"
    echo -e "${YELLOW}${BOLD}  ╚══════════════════════════════════════════════════════════════════╝${RST}"
fi

echo ""
hr
echo ""
echo -e "  ${WHITE}${BOLD}STATS${RST}"
echo ""
echo -e "    ${CYAN}⏱${RST}  Total time:     ${BOLD}${TOTAL_MIN}m ${TOTAL_SEC}s${RST}"
echo -e "    ${CYAN}⏱${RST}  Restore time:   ${BOLD}$((RESTORE_SECS / 60))m $((RESTORE_SECS % 60))s${RST}"
echo -e "    ${CYAN}📦${RST}  Backup size:    ${BOLD}${BACKUP_SIZE:-unknown}${RST}"
echo -e "    ${CYAN}💾${RST}  Backup file:    ${DIM}${BACKUP_FILE:-none}${RST}"
echo -e "    ${CYAN}📋${RST}  Full log:       ${BOLD}${LOGFILE}${RST}"
echo -e "    ${CYAN}🖥${RST}  Hostname:       ${BOLD}$(hostname)${RST}"
echo -e "    ${CYAN}🐧${RST}  Distro:         ${BOLD}$(lsb_release -ds 2>/dev/null || echo 'unknown')${RST}"
echo ""
hr
echo ""
echo -e "  ${WHITE}${BOLD}NEXT STEPS${RST}"
echo ""
echo -e "    ${LGREEN}1.${RST}  ${BOLD}Reboot${RST} to activate systemd-boot, KDE panels, and all configs"
echo -e "        ${CYAN}sudo reboot${RST}"
echo ""
echo -e "    ${LGREEN}2.${RST}  After reboot, verify your environment:"
echo -e "        ${CYAN}claude --version${RST}    ${DIM}# Claude Code CLI${RST}"
echo -e "        ${CYAN}node --version${RST}      ${DIM}# Node.js${RST}"
echo -e "        ${CYAN}bun --version${RST}       ${DIM}# Bun runtime${RST}"
echo -e "        ${CYAN}gh auth status${RST}      ${DIM}# GitHub CLI${RST}"
echo ""
echo -e "    ${LGREEN}3.${RST}  If panels look wrong after reboot:"
echo -e "        ${CYAN}kquitapp6 plasmashell && sleep 2 && plasmashell &${RST}"
echo ""
hr
echo ""
echo -e "  ${WHITE}${BOLD}TO RUN THIS AGAIN${RST}"
echo ""
echo -e "    ${LCYAN}${BOLD}curl -fsSL https://raw.githubusercontent.com/jdgafx/linux-sysconfig/main/bootstrap.sh | bash${RST}"
echo ""
echo -e "  ${DIM}Source: https://github.com/jdgafx/linux-sysconfig${RST}"
echo ""
hr
echo ""
echo -e "  ${DIM}Bootstrap completed at $(date '+%Y-%m-%d %H:%M:%S %Z')${RST}"
echo -e "  ${DIM}Log saved to: ${LOGFILE}${RST}"
echo ""

exit $EXIT_CODE
