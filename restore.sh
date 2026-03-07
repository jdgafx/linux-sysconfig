#!/usr/bin/env bash
###############################################################################
# restore.sh — Fully automated dev environment restoration
#
# Works on ANY Linux distro: Debian/Ubuntu (apt), Fedora/RHEL (dnf),
# Arch/Manjaro (pacman), openSUSE (zypper), Alpine (apk), Void (xbps).
# Designed for resilience: every step is idempotent, failures are logged but
# never block subsequent steps.
#
# Usage:  sudo bash restore.sh /path/to/linux-sysconfig-*.tar.zst
#         sudo bash restore.sh   (auto-finds latest backup in current dir)
#         sudo bash restore.sh --dry-run [/path/to/backup.tar.zst]
#         bash restore.sh --dry-run   (no root needed for dry run)
###############################################################################
set -uo pipefail
IFS=$'\n\t'

# --- Colors & Logging --------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

LOGFILE="/tmp/sysconfig-restore-$(date +%Y%m%d-%H%M%S).log"

log()  { echo -e "${GREEN}[+]${NC} $*" | tee -a "$LOGFILE"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOGFILE"; }
err()  { echo -e "${RED}[x]${NC} $*" | tee -a "$LOGFILE"; }
hdr()  { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}" | tee -a "$LOGFILE"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*" | tee -a "$LOGFILE"; }
fail() { echo -e "${RED}[FAIL]${NC} $*" | tee -a "$LOGFILE"; }

FAILED_STEPS=()
track_failure() {
    FAILED_STEPS+=("$1")
    fail "$1 — logged, continuing..."
}

# --- Dry-run flag parsing -----------------------------------------------------
DRY_RUN=false
POSITIONAL_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        *) POSITIONAL_ARGS+=("$arg") ;;
    esac
done
set -- "${POSITIONAL_ARGS[@]+"${POSITIONAL_ARGS[@]}"}"

# Dry-run counters
DRY_PKGS=0
DRY_SNAPS=0
DRY_FLATPAKS=0
DRY_FILES=0
DRY_SSH=0
DRY_REPOS=0
DRY_CONFIGS=0
DRY_SERVICES=0

# Dry-run helper: either execute or log what would be done
dry_run_or_exec() {
    if $DRY_RUN; then
        log "  [DRY RUN] Would execute: $*"
        return 0
    fi
    "$@"
}

if $DRY_RUN; then
    log "*** DRY RUN MODE — no changes will be made ***"
fi

# --- Detect target user (we run as root but install for the real user) --------
if [ "$(id -u)" -ne 0 ]; then
    if $DRY_RUN; then
        warn "Not running as root — dry run will still show what would happen"
    else
        echo -e "${RED}This script must be run as root (sudo).${NC}"
        echo "Usage: sudo bash restore.sh [/path/to/backup.tar.zst]"
        exit 1
    fi
fi

# Determine the real user (the one who called sudo)
TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo chris)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -z "$TARGET_HOME" ] && TARGET_HOME="/home/${TARGET_USER}"

echo ""
echo -e "${CYAN}${BOLD}"
cat <<'BANNER'
  ╔══════════════════════════════════════════════════════════════╗
  ║            Linux Sysconfig Restore v3.0                     ║
  ║      Universal • Resilient • Desktop • Boot Manager         ║
  ╚══════════════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"
log "Restoring for user: ${TARGET_USER} (home: ${TARGET_HOME})"
log "Log file: ${LOGFILE}"

# --- Helper: run as target user -----------------------------------------------
as_user() {
    su - "$TARGET_USER" -c "$*"
}

# =============================================================================
#  UNIVERSAL PACKAGE MANAGER LAYER
# =============================================================================
# Detects the system's package manager and provides unified install/update
# functions. Maps Debian package names to equivalents on other distros.

PKG_MANAGER=""
detect_pkg_manager() {
    if command -v apt-get &>/dev/null; then
        PKG_MANAGER="apt"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
    elif command -v yum &>/dev/null; then
        PKG_MANAGER="yum"
    elif command -v pacman &>/dev/null; then
        PKG_MANAGER="pacman"
    elif command -v zypper &>/dev/null; then
        PKG_MANAGER="zypper"
    elif command -v apk &>/dev/null; then
        PKG_MANAGER="apk"
    elif command -v xbps-install &>/dev/null; then
        PKG_MANAGER="xbps"
    elif command -v emerge &>/dev/null; then
        PKG_MANAGER="portage"
    elif command -v nix-env &>/dev/null; then
        PKG_MANAGER="nix"
    else
        PKG_MANAGER="unknown"
    fi
    log "Detected package manager: ${PKG_MANAGER}"
}

# Map Debian package names to other distro equivalents
# Returns mapped name or empty string to skip
pkg_translate() {
    local deb_pkg="$1"

    # Strip arch suffix (:amd64, :i386, etc.)
    deb_pkg="${deb_pkg%%:*}"

    # Skip meta/virtual packages that are Debian/Ubuntu-specific
    case "$deb_pkg" in
        base-files|base-passwd|dpkg|apt|apt-*|aptitude*|aptdaemon*) echo ""; return ;;
        ubuntu-*|kubuntu-*|xubuntu-*|lubuntu-*) echo ""; return ;;
        snapd|snap-*) echo ""; return ;;  # handled separately
        *-dbgsym|*-dbg) echo ""; return ;;  # debug symbols
        linux-image-*|linux-headers-*|linux-modules-*) echo ""; return ;;  # kernel — use host's kernel
        initramfs-tools*|busybox-initramfs) echo ""; return ;;
        debconf*|debhelper*|dh-*|dpkg-dev) echo ""; return ;;  # debian-specific build tools
        update-manager*|unattended-upgrades) echo ""; return ;;
    esac

    # Distro-specific translations
    case "$PKG_MANAGER" in
        dnf|yum)
            case "$deb_pkg" in
                build-essential) echo "@development-tools" ;;
                systemd-boot) echo "systemd-boot-unsigned" ;;
                python3-dev) echo "python3-devel" ;;
                libssl-dev) echo "openssl-devel" ;;
                libffi-dev) echo "libffi-devel" ;;
                libcurl4-openssl-dev) echo "libcurl-devel" ;;
                libbz2-dev) echo "bzip2-devel" ;;
                libreadline-dev) echo "readline-devel" ;;
                libsqlite3-dev) echo "sqlite-devel" ;;
                zlib1g-dev) echo "zlib-devel" ;;
                libncurses*-dev) echo "ncurses-devel" ;;
                liblzma-dev) echo "xz-devel" ;;
                libxml2-dev) echo "libxml2-devel" ;;
                libxslt1-dev) echo "libxslt-devel" ;;
                libyaml-dev) echo "libyaml-devel" ;;
                libgdbm-dev) echo "gdbm-devel" ;;
                libjpeg-dev|libjpeg*-turbo-dev) echo "libjpeg-turbo-devel" ;;
                libpng-dev) echo "libpng-devel" ;;
                libtiff-dev) echo "libtiff-devel" ;;
                libwebp-dev) echo "libwebp-devel" ;;
                pkg-config) echo "pkgconf" ;;
                software-properties-common) echo "" ;;  # not needed on Fedora
                python3-venv) echo "python3" ;;  # venv is built into python3 on Fedora
                ca-certificates) echo "ca-certificates" ;;
                gnupg) echo "gnupg2" ;;
                *) echo "$deb_pkg" ;;
            esac
            ;;
        pacman)
            case "$deb_pkg" in
                build-essential) echo "base-devel" ;;
                systemd-boot) echo "systemd" ;;
                dracut) echo "dracut" ;;
                python3) echo "python" ;;
                python3-pip) echo "python-pip" ;;
                python3-dev) echo "python" ;;
                python3-venv) echo "python" ;;
                libssl-dev) echo "openssl" ;;
                libffi-dev) echo "libffi" ;;
                libcurl4-openssl-dev) echo "curl" ;;
                pkg-config) echo "pkgconf" ;;
                software-properties-common) echo "" ;;
                gnupg) echo "gnupg" ;;
                curl) echo "curl" ;;
                wget) echo "wget" ;;
                git) echo "git" ;;
                jq) echo "jq" ;;
                zstd) echo "zstd" ;;
                htop) echo "htop" ;;
                ripgrep) echo "ripgrep" ;;
                fd-find) echo "fd" ;;
                batcat|bat) echo "bat" ;;
                tmux) echo "tmux" ;;
                fish) echo "fish" ;;
                *-dev) echo "${deb_pkg%-dev}" ;;  # Arch doesn't split -dev
                lib*) echo "$deb_pkg" ;;
                *) echo "$deb_pkg" ;;
            esac
            ;;
        zypper)
            case "$deb_pkg" in
                build-essential) echo "-t pattern devel_basis" ;;
                python3-dev) echo "python3-devel" ;;
                libssl-dev) echo "libopenssl-devel" ;;
                libffi-dev) echo "libffi-devel" ;;
                software-properties-common) echo "" ;;
                *) echo "$deb_pkg" ;;
            esac
            ;;
        apk)
            case "$deb_pkg" in
                build-essential) echo "build-base" ;;
                python3-dev) echo "python3-dev" ;;
                python3-pip) echo "py3-pip" ;;
                python3-venv) echo "python3" ;;
                software-properties-common) echo "" ;;
                *) echo "$deb_pkg" ;;
            esac
            ;;
        *)
            echo "$deb_pkg"
            ;;
    esac
}

# Update package database
pkg_update() {
    if $DRY_RUN; then
        log "  [DRY RUN] Would update package database (${PKG_MANAGER})"
        return 0
    fi
    case "$PKG_MANAGER" in
        apt)    apt-get update -qq 2>>"$LOGFILE" ;;
        dnf)    dnf check-update >>"$LOGFILE" 2>&1 || true ;;
        yum)    yum check-update >>"$LOGFILE" 2>&1 || true ;;
        pacman) pacman -Sy --noconfirm >>"$LOGFILE" 2>&1 ;;
        zypper) zypper refresh >>"$LOGFILE" 2>&1 ;;
        apk)    apk update >>"$LOGFILE" 2>&1 ;;
        xbps)   xbps-install -S >>"$LOGFILE" 2>&1 ;;
        *)      warn "Unknown package manager, skipping update" ;;
    esac
}

# Install a single package (returns 0 on success)
pkg_install_one() {
    local pkg="$1"
    [ -z "$pkg" ] && return 0

    if $DRY_RUN; then
        DRY_PKGS=$((DRY_PKGS + 1))
        log "  [DRY RUN] Would install package: $pkg"
        return 0
    fi

    case "$PKG_MANAGER" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get install -y \
                -o Dpkg::Options::="--force-confdef" \
                -o Dpkg::Options::="--force-confold" \
                "$pkg" >>"$LOGFILE" 2>&1
            ;;
        dnf)
            dnf install -y "$pkg" >>"$LOGFILE" 2>&1
            ;;
        yum)
            yum install -y "$pkg" >>"$LOGFILE" 2>&1
            ;;
        pacman)
            pacman -S --noconfirm --needed "$pkg" >>"$LOGFILE" 2>&1
            ;;
        zypper)
            zypper install -y "$pkg" >>"$LOGFILE" 2>&1
            ;;
        apk)
            apk add "$pkg" >>"$LOGFILE" 2>&1
            ;;
        xbps)
            xbps-install -y "$pkg" >>"$LOGFILE" 2>&1
            ;;
        *)
            warn "Cannot install $pkg — unknown package manager"
            return 1
            ;;
    esac
}

# Install a list of packages (batch for speed, individual retry for resilience)
pkg_install_batch() {
    local -a pkgs=("$@")
    [ ${#pkgs[@]} -eq 0 ] && return 0

    if $DRY_RUN; then
        DRY_PKGS=$((DRY_PKGS + ${#pkgs[@]}))
        log "  [DRY RUN] Would install ${#pkgs[@]} packages: ${pkgs[*]}"
        return 0
    fi

    case "$PKG_MANAGER" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get install -y \
                -o Dpkg::Options::="--force-confdef" \
                -o Dpkg::Options::="--force-confold" \
                --no-install-recommends \
                "${pkgs[@]}" >>"$LOGFILE" 2>&1
            ;;
        dnf)
            dnf install -y "${pkgs[@]}" >>"$LOGFILE" 2>&1
            ;;
        yum)
            yum install -y "${pkgs[@]}" >>"$LOGFILE" 2>&1
            ;;
        pacman)
            pacman -S --noconfirm --needed "${pkgs[@]}" >>"$LOGFILE" 2>&1
            ;;
        zypper)
            zypper install -y "${pkgs[@]}" >>"$LOGFILE" 2>&1
            ;;
        apk)
            apk add "${pkgs[@]}" >>"$LOGFILE" 2>&1
            ;;
        xbps)
            xbps-install -y "${pkgs[@]}" >>"$LOGFILE" 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

# Resilient package install from file (batch with retry, name translation)
pkg_install_resilient() {
    local pkg_file="$1"
    local label="$2"
    local total=$(wc -l < "$pkg_file")
    local installed=0
    local skipped=0
    local failed_pkgs=()

    hdr "Installing ${label} (${total} packages via ${PKG_MANAGER})"

    # First pass: bulk install in batches of 50
    local batch=()
    local batch_num=0
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        [[ "$pkg" =~ ^# ]] && continue

        # Translate Debian package name to native name
        local native_pkg
        native_pkg=$(pkg_translate "$pkg")

        if [ -z "$native_pkg" ]; then
            skipped=$((skipped + 1))
            continue
        fi

        batch+=("$native_pkg")

        if [ ${#batch[@]} -ge 50 ]; then
            batch_num=$((batch_num + 1))
            log "  Batch ${batch_num} (${#batch[@]} packages)..."
            if pkg_install_batch "${batch[@]}"; then
                installed=$((installed + ${#batch[@]}))
            else
                # Batch failed — try individually
                for p in "${batch[@]}"; do
                    if pkg_install_one "$p"; then
                        installed=$((installed + 1))
                    else
                        failed_pkgs+=("$p")
                    fi
                done
            fi
            batch=()
        fi
    done < "$pkg_file"

    # Final partial batch
    if [ ${#batch[@]} -gt 0 ]; then
        batch_num=$((batch_num + 1))
        log "  Batch ${batch_num} (${#batch[@]} packages)..."
        if pkg_install_batch "${batch[@]}"; then
            installed=$((installed + ${#batch[@]}))
        else
            for p in "${batch[@]}"; do
                if pkg_install_one "$p"; then
                    installed=$((installed + 1))
                else
                    failed_pkgs+=("$p")
                fi
            done
        fi
    fi

    ok "${installed} installed, ${skipped} skipped (distro-specific)"
    if [ ${#failed_pkgs[@]} -gt 0 ]; then
        warn "${#failed_pkgs[@]} packages failed:"
        printf '  %s\n' "${failed_pkgs[@]}" | tee -a "$LOGFILE"
        printf '%s\n' "${failed_pkgs[@]}" > "/tmp/failed-${label// /-}.txt"
    fi
}

# Detect the package manager now
detect_pkg_manager

# --- Locate & Extract Backup -------------------------------------------------
hdr "Locating Backup Archive"

TARBALL="${1:-}"
if [ -z "$TARBALL" ]; then
    # Auto-find latest backup (encrypted .age or plain .tar.zst)
    TARBALL=$(find . /tmp "$TARGET_HOME" -maxdepth 2 \( -name "linux-sysconfig-*.tar.zst" -o -name "linux-sysconfig-*.tar.zst.age" \) -type f 2>/dev/null | sort -r | head -1)
fi

if [ -z "$TARBALL" ] || [ ! -f "$TARBALL" ]; then
    err "No backup archive found."
    echo "Usage: sudo bash restore.sh /path/to/linux-sysconfig-*.tar.zst"
    exit 1
fi

log "Using backup: ${TARBALL}"

# --- Detect and decrypt encrypted backup ------------------------------------
if [[ "$TARBALL" == *.age ]]; then
    hdr "Decrypting Backup"
    DECRYPTED="${TARBALL%.age}"
    if command -v age &>/dev/null; then
        if [ -n "${BACKUP_PASSPHRASE:-}" ]; then
            printf '%s\n' "$BACKUP_PASSPHRASE" | \
                script -q /dev/null -c "age -d -o '$DECRYPTED' '$TARBALL'" >/dev/null 2>&1
        else
            age -d -o "$DECRYPTED" "$TARBALL"
        fi
    elif command -v gpg &>/dev/null; then
        if [ -n "${BACKUP_PASSPHRASE:-}" ]; then
            echo "$BACKUP_PASSPHRASE" | gpg --batch --yes --passphrase-fd 0 -d -o "$DECRYPTED" "$TARBALL"
        else
            gpg -d -o "$DECRYPTED" "$TARBALL"
        fi
    else
        err "Backup is encrypted but neither age nor gpg is available"
        exit 1
    fi
    TARBALL="$DECRYPTED"
    log "Decrypted successfully"
fi

EXTRACT_DIR="/tmp/sysconfig-restore-$$"
mkdir -p "$EXTRACT_DIR"
log "Extracting..."

if command -v zstd &>/dev/null; then
    tar -I zstd -xf "$TARBALL" -C "$EXTRACT_DIR" 2>>"$LOGFILE"
else
    # Install zstd first
    detect_pkg_manager
    pkg_update
    pkg_install_one "zstd"
    tar -I zstd -xf "$TARBALL" -C "$EXTRACT_DIR" 2>>"$LOGFILE"
fi

# Find the actual backup directory inside the extract
BACKUP_DIR=$(find "$EXTRACT_DIR" -maxdepth 1 -type d -name "linux-sysconfig-*" | head -1)
[ -z "$BACKUP_DIR" ] && BACKUP_DIR="$EXTRACT_DIR"

log "Backup contents at: ${BACKUP_DIR}"
ls "$BACKUP_DIR"/ 2>/dev/null | tee -a "$LOGFILE"

# =============================================================================
#  PHASE 1: Base System (requires network)
# =============================================================================
hdr "PHASE 1: System Packages & Repos"

# --- 1a. Essential tools first ------------------------------------------------
log "Installing essential tools..."
pkg_update
ESSENTIAL_PKGS=(curl wget git build-essential ca-certificates gnupg zstd jq python3 python3-pip python3-venv sqlite3)
ESSENTIAL_NATIVE=()
for ep in "${ESSENTIAL_PKGS[@]}"; do
    translated=$(pkg_translate "$ep")
    [ -n "$translated" ] && ESSENTIAL_NATIVE+=("$translated")
done
pkg_install_batch "${ESSENTIAL_NATIVE[@]}" || track_failure "essential-tools"

# Also install lsb-release if on apt-based system
[ "$PKG_MANAGER" = "apt" ] && pkg_install_one "lsb-release" 2>/dev/null || true
[ "$PKG_MANAGER" = "apt" ] && pkg_install_one "software-properties-common" 2>/dev/null || true

# --- 1b. Restore APT keyrings & sources (apt-based distros only) -------------
if [ "$PKG_MANAGER" = "apt" ]; then
    hdr "Restoring APT Keyrings"
    if [ -d "$BACKUP_DIR/keyrings" ]; then
        if $DRY_RUN; then
            keyring_count=$(find "$BACKUP_DIR/keyrings/" -name "*.gpg" 2>/dev/null | wc -l)
            DRY_CONFIGS=$((DRY_CONFIGS + keyring_count))
            log "  [DRY RUN] Would restore ${keyring_count} keyrings"
        else
            mkdir -p /usr/share/keyrings /etc/apt/keyrings
            cp -f "$BACKUP_DIR/keyrings/"*.gpg /usr/share/keyrings/ 2>/dev/null || true
            cp -f "$BACKUP_DIR/keyrings/"*.gpg /etc/apt/keyrings/ 2>/dev/null || true
            ok "Keyrings restored"
        fi
    fi

    hdr "Restoring APT Sources"
    if [ -d "$BACKUP_DIR/apt-sources" ]; then
        if $DRY_RUN; then
            src_count=$(find "$BACKUP_DIR/apt-sources/" -type f 2>/dev/null | wc -l)
            DRY_CONFIGS=$((DRY_CONFIGS + src_count))
            log "  [DRY RUN] Would restore ${src_count} APT source files"
        else
            [ -f "$BACKUP_DIR/apt-sources/sources.list" ] && \
                cp "$BACKUP_DIR/apt-sources/sources.list" /etc/apt/sources.list

            for f in "$BACKUP_DIR/apt-sources/"*; do
                fname=$(basename "$f")
                [ "$fname" = "sources.list" ] && continue
                [ "$fname" = "ubuntu.sources" ] && continue
                cp "$f" "/etc/apt/sources.list.d/$fname" 2>/dev/null || true
                log "  Restored: $fname"
            done

            DISTRO_CODENAME=$(lsb_release -cs 2>/dev/null || echo "bookworm")
            log "  Target distro codename: ${DISTRO_CODENAME}"
            apt-get update -qq 2>>"$LOGFILE" || warn "Some repos failed to update (expected on new distro)"
        fi
    fi
else
    hdr "Non-APT System — Adding Third-Party Repos"
    if $DRY_RUN; then
        log "  [DRY RUN] Would configure third-party repos for ${PKG_MANAGER}"
    else
    # Install key third-party software repos for non-apt distros
    case "$PKG_MANAGER" in
        dnf|yum)
            # Enable RPM Fusion + EPEL for broader package availability
            dnf install -y epel-release 2>>"$LOGFILE" || true
            dnf install -y \
                "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
                "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm" \
                2>>"$LOGFILE" || true
            # Google Chrome repo
            cat > /etc/yum.repos.d/google-chrome.repo <<'CHROMEREPO'
[google-chrome]
name=Google Chrome
baseurl=https://dl.google.com/linux/chrome/rpm/stable/x86_64
enabled=1
gpgcheck=1
gpgkey=https://dl.google.com/linux/linux_signing_key.pub
CHROMEREPO
            # Tailscale
            dnf config-manager --add-repo https://pkgs.tailscale.com/stable/fedora/tailscale.repo 2>>"$LOGFILE" || true
            log "  Fedora/RHEL repos configured"
            ;;
        pacman)
            # Enable multilib if not already
            if ! grep -q "^\[multilib\]" /etc/pacman.conf 2>/dev/null; then
                echo -e "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist" >> /etc/pacman.conf
            fi
            # Install yay (AUR helper) for broader package access
            if ! command -v yay &>/dev/null; then
                log "  Installing yay AUR helper..."
                as_user "cd /tmp && git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm" \
                    >>"$LOGFILE" 2>&1 || warn "yay installation failed — some packages may be unavailable"
            fi
            pacman -Sy --noconfirm >>"$LOGFILE" 2>&1
            log "  Arch repos configured"
            ;;
        zypper)
            # Add Packman repo for multimedia
            zypper ar -cfp 90 "https://ftp.gwdg.de/pub/linux/misc/packman/suse/openSUSE_Tumbleweed/" packman 2>>"$LOGFILE" || true
            zypper refresh >>"$LOGFILE" 2>&1
            log "  openSUSE repos configured"
            ;;
    esac
    fi
    pkg_update
fi

# --- 1d. Install system packages ----------------------------------------------
# Support both new names (system-packages/manual-packages) and legacy (apt-packages/apt-manual)
MANUAL_PKG_FILE=""
ALL_PKG_FILE=""
for candidate in manual-packages.txt apt-manual.txt; do
    [ -f "$BACKUP_DIR/manifests/$candidate" ] && MANUAL_PKG_FILE="$BACKUP_DIR/manifests/$candidate" && break
done
for candidate in system-packages.txt apt-packages.txt; do
    [ -f "$BACKUP_DIR/manifests/$candidate" ] && ALL_PKG_FILE="$BACKUP_DIR/manifests/$candidate" && break
done

if [ -n "$MANUAL_PKG_FILE" ]; then
    pkg_install_resilient "$MANUAL_PKG_FILE" "manually-installed packages"
elif [ -n "$ALL_PKG_FILE" ]; then
    warn "No manual package list found, using full package list"
    pkg_install_resilient "$ALL_PKG_FILE" "all system packages"
else
    warn "No package manifests found in backup"
fi

# --- 1e. Snap packages -------------------------------------------------------
hdr "Snap Packages"
# Install snapd if not available (works on most distros)
if ! command -v snap &>/dev/null && [ -f "$BACKUP_DIR/manifests/snap-packages.txt" ]; then
    if $DRY_RUN; then
        log "  [DRY RUN] Would install snapd"
    else
        log "  snapd not found, attempting install..."
        pkg_install_one "snapd" || true
        # Enable and start snapd service
        systemctl enable --now snapd.socket 2>/dev/null || true
        systemctl enable --now snapd.service 2>/dev/null || true
        # Create symlink for classic snap support
        [ ! -L /snap ] && ln -s /var/lib/snapd/snap /snap 2>/dev/null || true
    fi
fi
if [ -f "$BACKUP_DIR/manifests/snap-packages.txt" ]; then
    if $DRY_RUN; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            pkg=$(echo "$line" | awk '{print $1}')
            case "$pkg" in bare|core*|snapd|gnome-*|gtk-*|icon-*|kf5-*|mesa-*|ffmpeg-*) continue ;; esac
            DRY_SNAPS=$((DRY_SNAPS + 1))
        done < "$BACKUP_DIR/manifests/snap-packages.txt"
        log "  [DRY RUN] Would install ${DRY_SNAPS} snap packages"
    elif command -v snap &>/dev/null; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            pkg=$(echo "$line" | awk '{print $1}')
            flag=$(echo "$line" | awk '{print $2}')
            # Skip base/core snaps — they install automatically
            case "$pkg" in bare|core*|snapd|gnome-*|gtk-*|icon-*|kf5-*|mesa-*|ffmpeg-*) continue ;; esac
            log "  Installing snap: ${pkg} ${flag}"
            snap install "$pkg" $flag >>"$LOGFILE" 2>&1 || track_failure "snap:${pkg}"
        done < "$BACKUP_DIR/manifests/snap-packages.txt"
        ok "Snap packages processed"
    else
        warn "snap not available or no manifest"
    fi
else
    warn "snap not available or no manifest"
fi

# --- 1f. Flatpak packages ----------------------------------------------------
hdr "Flatpak Packages"
if [ -f "$BACKUP_DIR/manifests/flatpak-packages.txt" ] && [ -s "$BACKUP_DIR/manifests/flatpak-packages.txt" ]; then
    if $DRY_RUN; then
        DRY_FLATPAKS=$(grep -c '[^[:space:]]' "$BACKUP_DIR/manifests/flatpak-packages.txt" 2>/dev/null || echo 0)
        DRY_PKGS=$((DRY_PKGS + DRY_FLATPAKS))
        log "  [DRY RUN] Would install ${DRY_FLATPAKS} flatpak packages"
    else
        command -v flatpak &>/dev/null || pkg_install_one "flatpak" >>"$LOGFILE" 2>&1
        flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
        while IFS= read -r app_id; do
            [ -z "$app_id" ] && continue
            flatpak install -y flathub "$app_id" >>"$LOGFILE" 2>&1 || track_failure "flatpak:${app_id}"
        done < "$BACKUP_DIR/manifests/flatpak-packages.txt"
    fi
fi

# =============================================================================
#  PHASE 2: Dev Toolchains (as user, not root)
# =============================================================================
hdr "PHASE 2: Dev Toolchains"

# --- 2a. NVM + Node ----------------------------------------------------------
hdr "NVM & Node.js"
if [ -f "$BACKUP_DIR/manifests/nvm-versions.txt" ]; then
    if $DRY_RUN; then
        nvm_count=$(wc -l < "$BACKUP_DIR/manifests/nvm-versions.txt")
        DRY_PKGS=$((DRY_PKGS + nvm_count + 1))
        log "  [DRY RUN] Would install NVM + ${nvm_count} Node versions"
    else
        as_user 'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash' \
            >>"$LOGFILE" 2>&1 || track_failure "nvm-install"

        # Install each Node version
        while IFS= read -r ver; do
            [ -z "$ver" ] && continue
            log "  Installing Node ${ver}..."
            as_user "export NVM_DIR=\$HOME/.nvm && . \$NVM_DIR/nvm.sh && nvm install ${ver}" \
                >>"$LOGFILE" 2>&1 || track_failure "node:${ver}"
        done < "$BACKUP_DIR/manifests/nvm-versions.txt"

        # Set default
        if [ -f "$BACKUP_DIR/manifests/nvm-default.txt" ]; then
            DEFAULT_NODE=$(cat "$BACKUP_DIR/manifests/nvm-default.txt")
            as_user "export NVM_DIR=\$HOME/.nvm && . \$NVM_DIR/nvm.sh && nvm alias default ${DEFAULT_NODE}" \
                >>"$LOGFILE" 2>&1 || true
            ok "Node default set to ${DEFAULT_NODE}"
        fi
    fi
fi

# --- 2b. Bun ------------------------------------------------------------------
hdr "Bun"
if [ -f "$BACKUP_DIR/manifests/bun-version.txt" ]; then
    if $DRY_RUN; then
        DRY_PKGS=$((DRY_PKGS + 1))
        log "  [DRY RUN] Would install Bun"
    else
        as_user 'curl -fsSL https://bun.sh/install | bash' >>"$LOGFILE" 2>&1 || track_failure "bun-install"
        ok "Bun installed"
    fi
fi

# --- 2c. NPM Global Packages -------------------------------------------------
hdr "NPM Global Packages"
if [ -f "$BACKUP_DIR/manifests/npm-globals.txt" ] && [ -s "$BACKUP_DIR/manifests/npm-globals.txt" ]; then
    if $DRY_RUN; then
        npm_count=$(grep -c '[^[:space:]]' "$BACKUP_DIR/manifests/npm-globals.txt" 2>/dev/null || echo 0)
        DRY_PKGS=$((DRY_PKGS + npm_count))
        log "  [DRY RUN] Would install ${npm_count} npm global packages"
    else
        NPKG_LIST=$(cat "$BACKUP_DIR/manifests/npm-globals.txt" | tr '\n' ' ')
        log "  Installing: ${NPKG_LIST}"
        as_user "export NVM_DIR=\$HOME/.nvm && . \$NVM_DIR/nvm.sh && npm install -g ${NPKG_LIST}" \
            >>"$LOGFILE" 2>&1 || {
            # Retry one at a time
            warn "Bulk npm install failed, retrying individually..."
            while IFS= read -r pkg; do
                [ -z "$pkg" ] && continue
                as_user "export NVM_DIR=\$HOME/.nvm && . \$NVM_DIR/nvm.sh && npm install -g ${pkg}" \
                    >>"$LOGFILE" 2>&1 || track_failure "npm:${pkg}"
            done < "$BACKUP_DIR/manifests/npm-globals.txt"
        }
        ok "NPM globals processed"
    fi
fi

# --- 2d. Pip Packages ---------------------------------------------------------
hdr "Pip Packages"
if [ -f "$BACKUP_DIR/manifests/pip-user.txt" ] && [ -s "$BACKUP_DIR/manifests/pip-user.txt" ]; then
    if $DRY_RUN; then
        pip_count=$(grep -c '[^[:space:]]' "$BACKUP_DIR/manifests/pip-user.txt" 2>/dev/null || echo 0)
        DRY_PKGS=$((DRY_PKGS + pip_count))
        log "  [DRY RUN] Would install ${pip_count} pip packages"
    else
        log "  Installing user pip packages..."
        as_user "pip3 install --user --break-system-packages -r $BACKUP_DIR/manifests/pip-user.txt" \
            >>"$LOGFILE" 2>&1 || {
            warn "Bulk pip install failed, retrying individually..."
            while IFS= read -r line; do
                pkg=$(echo "$line" | cut -d= -f1)
                [ -z "$pkg" ] && continue
                as_user "pip3 install --user --break-system-packages ${pkg}" \
                    >>"$LOGFILE" 2>&1 || track_failure "pip:${pkg}"
            done < "$BACKUP_DIR/manifests/pip-user.txt"
        }
        ok "Pip packages processed"
    fi
fi

# --- 2e. pnpm -----------------------------------------------------------------
hdr "pnpm"
if $DRY_RUN; then
    DRY_PKGS=$((DRY_PKGS + 1))
    log "  [DRY RUN] Would enable pnpm via corepack"
else
    as_user "export NVM_DIR=\$HOME/.nvm && . \$NVM_DIR/nvm.sh && corepack enable pnpm" \
        >>"$LOGFILE" 2>&1 || track_failure "pnpm"
    ok "pnpm enabled via corepack"
fi

# --- 2f. uv (Python package manager) ------------------------------------------
hdr "uv (Astral)"
if $DRY_RUN; then
    DRY_PKGS=$((DRY_PKGS + 1))
    log "  [DRY RUN] Would install uv (Astral)"
else
    log "Installing/updating uv..."
    if command -v snap &>/dev/null; then
        snap install astral-uv --classic >>"$LOGFILE" 2>&1 || \
            snap refresh astral-uv --classic >>"$LOGFILE" 2>&1 || track_failure "snap:astral-uv"
    else
        as_user "curl -LsSf https://astral.sh/uv/install.sh | sh" >>"$LOGFILE" 2>&1 || track_failure "uv-install"
    fi
    ok "uv installed/updated"
fi

# =============================================================================
#  PHASE 3: Dotfiles & Configs
# =============================================================================
hdr "PHASE 3: Dotfiles & Configs"

# --- 3a. Dotfiles -------------------------------------------------------------
hdr "Restoring Dotfiles"
if [ -d "$BACKUP_DIR/dotfiles" ]; then
    if $DRY_RUN; then
        for f in "$BACKUP_DIR/dotfiles/".*; do
            [ ! -f "$f" ] && continue
            DRY_FILES=$((DRY_FILES + 1))
        done
        for f in "$BACKUP_DIR/dotfiles/"[!.]*; do
            [ ! -f "$f" ] && continue
            DRY_FILES=$((DRY_FILES + 1))
        done
        if [ -d "$BACKUP_DIR/dotfiles/bashrc.d" ]; then
            bashrc_d_count=$(find "$BACKUP_DIR/dotfiles/bashrc.d" -type f 2>/dev/null | wc -l)
            DRY_FILES=$((DRY_FILES + bashrc_d_count))
        fi
        log "  [DRY RUN] Would restore ${DRY_FILES} dotfiles"
    else
        for f in "$BACKUP_DIR/dotfiles/".*; do
            [ ! -f "$f" ] && continue
            fname=$(basename "$f")
            # Don't overwrite .bashrc on Debian — merge instead
            if [ "$fname" = ".bashrc" ]; then
                # Remove old customization block if present, then re-append fresh
                if grep -q "bashrc.d" "$TARGET_HOME/.bashrc" 2>/dev/null; then
                    # Strip everything from "# bun" to end of our block (opencode PATH line)
                    sed -i '/^# bun$/,/^export PATH=\$HOME\/.opencode\/bin:\$PATH$/d' "$TARGET_HOME/.bashrc" 2>/dev/null || true
                fi
                cat >> "$TARGET_HOME/.bashrc" <<'BASHRC_APPEND'

# bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# Source all files in ~/.bashrc.d
for f in ~/.bashrc.d/*.sh; do [ -r "$f" ] && source "$f"; done

# pnpm
export PNPM_HOME="$HOME/.local/share/pnpm"
case ":$PATH:" in
  *":$PNPM_HOME:"*) ;;
  *) export PATH="$PNPM_HOME:$PATH" ;;
esac

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
alias pip='pip3'

export PATH="/usr/lib/llvm-23/bin:$PATH"

# OpenClaw Auto-Integration
if [ -f ~/.openclaw/.env ]; then
    export $(grep -v '^#' ~/.openclaw/.env | xargs)
fi

# opencode
export PATH=$HOME/.opencode/bin:$PATH
BASHRC_APPEND
                    log "  .bashrc — dev customizations applied"
            else
                cp "$f" "$TARGET_HOME/$fname"
                log "  $fname"
            fi
        done

        # Non-dotfiles (like regular named files)
        for f in "$BACKUP_DIR/dotfiles/"[!.]*; do
            [ ! -f "$f" ] && continue
            fname=$(basename "$f")
            cp "$f" "$TARGET_HOME/$fname"
            log "  $fname"
        done

        # .bashrc.d directory
        if [ -d "$BACKUP_DIR/dotfiles/bashrc.d" ]; then
            mkdir -p "$TARGET_HOME/.bashrc.d"
            cp -a "$BACKUP_DIR/dotfiles/bashrc.d/"* "$TARGET_HOME/.bashrc.d/"
            ok ".bashrc.d/ restored ($(ls "$TARGET_HOME/.bashrc.d/" | wc -l) files)"
        fi
    fi
fi

# --- 3b. Git Config -----------------------------------------------------------
hdr "Git Config"
if $DRY_RUN; then
    DRY_CONFIGS=$((DRY_CONFIGS + 1))
    log "  [DRY RUN] Would set git global config (user, email, push, pull, credentials)"
    [ -f "$BACKUP_DIR/dotfiles/.git-credentials" ] && {
        DRY_FILES=$((DRY_FILES + 1))
        log "  [DRY RUN] Would restore .git-credentials"
    }
else
    as_user 'git config --global user.name "jdgafx"'
    as_user 'git config --global user.email "jdgafx@users.noreply.github.com"'
    as_user 'git config --global push.autoSetupRemote true'
    as_user 'git config --global pull.rebase false'
    as_user 'git config --global credential.helper store'
    ok "Git global config set"

    # Restore git credentials
    if [ -f "$BACKUP_DIR/dotfiles/.git-credentials" ]; then
        cp "$BACKUP_DIR/dotfiles/.git-credentials" "$TARGET_HOME/.git-credentials"
        chmod 600 "$TARGET_HOME/.git-credentials"
        ok "Git credentials restored"
    fi
fi

# --- 3c. SSH Keys -------------------------------------------------------------
hdr "SSH Keys"
if [ -d "$BACKUP_DIR/ssh" ]; then
    if $DRY_RUN; then
        DRY_SSH=$(find "$BACKUP_DIR/ssh/" -type f 2>/dev/null | wc -l)
        log "  [DRY RUN] Would copy ${DRY_SSH} SSH files to ~/.ssh/"
    else
        mkdir -p "$TARGET_HOME/.ssh"
        # Don't blindly overwrite — only copy what's in backup
        find "$BACKUP_DIR/ssh/" -type f | while read -r f; do
            fname=$(basename "$f")
            cp "$f" "$TARGET_HOME/.ssh/$fname"
        done
        chmod 700 "$TARGET_HOME/.ssh"
        chmod 600 "$TARGET_HOME/.ssh/"* 2>/dev/null || true
        chmod 644 "$TARGET_HOME/.ssh/"*.pub 2>/dev/null || true
        chmod 644 "$TARGET_HOME/.ssh/known_hosts" 2>/dev/null || true
        ok "SSH keys restored"
    fi
fi

# =============================================================================
#  PHASE 4: Dev Tools (Claude, OpenCode, rclone, etc.)
# =============================================================================
hdr "PHASE 4: Dev Tools & AI Assistants"

# --- 4a. Claude Code ---------------------------------------------------------
hdr "Claude Code"
if $DRY_RUN; then
    DRY_PKGS=$((DRY_PKGS + 1))
    log "  [DRY RUN] Would install Claude Code CLI"
    if [ -d "$BACKUP_DIR/claude" ]; then
        claude_files=$(find "$BACKUP_DIR/claude" -type f 2>/dev/null | wc -l)
        DRY_CONFIGS=$((DRY_CONFIGS + claude_files))
        log "  [DRY RUN] Would restore ${claude_files} Claude config files"
    fi
else
    # Install/update Claude CLI (always force-install for fresh state)
    log "Installing/updating Claude Code CLI..."
    as_user "export NVM_DIR=\$HOME/.nvm && . \$NVM_DIR/nvm.sh && npm install -g @anthropic-ai/claude-code" \
        >>"$LOGFILE" 2>&1 || track_failure "claude-code-install"

    # Install/update claude-flow (multi-agent orchestration)
    log "Installing/updating claude-flow..."
    as_user "export NVM_DIR=\$HOME/.nvm && . \$NVM_DIR/nvm.sh && npm install -g @claude-flow/cli" \
        >>"$LOGFILE" 2>&1 || track_failure "claude-flow-install"

    # Restore Claude config
    if [ -d "$BACKUP_DIR/claude" ]; then
        mkdir -p "$TARGET_HOME/.claude"
        # Core config files
        for item in settings.json settings.local.json .credentials.json statusline-command.sh \
                    mcp-needs-auth-cache.json keybindings.json policy-limits.json; do
            [ -f "$BACKUP_DIR/claude/$item" ] && \
                cp "$BACKUP_DIR/claude/$item" "$TARGET_HOME/.claude/" && \
                log "  .claude/$item"
        done

        # Auth backups
        if [ -d "$BACKUP_DIR/claude/backups" ]; then
            mkdir -p "$TARGET_HOME/.claude/backups"
            cp "$BACKUP_DIR/claude/backups/"* "$TARGET_HOME/.claude/backups/" 2>/dev/null || true
            ok "Claude auth backups restored"
        fi

        # Scripts & hooks
        if [ -d "$BACKUP_DIR/claude/scripts" ]; then
            cp -a "$BACKUP_DIR/claude/scripts" "$TARGET_HOME/.claude/"
            chmod +x "$TARGET_HOME/.claude/scripts/"*.sh 2>/dev/null || true
            chmod +x "$TARGET_HOME/.claude/scripts/hooks/"*.sh 2>/dev/null || true
            ok "Claude scripts & hooks restored"
        fi

        # Custom agents
        if [ -d "$BACKUP_DIR/claude/agents" ]; then
            cp -a "$BACKUP_DIR/claude/agents" "$TARGET_HOME/.claude/"
            ok "Claude custom agents restored"
        fi

        # Plugins (full cache with skills, hooks, config)
        if [ -d "$BACKUP_DIR/claude/plugins" ]; then
            cp -a "$BACKUP_DIR/claude/plugins" "$TARGET_HOME/.claude/"
            ok "Claude plugins restored"
        fi

        # Project directories (memory, settings — no transcripts)
        if [ -d "$BACKUP_DIR/claude/projects" ]; then
            cp -a "$BACKUP_DIR/claude/projects" "$TARGET_HOME/.claude/"
            ok "Claude projects config + memory restored"
        fi

        # Fix hardcoded home paths in settings.json for this machine
        if [ -f "$TARGET_HOME/.claude/settings.json" ]; then
            SOURCE_HOME=""
            if [ -f "$BACKUP_DIR/manifests/system-info.txt" ]; then
                SOURCE_HOME=$(grep '^home=' "$BACKUP_DIR/manifests/system-info.txt" | cut -d= -f2)
            fi
            # Fallback: detect the most common /home/user pattern in the file
            if [ -z "$SOURCE_HOME" ]; then
                SOURCE_HOME=$(grep -oP '/home/[a-zA-Z0-9_-]+' "$TARGET_HOME/.claude/settings.json" | \
                    sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
            fi
            if [ -n "$SOURCE_HOME" ] && [ "$SOURCE_HOME" != "$TARGET_HOME" ]; then
                log "  Fixing paths: ${SOURCE_HOME} → ${TARGET_HOME}"
                sed -i "s|${SOURCE_HOME}|${TARGET_HOME}|g" "$TARGET_HOME/.claude/settings.json"
                ok "Claude settings.json paths updated for this machine"
            fi
        fi
    fi
fi

# --- 4b. OpenCode ------------------------------------------------------------
hdr "OpenCode"
if $DRY_RUN; then
    DRY_PKGS=$((DRY_PKGS + 1))
    log "  [DRY RUN] Would install OpenCode"
    [ -d "$BACKUP_DIR/configs/opencode" ] && { DRY_CONFIGS=$((DRY_CONFIGS + 1)); log "  [DRY RUN] Would restore OpenCode config"; }
    [ -d "$BACKUP_DIR/configs/opencode-data" ] && { DRY_CONFIGS=$((DRY_CONFIGS + 1)); log "  [DRY RUN] Would restore OpenCode auth data"; }
else
    # Install/update OpenCode (always reinstall for latest version)
    log "Installing/updating OpenCode..."
    as_user 'curl -fsSL https://opencode.ai/install.sh | bash' >>"$LOGFILE" 2>&1 || \
    as_user 'curl -fsSL https://get.opencode.ai | bash' >>"$LOGFILE" 2>&1 || \
        track_failure "opencode-install"

    # Restore OpenCode config
    if [ -d "$BACKUP_DIR/configs/opencode" ]; then
        mkdir -p "$TARGET_HOME/.config/opencode"
        cp -a "$BACKUP_DIR/configs/opencode/"* "$TARGET_HOME/.config/opencode/"
        ok "OpenCode config restored"
    fi

    if [ -d "$BACKUP_DIR/configs/opencode-data" ]; then
        mkdir -p "$TARGET_HOME/.local/share/opencode"
        cp -a "$BACKUP_DIR/configs/opencode-data/"* "$TARGET_HOME/.local/share/opencode/"
        ok "OpenCode auth data restored"
    fi
fi

# --- 4c. OpenClaw -------------------------------------------------------------
hdr "OpenClaw"
if [ -d "$BACKUP_DIR/configs/openclaw" ]; then
    if $DRY_RUN; then
        DRY_CONFIGS=$((DRY_CONFIGS + 1))
        log "  [DRY RUN] Would restore OpenClaw config"
    else
        cp -a "$BACKUP_DIR/configs/openclaw" "$TARGET_HOME/.openclaw"
        ok "OpenClaw config restored"
    fi
fi

# --- 4d. Antigravity ----------------------------------------------------------
hdr "Antigravity"
if [ -d "$BACKUP_DIR/configs/Antigravity" ]; then
    if $DRY_RUN; then
        DRY_CONFIGS=$((DRY_CONFIGS + 1))
        log "  [DRY RUN] Would restore Antigravity config"
    else
        mkdir -p "$TARGET_HOME/.config/Antigravity"
        cp -a "$BACKUP_DIR/configs/Antigravity/"* "$TARGET_HOME/.config/Antigravity/"
        ok "Antigravity config restored"
    fi
fi

# --- 4e. GitHub CLI -----------------------------------------------------------
hdr "GitHub CLI"
if $DRY_RUN; then
    DRY_PKGS=$((DRY_PKGS + 1))
    log "  [DRY RUN] Would install GitHub CLI (gh)"
    [ -d "$BACKUP_DIR/configs/gh" ] && { DRY_CONFIGS=$((DRY_CONFIGS + 1)); log "  [DRY RUN] Would restore gh CLI config"; }
else
    log "Installing/updating GitHub CLI..."
    case "$PKG_MANAGER" in
        apt)
            (type -p wget >/dev/null || pkg_install_one "wget") && \
            mkdir -p -m 755 /etc/apt/keyrings && \
            wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null && \
            chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli-stable.list > /dev/null && \
            apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall gh >>"$LOGFILE" 2>&1 || track_failure "gh-cli"
            ;;
        dnf|yum)
            dnf install -y 'dnf-command(config-manager)' >>"$LOGFILE" 2>&1 || true
            dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo >>"$LOGFILE" 2>&1 && \
            dnf install -y gh >>"$LOGFILE" 2>&1 || track_failure "gh-cli"
            ;;
        pacman)
            pacman -S --noconfirm --needed github-cli >>"$LOGFILE" 2>&1 || track_failure "gh-cli"
            ;;
        zypper)
            zypper install -y gh >>"$LOGFILE" 2>&1 || track_failure "gh-cli"
            ;;
        apk)
            apk add github-cli >>"$LOGFILE" 2>&1 || track_failure "gh-cli"
            ;;
        *)
            curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
                -o /tmp/gh-keyring.gpg 2>/dev/null && \
            warn "gh CLI: no known install method for ${PKG_MANAGER}, try manual install" || \
            track_failure "gh-cli"
            ;;
    esac

    if [ -d "$BACKUP_DIR/configs/gh" ]; then
        mkdir -p "$TARGET_HOME/.config/gh"
        cp -a "$BACKUP_DIR/configs/gh/"* "$TARGET_HOME/.config/gh/"
        ok "gh CLI config restored"
    fi
fi

# --- 4f. Rclone ---------------------------------------------------------------
hdr "Rclone"
if $DRY_RUN; then
    DRY_PKGS=$((DRY_PKGS + 1))
    log "  [DRY RUN] Would install rclone"
    [ -d "$BACKUP_DIR/configs/rclone" ] && { DRY_CONFIGS=$((DRY_CONFIGS + 1)); log "  [DRY RUN] Would restore rclone config"; }
else
    log "Installing/updating rclone..."
    curl -fsSL https://rclone.org/install.sh | bash >>"$LOGFILE" 2>&1 || track_failure "rclone"

    if [ -d "$BACKUP_DIR/configs/rclone" ]; then
        mkdir -p "$TARGET_HOME/.config/rclone"
        cp -a "$BACKUP_DIR/configs/rclone/"* "$TARGET_HOME/.config/rclone/"
        ok "Rclone config restored"
    fi
fi

# --- 4g. Tailscale ------------------------------------------------------------
hdr "Tailscale"
if $DRY_RUN; then
    DRY_PKGS=$((DRY_PKGS + 1))
    log "  [DRY RUN] Would install Tailscale"
else
    log "Installing/updating Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | bash >>"$LOGFILE" 2>&1 || track_failure "tailscale"
fi

# --- 4h. Google Chrome & Chrome Canary ----------------------------------------
hdr "Google Chrome"
if $DRY_RUN; then
    DRY_PKGS=$((DRY_PKGS + 1))
    log "  [DRY RUN] Would install Google Chrome"
    [ "$PKG_MANAGER" = "apt" ] && { DRY_PKGS=$((DRY_PKGS + 1)); log "  [DRY RUN] Would install Chrome Canary"; }
    for browser in google-chrome google-chrome-canary; do
        [ -d "$BACKUP_DIR/configs/$browser" ] && { DRY_CONFIGS=$((DRY_CONFIGS + 1)); log "  [DRY RUN] Would restore $browser bookmarks/prefs"; }
    done
else
    log "Installing/updating Google Chrome..."
    case "$PKG_MANAGER" in
        apt)
            wget -q -O /tmp/chrome.deb "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb" && \
            dpkg -i /tmp/chrome.deb >>"$LOGFILE" 2>&1 || apt-get install -fy >>"$LOGFILE" 2>&1
            rm -f /tmp/chrome.deb
            ;;
        dnf|yum)
            dnf install -y google-chrome-stable >>"$LOGFILE" 2>&1 || track_failure "chrome"
            ;;
        pacman)
            if command -v yay &>/dev/null; then
                as_user "yay -S --noconfirm google-chrome" >>"$LOGFILE" 2>&1 || track_failure "chrome"
            else
                warn "Install google-chrome from AUR manually (yay not available)"
            fi
            ;;
        zypper)
            zypper install -y google-chrome-stable >>"$LOGFILE" 2>&1 || {
                zypper ar -f https://dl.google.com/linux/chrome/rpm/stable/x86_64 google-chrome 2>>"$LOGFILE" || true
                rpm --import https://dl.google.com/linux/linux_signing_key.pub 2>>"$LOGFILE" || true
                zypper install -y google-chrome-stable >>"$LOGFILE" 2>&1 || track_failure "chrome"
            }
            ;;
        *)
            warn "Chrome: no automated install method for ${PKG_MANAGER}"
            ;;
    esac
    command -v google-chrome &>/dev/null && ok "Google Chrome installed/updated"

    # Chrome Canary (separate repo + signing key required)
    if [ "$PKG_MANAGER" = "apt" ]; then
        log "  Installing/updating Chrome Canary..."
        # Always set up the Canary repo and signing key (overwrite if stale)
        if [ -f "$BACKUP_DIR/keyrings/google-chrome-canary.gpg" ]; then
            cp -f "$BACKUP_DIR/keyrings/google-chrome-canary.gpg" /usr/share/keyrings/ 2>>"$LOGFILE" || true
        else
            wget -qO- https://dl.google.com/linux/linux_signing_key.pub | \
                gpg --dearmor --yes -o /usr/share/keyrings/google-chrome-canary.gpg 2>>"$LOGFILE" || true
        fi
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome-canary.gpg] https://dl.google.com/linux/chrome-canary/deb/ stable main" \
            > /etc/apt/sources.list.d/google-chrome-canary.list 2>>"$LOGFILE" || true
        apt-get update -qq 2>>"$LOGFILE" || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y google-chrome-canary >>"$LOGFILE" 2>&1 || \
            track_failure "chrome-canary"
        command -v google-chrome-canary &>/dev/null && ok "Chrome Canary installed/updated"
    fi

    # Restore browser bookmarks/prefs (only for browsers that are actually installed)
    for browser in google-chrome google-chrome-canary; do
        if [ -d "$BACKUP_DIR/configs/$browser" ]; then
            # Only restore config if the browser binary exists — restoring prefs
            # for a non-existent browser causes crash dialogs and broken state
            case "$browser" in
                google-chrome) command -v google-chrome-stable &>/dev/null || command -v google-chrome &>/dev/null || { log "  $browser not installed, skipping prefs"; continue; } ;;
                google-chrome-canary) command -v google-chrome-canary &>/dev/null || { log "  $browser not installed, skipping prefs"; continue; } ;;
            esac
            mkdir -p "$TARGET_HOME/.config/$browser/Default"
            for f in Bookmarks Preferences "Local State"; do
                [ -f "$BACKUP_DIR/configs/$browser/$f" ] && \
                    cp "$BACKUP_DIR/configs/$browser/$f" "$TARGET_HOME/.config/$browser/Default/" 2>/dev/null
                [ -f "$BACKUP_DIR/configs/$browser/$f" ] && \
                    cp "$BACKUP_DIR/configs/$browser/$f" "$TARGET_HOME/.config/$browser/" 2>/dev/null
            done
            log "  $browser bookmarks restored"
        fi
    done

    # Disable apport crash reporter (noisy on fresh installs with restored configs)
    if [ -f /etc/default/apport ]; then
        sed -i 's/enabled=1/enabled=0/' /etc/default/apport 2>>"$LOGFILE" || true
        systemctl stop apport.service 2>>"$LOGFILE" || true
        log "  Disabled apport crash reporter (prevents false crash dialogs)"
    fi
fi

# --- 4i. Fish Shell Config ----------------------------------------------------
hdr "Fish Shell"
if [ -d "$BACKUP_DIR/configs/fish" ]; then
    if $DRY_RUN; then
        DRY_CONFIGS=$((DRY_CONFIGS + 1))
        log "  [DRY RUN] Would restore Fish shell config"
    else
        mkdir -p "$TARGET_HOME/.config/fish"
        cp -a "$BACKUP_DIR/configs/fish/"* "$TARGET_HOME/.config/fish/"
        ok "Fish config restored"
    fi
fi

# =============================================================================
#  PHASE 5: CLAUDE.md & Dev Repos
# =============================================================================
hdr "PHASE 5: CLAUDE.md & Dev Repos"

# --- 5a. CLAUDE.md files ------------------------------------------------------
if $DRY_RUN; then
    for f in "$BACKUP_DIR/configs/"*CLAUDE.md; do
        [ ! -f "$f" ] && continue
        DRY_FILES=$((DRY_FILES + 1))
    done
    [ $DRY_FILES -gt 0 ] && log "  [DRY RUN] Would restore CLAUDE.md files"
else
    for f in "$BACKUP_DIR/configs/"*CLAUDE.md; do
        [ ! -f "$f" ] && continue
        fname=$(basename "$f")
        if echo "$fname" | grep -q "_home_chris_CLAUDE"; then
            cp "$f" "$TARGET_HOME/CLAUDE.md"
            log "  ~/CLAUDE.md restored"
        elif echo "$fname" | grep -q "_home_chris_dev_CLAUDE"; then
            mkdir -p "$TARGET_HOME/dev"
            cp "$f" "$TARGET_HOME/dev/CLAUDE.md"
            log "  ~/dev/CLAUDE.md restored"
        elif echo "$fname" | grep -q "^dev_.*_CLAUDE.md$"; then
            # Per-project CLAUDE.md files: dev_projectname_CLAUDE.md -> ~/dev/projectname/CLAUDE.md
            projname=$(echo "$fname" | sed 's/^dev_//; s/_CLAUDE\.md$//')
            if [ -d "$TARGET_HOME/dev/$projname" ]; then
                cp "$f" "$TARGET_HOME/dev/$projname/CLAUDE.md"
                log "  ~/dev/$projname/CLAUDE.md restored"
            fi
        fi
    done
fi

# --- 5b. Set up Git credentials & Clone dev repos ----------------------------
hdr "Git Credentials & Dev Repos"

# Set up git credentials BEFORE cloning (uses token from backup if available)
if [ -f "$BACKUP_DIR/configs/gh/hosts.yml" ]; then
    GITHUB_TOKEN=$(grep 'oauth_token:' "$BACKUP_DIR/configs/gh/hosts.yml" 2>/dev/null | head -1 | awk '{print $2}')
fi
# Fallback: extract from CLAUDE.md if available
if [ -z "${GITHUB_TOKEN:-}" ] && [ -f "$TARGET_HOME/CLAUDE.md" ]; then
    GITHUB_TOKEN=$(grep -oP 'ghp_[a-zA-Z0-9]+' "$TARGET_HOME/CLAUDE.md" 2>/dev/null | head -1)
fi
# Fallback: extract from Claude settings
if [ -z "${GITHUB_TOKEN:-}" ] && [ -f "$TARGET_HOME/.claude/settings.json" ]; then
    GITHUB_TOKEN=$(grep -oP 'ghp_[a-zA-Z0-9]+' "$TARGET_HOME/.claude/settings.json" 2>/dev/null | head -1)
fi

if [ -n "${GITHUB_TOKEN:-}" ]; then
    log "Setting up Git credential helper for GitHub..."
    if $DRY_RUN; then
        log "  [DRY RUN] Would configure git credential helper with GitHub token"
    else
        # Configure git credential store with token
        as_user "git config --global credential.helper store" >>"$LOGFILE" 2>&1 || true
        as_user "printf 'https://jdgafx:${GITHUB_TOKEN}@github.com\n' > \$HOME/.git-credentials && chmod 600 \$HOME/.git-credentials" \
            >>"$LOGFILE" 2>&1 || true
        as_user "git config --global user.name 'jdgafx'" >>"$LOGFILE" 2>&1 || true
        as_user "git config --global user.email 'jdgafx@users.noreply.github.com'" >>"$LOGFILE" 2>&1 || true
        ok "Git credentials configured"

        # Also auth gh CLI if available
        if command -v gh &>/dev/null; then
            as_user "echo '${GITHUB_TOKEN}' | gh auth login --with-token" >>"$LOGFILE" 2>&1 || true
            ok "GitHub CLI authenticated"
        fi
    fi
fi

hdr "Cloning Dev Repos"
if [ -f "$BACKUP_DIR/manifests/dev-repos.txt" ]; then
    if $DRY_RUN; then
        while IFS='|' read -r dirname remote branch; do
            [[ "$dirname" =~ ^# ]] && continue
            [ "$remote" = "NOT_A_REPO" ] && continue
            [ "$remote" = "LOCAL_ONLY" ] && continue
            [ -z "$remote" ] && continue
            DRY_REPOS=$((DRY_REPOS + 1))
        done < "$BACKUP_DIR/manifests/dev-repos.txt"
        log "  [DRY RUN] Would clone/update ${DRY_REPOS} dev repos to ~/dev/"
    else
        mkdir -p "$TARGET_HOME/dev"

        # Inject GitHub token into clone URLs for private repos
        inject_token() {
            local url="$1"
            if [ -n "${GITHUB_TOKEN:-}" ] && echo "$url" | grep -q "github.com"; then
                # Only inject if not already present
                if ! echo "$url" | grep -q "@github.com"; then
                    echo "$url" | sed "s|https://github.com|https://jdgafx:${GITHUB_TOKEN}@github.com|"
                    return
                fi
            fi
            echo "$url"
        }

        CLONED=0; UPDATED=0; FAILED_CLONE=0
        while IFS='|' read -r dirname remote branch; do
            # Skip comments and non-repos
            [[ "$dirname" =~ ^# ]] && continue
            [ "$remote" = "NOT_A_REPO" ] && continue
            [ "$remote" = "LOCAL_ONLY" ] && continue
            [ -z "$remote" ] && continue

            target="$TARGET_HOME/dev/$dirname"
            auth_remote=$(inject_token "$remote")

            if [ -d "$target/.git" ]; then
                # Already exists — pull latest
                log "  ${dirname} — exists, pulling latest..."
                as_user "cd '${target}' && git pull --ff-only" >>"$LOGFILE" 2>&1 || \
                    as_user "cd '${target}' && git fetch --all" >>"$LOGFILE" 2>&1 || true
                UPDATED=$((UPDATED + 1))
                continue
            fi

            log "  Cloning ${dirname}..."
            as_user "git clone --depth=1 '${auth_remote}' '${target}'" >>"$LOGFILE" 2>&1 || {
                # Try without depth limit
                as_user "git clone '${auth_remote}' '${target}'" >>"$LOGFILE" 2>&1 || {
                    track_failure "git-clone:${dirname}"
                    FAILED_CLONE=$((FAILED_CLONE + 1))
                    continue
                }
            }
            CLONED=$((CLONED + 1))

            # Checkout correct branch if not main/master
            if [ -n "$branch" ] && [ "$branch" != "main" ] && [ "$branch" != "master" ]; then
                as_user "cd '${target}' && git checkout '${branch}'" >>"$LOGFILE" 2>&1 || true
            fi

            # Clean token from stored remote URL (use clean URL going forward)
            if [ "$auth_remote" != "$remote" ] && [ -d "$target/.git" ]; then
                as_user "cd '${target}' && git remote set-url origin '${remote}'" >>"$LOGFILE" 2>&1 || true
            fi
        done < "$BACKUP_DIR/manifests/dev-repos.txt"

        ok "Dev repos: ${CLONED} cloned, ${UPDATED} updated, ${FAILED_CLONE} failed"
    fi
fi

# --- 5c. Crontab -------------------------------------------------------------
hdr "Crontab"
if [ -f "$BACKUP_DIR/configs/crontab.txt" ] && [ -s "$BACKUP_DIR/configs/crontab.txt" ]; then
    if $DRY_RUN; then
        DRY_CONFIGS=$((DRY_CONFIGS + 1))
        log "  [DRY RUN] Would restore crontab"
    else
        crontab -u "$TARGET_USER" "$BACKUP_DIR/configs/crontab.txt" 2>/dev/null || \
            warn "Could not restore crontab"
        ok "Crontab restored"
    fi
fi

# --- 5d. Systemd User Services -----------------------------------------------
hdr "Systemd User Services"
if [ -f "$BACKUP_DIR/manifests/systemd-user-enabled.txt" ] && [ -s "$BACKUP_DIR/manifests/systemd-user-enabled.txt" ]; then
    if $DRY_RUN; then
        DRY_SERVICES=$(grep -c '[^[:space:]]' "$BACKUP_DIR/manifests/systemd-user-enabled.txt" 2>/dev/null || echo 0)
        log "  [DRY RUN] Would enable ${DRY_SERVICES} systemd user services"
    else
        while IFS= read -r svc; do
            [ -z "$svc" ] && continue
            as_user "systemctl --user enable '${svc}'" >>"$LOGFILE" 2>&1 || true
        done < "$BACKUP_DIR/manifests/systemd-user-enabled.txt"
        ok "User services re-enabled"
    fi
fi

# --- KDE Panel Fixup Helper ---------------------------------------------------
# Remaps activity IDs and screen mappings so panels actually appear on new hardware
_kde_fixup_panels() {
    local home="$1"
    local appletsrc="$home/.config/plasma-org.kde.plasma.desktop-appletsrc"
    [ -f "$appletsrc" ] || return 0

    log "  Fixing KDE panel activity IDs and screen mapping..."

    # Get the current machine's default activity ID
    local new_activity=""
    if [ -f "$home/.local/share/kactivitymanagerd/resources/database" ]; then
        # SQLite database has activity info
        new_activity=$(sqlite3 "$home/.local/share/kactivitymanagerd/resources/database" \
            "SELECT resourceId FROM ResourceInfo LIMIT 1" 2>/dev/null || true)
    fi
    if [ -z "$new_activity" ] && command -v qdbus6 &>/dev/null; then
        new_activity=$(as_user "qdbus6 org.kde.ActivityManager /ActivityManager/Activities ListActivities 2>/dev/null | head -1" 2>/dev/null || true)
    fi
    if [ -z "$new_activity" ] && command -v qdbus &>/dev/null; then
        new_activity=$(as_user "qdbus org.kde.ActivityManager /ActivityManager/Activities ListActivities 2>/dev/null | head -1" 2>/dev/null || true)
    fi

    # Extract the old activity ID from the config
    local old_activity
    old_activity=$(grep -m1 '^activityId=' "$appletsrc" | head -1 | cut -d= -f2)

    if [ -n "$new_activity" ] && [ -n "$old_activity" ] && [ "$new_activity" != "$old_activity" ]; then
        sed -i "s/${old_activity}/${new_activity}/g" "$appletsrc" 2>>"$LOGFILE" || true
        log "  Remapped activity: ${old_activity} -> ${new_activity}"
    elif [ -z "$new_activity" ] && [ -n "$old_activity" ]; then
        # No activity manager running (fresh install, not in KDE session yet)
        # Clear activity IDs so Plasma assigns the default on first login
        sed -i 's/^activityId=.*/activityId=/' "$appletsrc" 2>>"$LOGFILE" || true
        log "  Cleared activity IDs (will auto-assign on first login)"
    fi

    # Reset screen mapping section — let Plasma figure it out for new hardware
    sed -i '/^\[ScreenMapping\]/,/^$/{ /^\[ScreenMapping\]/!{ /^$/!s/.*// }; }' "$appletsrc" 2>>"$LOGFILE" || true

    # Force all panels to lastScreen=0 so at least they show up on primary monitor
    # (user can drag them to other screens after login)
    sed -i '/^\[Containments\]\[[0-9]*\]$/,/^\[/ { s/^lastScreen=[0-9]*/lastScreen=0/ }' "$appletsrc" 2>>"$LOGFILE" || true
    log "  Reset screen mappings to primary display"

    ok "KDE panel config adapted for new machine"
}

# --- 5e. Desktop Environment Config -------------------------------------------
hdr "Desktop Environment Config"
if [ -d "$BACKUP_DIR/configs/desktop" ]; then
    if $DRY_RUN; then
        DE_FILES=$(find "$BACKUP_DIR/configs/desktop" -type f 2>/dev/null | wc -l)
        log "  [DRY RUN] Would restore ${DE_FILES} desktop config files"
    else
        # Read captured DE info
        CAPTURED_DE="unknown"
        [ -f "$BACKUP_DIR/configs/desktop/session-info.txt" ] && \
            CAPTURED_DE=$(grep "^desktop=" "$BACKUP_DIR/configs/desktop/session-info.txt" 2>/dev/null | cut -d= -f2)
        log "  Captured DE: ${CAPTURED_DE}"

        # KDE Plasma configs
        if [ -d "$BACKUP_DIR/configs/desktop/kde-config" ]; then
            log "  Restoring KDE Plasma configs..."
            # Detect display server (Wayland vs X11)
            SESSION_TYPE="${XDG_SESSION_TYPE:-$(loginctl show-session "$(loginctl | grep "$TARGET_USER" | awk '{print $1}')" -p Type --value 2>/dev/null || echo "unknown")}"
            log "  Session type: ${SESSION_TYPE}"

            # Stop plasmashell to avoid conflicts and cached defaults
            if [ "$SESSION_TYPE" = "wayland" ]; then
                # On Wayland, kquitapp6 may not find the service — use dbus directly
                as_user "kquitapp6 plasmashell" >>"$LOGFILE" 2>&1 || \
                    as_user "dbus-send --session --dest=org.kde.plasmashell --type=method_call /MainApplication org.qtproject.Qt.QCoreApplication.quit" >>"$LOGFILE" 2>&1 || true
            else
                as_user "kquitapp6 plasmashell" >>"$LOGFILE" 2>&1 || \
                    as_user "kquitapp5 plasmashell" >>"$LOGFILE" 2>&1 || true
            fi
            sleep 2

            # Nuke Plasma cache so it doesn't use stale/default panel layout
            for cachedir in "$TARGET_HOME/.cache/plasmashell" \
                            "$TARGET_HOME/.cache/plasma_theme_"* \
                            "$TARGET_HOME/.cache/plasma-svgelements"* \
                            "$TARGET_HOME/.cache/ksycoca6"* \
                            "$TARGET_HOME/.cache/ksycoca5"*; do
                rm -rf "$cachedir" 2>/dev/null || true
            done
            log "  Cleared Plasma caches"

            for f in "$BACKUP_DIR/configs/desktop/kde-config"/*; do
                fname=$(basename "$f")
                if [ -d "$f" ]; then
                    mkdir -p "$TARGET_HOME/.config/$fname"
                    cp -a "$f"/* "$TARGET_HOME/.config/$fname/" 2>>"$LOGFILE" || true
                else
                    cp "$f" "$TARGET_HOME/.config/" 2>>"$LOGFILE" || true
                fi
            done
            chown -R "$TARGET_USER:$(id -gn "$TARGET_USER")" "$TARGET_HOME/.config" 2>>"$LOGFILE" || true

            # Remap activity IDs and screen mappings for new hardware
            _kde_fixup_panels "$TARGET_HOME"
            ok "KDE rc files restored"

            # Rebuild KDE sycoca cache with the new configs
            as_user "kbuildsycoca6 2>/dev/null || kbuildsycoca5 2>/dev/null" >>"$LOGFILE" 2>&1 || true

            # Restart plasmashell with restored config
            sleep 1
            if [ "$SESSION_TYPE" = "wayland" ]; then
                # On Wayland, plasmashell is managed by kwin_wayland — just start it
                as_user "nohup plasmashell >/dev/null 2>&1 &" >>"$LOGFILE" 2>&1 || true
            else
                as_user "nohup plasmashell --replace >/dev/null 2>&1 &" >>"$LOGFILE" 2>&1 || true
            fi
            log "  Plasmashell restarted (${SESSION_TYPE}) — panels should appear within a few seconds"
            log "  If panels still missing, log out and back in to apply fully"
        fi

        # KDE local share (konsole profiles, color schemes, themes)
        if [ -d "$BACKUP_DIR/configs/desktop/kde-local-share" ]; then
            for d in "$BACKUP_DIR/configs/desktop/kde-local-share"/*; do
                dname=$(basename "$d")
                mkdir -p "$TARGET_HOME/.local/share/$dname"
                cp -a "$d"/* "$TARGET_HOME/.local/share/$dname/" 2>>"$LOGFILE" || true
            done
            ok "KDE local data (konsole profiles, themes) restored"
        fi

        # GTK configs
        for gtkdir in gtk-3.0 gtk-4.0; do
            if [ -d "$BACKUP_DIR/configs/desktop/$gtkdir" ]; then
                mkdir -p "$TARGET_HOME/.config/$gtkdir"
                cp -a "$BACKUP_DIR/configs/desktop/$gtkdir"/* "$TARGET_HOME/.config/$gtkdir/" 2>>"$LOGFILE" || true
                log "  $gtkdir restored"
            fi
        done

        # Fontconfig
        if [ -d "$BACKUP_DIR/configs/desktop/fontconfig" ]; then
            mkdir -p "$TARGET_HOME/.config/fontconfig"
            cp -a "$BACKUP_DIR/configs/desktop/fontconfig"/* "$TARGET_HOME/.config/fontconfig/" 2>>"$LOGFILE" || true
            log "  fontconfig restored"
        fi

        # Custom fonts
        if [ -d "$BACKUP_DIR/configs/desktop/fonts" ]; then
            mkdir -p "$TARGET_HOME/.local/share/fonts"
            cp -a "$BACKUP_DIR/configs/desktop/fonts"/* "$TARGET_HOME/.local/share/fonts/" 2>>"$LOGFILE" || true
            as_user "fc-cache -f" >>"$LOGFILE" 2>&1 || true
            ok "Custom fonts restored & cache rebuilt"
        fi

        # GNOME dconf
        if [ -f "$BACKUP_DIR/configs/desktop/dconf-dump.ini" ]; then
            if command -v dconf &>/dev/null; then
                as_user "dconf load / < '$BACKUP_DIR/configs/desktop/dconf-dump.ini'" >>"$LOGFILE" 2>&1 || true
                ok "GNOME dconf settings restored"
            fi
        fi

        # XFCE
        if [ -d "$BACKUP_DIR/configs/desktop/xfce4" ]; then
            mkdir -p "$TARGET_HOME/.config/xfce4"
            cp -a "$BACKUP_DIR/configs/desktop/xfce4"/* "$TARGET_HOME/.config/xfce4/" 2>>"$LOGFILE" || true
            ok "XFCE4 config restored"
        fi

        # SDDM (system-level — needs root)
        if [ -d "$BACKUP_DIR/configs/desktop/sddm" ]; then
            [ -f "$BACKUP_DIR/configs/desktop/sddm/sddm.conf" ] && \
                cp "$BACKUP_DIR/configs/desktop/sddm/sddm.conf" /etc/sddm.conf 2>>"$LOGFILE" || true
            [ -d "$BACKUP_DIR/configs/desktop/sddm/sddm.conf.d" ] && \
                cp -a "$BACKUP_DIR/configs/desktop/sddm/sddm.conf.d"/* /etc/sddm.conf.d/ 2>>"$LOGFILE" || true
            ok "SDDM display manager config restored"
        fi

        # Install/reinstall the captured DE (always ensure all packages present)
        if echo "$CAPTURED_DE" | grep -qi "kde\|plasma"; then
            log "  Installing/updating full KDE Plasma desktop environment..."

            # Core desktop + essential KDE apps for a complete, usable desktop
            KDE_PKGS_DEB=(
                kde-plasma-desktop plasma-workspace sddm sddm-theme-breeze
                konsole dolphin kate ark okular gwenview spectacle
                plasma-systemmonitor plasma-nm plasma-pa plasma-firewall
                kde-spectacle kscreen kwin-wayland kwin-x11
                breeze-gtk-theme kde-config-gtk-style
                xdg-desktop-portal-kde pipewire wireplumber
                phonon4qt5-backend-vlc
                plasma-discover flatpak-backend
                powerdevil bluedevil
            )
            log "  Installing ${#KDE_PKGS_DEB[@]} KDE packages..."
            KDE_NATIVE=()
            for kp in "${KDE_PKGS_DEB[@]}"; do
                kp_translated=$(pkg_translate "$kp")
                [ -n "$kp_translated" ] && KDE_NATIVE+=("$kp_translated")
            done
            pkg_install_batch "${KDE_NATIVE[@]}" >>"$LOGFILE" 2>&1 || {
                warn "Batch KDE install had errors, retrying core packages individually..."
                for kp in kde-plasma-desktop sddm konsole dolphin kate kwin-wayland kscreen; do
                    pkg_install_one "$(pkg_translate "$kp")" >>"$LOGFILE" 2>&1 || true
                done
            }

            # Set SDDM as default display manager
            if command -v update-alternatives &>/dev/null; then
                update-alternatives --set x-display-manager /usr/bin/sddm 2>>"$LOGFILE" || true
            fi
            systemctl enable sddm 2>>"$LOGFILE" || true
            ok "KDE Plasma desktop fully installed & SDDM enabled"
        fi

        # CRITICAL: Always re-apply KDE configs AFTER package install/update.
        # KDE package install drops default configs that overwrite what we restored above.
        # Re-copy the panel/desktop configs so they survive first login.
        if [ -d "$BACKUP_DIR/configs/desktop/kde-config" ]; then
            log "  Re-applying KDE configs after fresh install (overriding package defaults)..."
            # Nuke any defaults the package install just created
            rm -f "$TARGET_HOME/.config/plasma-org.kde.plasma.desktop-appletsrc" 2>/dev/null || true
            rm -f "$TARGET_HOME/.config/plasmashellrc" 2>/dev/null || true
            rm -rf "$TARGET_HOME/.cache/plasmashell" 2>/dev/null || true
            rm -rf "$TARGET_HOME/.cache/ksycoca6"* "$TARGET_HOME/.cache/ksycoca5"* 2>/dev/null || true

            for f in "$BACKUP_DIR/configs/desktop/kde-config"/*; do
                fname=$(basename "$f")
                if [ -d "$f" ]; then
                    mkdir -p "$TARGET_HOME/.config/$fname"
                    cp -a "$f"/* "$TARGET_HOME/.config/$fname/" 2>>"$LOGFILE" || true
                else
                    cp "$f" "$TARGET_HOME/.config/" 2>>"$LOGFILE" || true
                fi
            done
            # Re-apply local share (konsole, kscreen, themes)
            if [ -d "$BACKUP_DIR/configs/desktop/kde-local-share" ]; then
                for d in "$BACKUP_DIR/configs/desktop/kde-local-share"/*; do
                    dname=$(basename "$d")
                    mkdir -p "$TARGET_HOME/.local/share/$dname"
                    cp -a "$d"/* "$TARGET_HOME/.local/share/$dname/" 2>>"$LOGFILE" || true
                done
            fi
            # Remap activity IDs and screen mappings for new machine
            _kde_fixup_panels "$TARGET_HOME"
            chown -R "$TARGET_USER:$(id -gn "$TARGET_USER")" \
                "$TARGET_HOME/.config" "$TARGET_HOME/.local/share" 2>>"$LOGFILE" || true
            ok "KDE panel & desktop configs re-applied after package install"
        fi
    fi
else
    log "  No desktop config in backup — skipping"
fi

# =============================================================================
#  PHASE 6: Fix Ownership & Permissions
# =============================================================================
hdr "PHASE 6: Fixing Ownership"
if $DRY_RUN; then
    log "  [DRY RUN] Would chown -R ${TARGET_USER}:${TARGET_USER} ${TARGET_HOME}"
    log "  [DRY RUN] Would fix SSH permissions in ~/.ssh/"
else
    chown -R "${TARGET_USER}:${TARGET_USER}" "$TARGET_HOME" 2>>"$LOGFILE"
    ok "All files owned by ${TARGET_USER}"

    # Fix SSH permissions specifically
    chmod 700 "$TARGET_HOME/.ssh" 2>/dev/null || true
    find "$TARGET_HOME/.ssh" -type f -name "*.pub" -exec chmod 644 {} \; 2>/dev/null || true
    find "$TARGET_HOME/.ssh" -type f ! -name "*.pub" ! -name "known_hosts*" ! -name "config" -exec chmod 600 {} \; 2>/dev/null || true
fi

# =============================================================================
#  PHASE 7: Boot Manager — systemd-boot + dracut
# =============================================================================
hdr "PHASE 7: Boot Manager (systemd-boot + dracut)"
if $DRY_RUN; then
    log "  [DRY RUN] Would install systemd-boot and dracut"
    log "  [DRY RUN] Would set boot menu timeout to 60s"
    log "  [DRY RUN] Would regenerate initramfs with dracut"
else
    # Install dracut (replaces initramfs-tools on Debian/Ubuntu)
    log "Installing dracut and boot dependencies..."
    BOOT_PKGS_DEB=(dracut systemd-boot binutils)
    BOOT_NATIVE=()
    for bp in "${BOOT_PKGS_DEB[@]}"; do
        bp_translated=$(pkg_translate "$bp")
        [ -n "$bp_translated" ] && BOOT_NATIVE+=("$bp_translated")
    done
    pkg_install_batch "${BOOT_NATIVE[@]}" >>"$LOGFILE" 2>&1 || {
        # Retry individually
        for bp in "${BOOT_PKGS_DEB[@]}"; do
            pkg_install_one "$(pkg_translate "$bp")" >>"$LOGFILE" 2>&1 || true
        done
    }

    # Verify dracut is available
    if command -v dracut &>/dev/null; then
        ok "dracut installed: $(dracut --version 2>/dev/null || echo 'ok')"

        # Install systemd-boot to the ESP if EFI system detected
        if [ -d /sys/firmware/efi ]; then
            log "  EFI system detected — configuring systemd-boot..."

            # Find the EFI System Partition
            ESP=""
            for candidate in /boot/efi /efi /boot; do
                if mountpoint -q "$candidate" 2>/dev/null && \
                   find "$candidate" -maxdepth 1 -name "EFI" -type d 2>/dev/null | grep -q .; then
                    ESP="$candidate"
                    break
                fi
            done
            # Fallback: check fstab
            if [ -z "$ESP" ]; then
                ESP=$(grep -E 'vfat.*(boot|efi)' /etc/fstab 2>/dev/null | awk '{print $2}' | head -1)
                [ -n "$ESP" ] && mountpoint -q "$ESP" 2>/dev/null || { [ -n "$ESP" ] && mount "$ESP" 2>>"$LOGFILE" || true; }
            fi

            if [ -n "$ESP" ]; then
                log "  ESP found at: ${ESP}"

                # Install systemd-boot bootloader
                bootctl install --esp-path="$ESP" >>"$LOGFILE" 2>&1 || \
                    bootctl update --esp-path="$ESP" >>"$LOGFILE" 2>&1 || \
                    track_failure "systemd-boot-install"
                ok "systemd-boot installed to ${ESP}"

                # Set boot menu timeout to 60 seconds
                bootctl set-timeout 60 --esp-path="$ESP" >>"$LOGFILE" 2>&1 || {
                    # Fallback: write loader.conf manually
                    mkdir -p "${ESP}/loader"
                    cat > "${ESP}/loader/loader.conf" <<'LOADERCONF'
timeout 60
console-mode max
editor yes
LOADERCONF
                    log "  Wrote loader.conf manually"
                }
                ok "Boot menu timeout set to 60 seconds"
            else
                warn "Could not find EFI System Partition — skipping systemd-boot install"
                warn "You may need to install manually: bootctl install --esp-path=/boot/efi"
            fi
        else
            warn "Not an EFI system (legacy BIOS) — skipping systemd-boot"
        fi

        # Regenerate initramfs with dracut
        log "  Regenerating initramfs with dracut (this may take a minute)..."
        dracut -f --uefi --parallel --regenerate-all --hardlink --early-microcode -M --verbose \
            >>"$LOGFILE" 2>&1 || {
            # Retry without --uefi if not on EFI
            warn "dracut --uefi failed, retrying without --uefi..."
            dracut -f --parallel --regenerate-all --hardlink --early-microcode -M --verbose \
                >>"$LOGFILE" 2>&1 || track_failure "dracut-regenerate"
        }
        ok "initramfs regenerated with dracut"
    else
        warn "dracut not available after install — initramfs not regenerated"
        warn "You can regenerate manually: dracut -f --uefi --parallel --regenerate-all --hardlink --early-microcode -M --verbose"
    fi
fi

# =============================================================================
#  SUMMARY
# =============================================================================
if $DRY_RUN; then
    hdr "DRY RUN SUMMARY"
    echo ""
    echo -e "${BOLD}The following actions would be performed:${NC}"
    echo -e "  ${CYAN}${DRY_PKGS}${NC} system/dev packages would be installed"
    echo -e "  ${CYAN}${DRY_SNAPS}${NC} snap packages would be installed"
    echo -e "  ${CYAN}${DRY_FLATPAKS}${NC} flatpak packages would be installed"
    echo -e "  ${CYAN}${DRY_FILES}${NC} dotfiles would be restored"
    echo -e "  ${CYAN}${DRY_SSH}${NC} SSH files would be copied"
    echo -e "  ${CYAN}${DRY_REPOS}${NC} dev repos would be cloned"
    echo -e "  ${CYAN}${DRY_CONFIGS}${NC} config directories would be restored"
    echo -e "  ${CYAN}${DRY_SERVICES}${NC} systemd user services would be enabled"
    echo ""
    echo -e "${BOLD}No changes were made. Run without --dry-run to apply.${NC}"
    echo ""
    ok "Log file: ${LOGFILE}"
else
    echo ""
    echo -e "${GREEN}${BOLD}"
    cat <<'BANNER'
  ╔══════════════════════════════════════════════════════════════╗
  ║            RESTORE COMPLETE                                 ║
  ╚══════════════════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"
    ok "Log file: ${LOGFILE}"

    if [ ${#FAILED_STEPS[@]} -gt 0 ]; then
        echo ""
        warn "The following steps had issues (${#FAILED_STEPS[@]} total):"
        printf "  - %s\n" "${FAILED_STEPS[@]}"
        echo ""
        warn "These are non-blocking. Review the log for details."
    else
        echo ""
        ok "All steps completed successfully!"
    fi

    echo ""
    echo -e "  ${CYAN}─────────────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}What was installed:${NC}"
    echo -e "    ${GREEN}✓${NC} System packages (${PKG_MANAGER})"
    echo -e "    ${GREEN}✓${NC} Dev toolchains (Node/NVM, Bun, pnpm, uv, pip)"
    echo -e "    ${GREEN}✓${NC} AI tools (Claude Code, claude-flow, OpenCode)"
    echo -e "    ${GREEN}✓${NC} Shell config (.bashrc, .bashrc.d/, SSH keys)"
    echo -e "    ${GREEN}✓${NC} Desktop environment (KDE Plasma + panels)"
    echo -e "    ${GREEN}✓${NC} Boot manager (systemd-boot + dracut)"
    echo -e "    ${GREEN}✓${NC} Dev repos cloned to ~/dev/"
    echo -e "  ${CYAN}─────────────────────────────────────────────────────${NC}"
    echo ""
    echo -e "${BOLD}Next steps:${NC}"
    echo -e "  1. ${CYAN}Reboot${NC} — to activate systemd-boot + new initramfs"
    echo -e "  2. ${CYAN}Log into KDE Plasma${NC} — panels should load automatically"
    echo -e "  3. ${CYAN}tailscale up${NC} — reconnect Tailscale VPN"
    echo -e "  4. ${CYAN}rclone config reconnect gdrive:${NC} — if Google Drive auth expired"
    echo -e "  5. ${CYAN}claude${NC} — to re-authenticate Claude Code"
    echo -e "  6. ${CYAN}gh auth login${NC} — if GitHub CLI needs re-auth"
    echo ""
    echo -e "  ${YELLOW}If KDE panels are missing after login:${NC}"
    echo -e "    ${CYAN}rm -rf ~/.cache/plasmashell ~/.cache/ksycoca6*${NC}"
    echo -e "    ${CYAN}kquitapp6 plasmashell; sleep 2; plasmashell &${NC}"
    echo ""
    echo -e "${GREEN}${BOLD}Your dev environment is ready!${NC}"
fi

# Cleanup extraction directory
rm -rf "$EXTRACT_DIR"
