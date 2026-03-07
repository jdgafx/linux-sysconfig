#!/usr/bin/env bash
###############################################################################
# capture.sh — Snapshot the entire dev environment for transfer
#
# Universal Linux support: APT, DNF/YUM, Pacman, Zypper, APK, XBPS
#
# Captures: system packages + repos + keyrings, snap packages, flatpak,
#           pip packages, npm globals, NVM, Bun, dotfiles, SSH keys,
#           Claude Code config, OpenCode config, rclone config, git config,
#           dev repo manifest, systemd user services, crontab, CLAUDE.md,
#           and more.
#
# Output:   A single compressed tarball uploaded to Google Drive via rclone.
# Usage:    bash capture.sh            (interactive — prompts for sudo)
#           bash capture.sh --yes      (auto-confirm everything)
#           bash capture.sh --encrypt  (encrypt with age/gpg passphrase)
#           BACKUP_PASSPHRASE=secret bash capture.sh --encrypt --yes
###############################################################################
set -euo pipefail
IFS=$'\n\t'

# --- Configuration -----------------------------------------------------------
BACKUP_NAME="linux-sysconfig-$(hostname)-$(date +%Y%m%d-%H%M%S)"
STAGING_DIR="${HOME}/.cache/sysconfig-capture/${BACKUP_NAME}"
TARBALL="${HOME}/.cache/sysconfig-capture/${BACKUP_NAME}.tar.zst"
GDRIVE_DEST="gdrive:Linux-Sysconfig-Backups"
AUTOYES=""
ENCRYPT=false
for arg in "$@"; do
    case "$arg" in
        --yes) AUTOYES="--yes" ;;
        --encrypt) ENCRYPT=true ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*"; }
hdr()  { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}"; }

die() { err "$*"; exit 1; }

# Sudo helper — uses SUDO_PASSWORD env var if set, otherwise prompts
do_sudo() {
    if [ -n "${SUDO_PASSWORD:-}" ]; then
        echo "$SUDO_PASSWORD" | sudo -S "$@" 2>/dev/null
    else
        sudo "$@"
    fi
}

confirm() {
    [[ "$AUTOYES" == "--yes" ]] && return 0
    read -rp "$(echo -e "${YELLOW}[?]${NC} $* [Y/n] ")" ans
    [[ -z "$ans" || "$ans" =~ ^[Yy] ]]
}

# --- Pre-flight checks -------------------------------------------------------
command -v tar  >/dev/null || die "tar is required"
if ! command -v zstd >/dev/null; then
    warn "zstd not found, installing..."
    if command -v apt-get &>/dev/null; then
        do_sudo apt-get install -y zstd
    elif command -v dnf &>/dev/null; then
        do_sudo dnf install -y zstd
    elif command -v yum &>/dev/null; then
        do_sudo yum install -y zstd
    elif command -v pacman &>/dev/null; then
        do_sudo pacman -S --noconfirm zstd
    elif command -v zypper &>/dev/null; then
        do_sudo zypper install -y zstd
    elif command -v apk &>/dev/null; then
        do_sudo apk add zstd
    elif command -v xbps-install &>/dev/null; then
        do_sudo xbps-install -y zstd
    else
        die "zstd is required but no known package manager found to install it"
    fi
fi

# --- Package Manager Detection -----------------------------------------------
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
    elif command -v xbps-query &>/dev/null; then
        PKG_MANAGER="xbps"
    elif command -v emerge &>/dev/null; then
        PKG_MANAGER="portage"
    elif command -v nix-env &>/dev/null; then
        PKG_MANAGER="nix"
    else
        PKG_MANAGER="unknown"
    fi
}

detect_pkg_manager
mkdir -p "${STAGING_DIR}"/{manifests,configs,dotfiles,claude,opencode,ssh,keyrings,repos,scripts}
echo "$PKG_MANAGER" > "${STAGING_DIR}/manifests/pkg-manager.txt"

echo ""
echo -e "${CYAN}${BOLD}"
cat <<'BANNER'
  ╔══════════════════════════════════════════════════════════════╗
  ║            Linux Sysconfig Capture v3.0                     ║
  ║            Universal • Encrypted • Portable                 ║
  ╚══════════════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"
log "Backup ID:  ${BOLD}${BACKUP_NAME}${NC}"
log "Staging:    ${STAGING_DIR}"
log "Pkg Manager: ${BOLD}${PKG_MANAGER}${NC}"
echo -e "  ${CYAN}─────────────────────────────────────────────────────${NC}"

# --- 1. System Packages (universal) ------------------------------------------
hdr "System Packages (${PKG_MANAGER})"
log "Exporting installed package list..."
case "$PKG_MANAGER" in
    apt)
        dpkg --get-selections | grep -v deinstall | awk '{print $1}' \
            > "${STAGING_DIR}/manifests/system-packages.txt"
        apt-mark showmanual 2>/dev/null | sort \
            > "${STAGING_DIR}/manifests/manual-packages.txt" || true
        ;;
    dnf)
        rpm -qa --queryformat '%{NAME}\n' | sort \
            > "${STAGING_DIR}/manifests/system-packages.txt"
        dnf repoquery --userinstalled --queryformat '%{NAME}' 2>/dev/null | sort \
            > "${STAGING_DIR}/manifests/manual-packages.txt" || true
        ;;
    yum)
        rpm -qa --queryformat '%{NAME}\n' | sort \
            > "${STAGING_DIR}/manifests/system-packages.txt"
        yum history userinstalled 2>/dev/null | sort \
            > "${STAGING_DIR}/manifests/manual-packages.txt" || \
            cp "${STAGING_DIR}/manifests/system-packages.txt" \
               "${STAGING_DIR}/manifests/manual-packages.txt"
        ;;
    pacman)
        pacman -Qq | sort \
            > "${STAGING_DIR}/manifests/system-packages.txt"
        pacman -Qqe | sort \
            > "${STAGING_DIR}/manifests/manual-packages.txt"
        # Also capture native vs AUR breakdown
        pacman -Qqen | sort \
            > "${STAGING_DIR}/manifests/pacman-native.txt"
        pacman -Qqem 2>/dev/null | sort \
            > "${STAGING_DIR}/manifests/pacman-aur.txt" || true
        log "  $(wc -l < "${STAGING_DIR}/manifests/pacman-native.txt") native, $(wc -l < "${STAGING_DIR}/manifests/pacman-aur.txt") AUR"
        ;;
    zypper)
        zypper se --installed-only 2>/dev/null | tail -n +5 \
            | awk -F'|' '{gsub(/^ +| +$/,"",$2); if($2!="") print $2}' | sort \
            > "${STAGING_DIR}/manifests/system-packages.txt"
        # Zypper doesn't distinguish manual/auto cleanly; capture all as manual
        cp "${STAGING_DIR}/manifests/system-packages.txt" \
           "${STAGING_DIR}/manifests/manual-packages.txt"
        ;;
    apk)
        apk info 2>/dev/null | sort \
            > "${STAGING_DIR}/manifests/system-packages.txt"
        # apk world file lists explicitly installed packages
        if [ -f /etc/apk/world ]; then
            sort /etc/apk/world > "${STAGING_DIR}/manifests/manual-packages.txt"
        else
            cp "${STAGING_DIR}/manifests/system-packages.txt" \
               "${STAGING_DIR}/manifests/manual-packages.txt"
        fi
        ;;
    xbps)
        xbps-query -l 2>/dev/null | awk '{print $2}' | sed 's/-[0-9].*$//' | sort \
            > "${STAGING_DIR}/manifests/system-packages.txt"
        xbps-query -m 2>/dev/null | sed 's/-[0-9].*$//' | sort \
            > "${STAGING_DIR}/manifests/manual-packages.txt" || true
        ;;
    portage)
        qlist -Iv 2>/dev/null | sort \
            > "${STAGING_DIR}/manifests/system-packages.txt" || \
            ls -d /var/db/pkg/*/* 2>/dev/null | sed 's|/var/db/pkg/||' | sort \
                > "${STAGING_DIR}/manifests/system-packages.txt"
        # In Gentoo, everything in world file is explicit
        if [ -f /var/lib/portage/world ]; then
            sort /var/lib/portage/world > "${STAGING_DIR}/manifests/manual-packages.txt"
        else
            cp "${STAGING_DIR}/manifests/system-packages.txt" \
               "${STAGING_DIR}/manifests/manual-packages.txt"
        fi
        ;;
    nix)
        nix-env -q 2>/dev/null | sort \
            > "${STAGING_DIR}/manifests/system-packages.txt"
        cp "${STAGING_DIR}/manifests/system-packages.txt" \
           "${STAGING_DIR}/manifests/manual-packages.txt"
        ;;
    *)
        warn "Unknown package manager — skipping system package capture"
        touch "${STAGING_DIR}/manifests/system-packages.txt"
        touch "${STAGING_DIR}/manifests/manual-packages.txt"
        ;;
esac
log "  $(wc -l < "${STAGING_DIR}/manifests/system-packages.txt") packages captured"
log "  $(wc -l < "${STAGING_DIR}/manifests/manual-packages.txt") manually-installed packages"

# --- 2. Repos & Keyrings (universal) ----------------------------------------
hdr "Package Repositories & Keyrings (${PKG_MANAGER})"
case "$PKG_MANAGER" in
    apt)
        log "Copying /etc/apt/sources.list.d/..."
        mkdir -p "${STAGING_DIR}/repos/apt-sources.d"
        do_sudo cp -a /etc/apt/sources.list.d/* "${STAGING_DIR}/repos/apt-sources.d/" 2>/dev/null || true
        do_sudo cp /etc/apt/sources.list "${STAGING_DIR}/repos/sources.list" 2>/dev/null || true

        log "Copying signing keyrings..."
        do_sudo find /usr/share/keyrings /etc/apt/keyrings /etc/apt/trusted.gpg.d \
            -name "*.gpg" -type f 2>/dev/null | while read -r keyring; do
            do_sudo cp "$keyring" "${STAGING_DIR}/keyrings/" 2>/dev/null || true
        done
        log "  $(ls "${STAGING_DIR}/keyrings/" 2>/dev/null | wc -l) keyrings captured"
        ;;
    dnf|yum)
        log "Copying /etc/yum.repos.d/..."
        if [ -d /etc/yum.repos.d ]; then
            do_sudo cp -a /etc/yum.repos.d "${STAGING_DIR}/repos/yum.repos.d" 2>/dev/null || true
            log "  $(ls "${STAGING_DIR}/repos/yum.repos.d/" 2>/dev/null | wc -l) repo files"
        fi
        # Also capture RPM GPG keys
        do_sudo find /etc/pki/rpm-gpg -type f 2>/dev/null | while read -r key; do
            do_sudo cp "$key" "${STAGING_DIR}/keyrings/" 2>/dev/null || true
        done
        log "  $(ls "${STAGING_DIR}/keyrings/" 2>/dev/null | wc -l) RPM GPG keys captured"
        ;;
    pacman)
        log "Copying pacman config..."
        do_sudo cp /etc/pacman.conf "${STAGING_DIR}/repos/" 2>/dev/null || true
        if [ -d /etc/pacman.d ]; then
            mkdir -p "${STAGING_DIR}/repos/pacman.d"
            do_sudo cp -a /etc/pacman.d/mirrorlist "${STAGING_DIR}/repos/pacman.d/" 2>/dev/null || true
            # Custom repos configs
            do_sudo cp -a /etc/pacman.d/*.conf "${STAGING_DIR}/repos/pacman.d/" 2>/dev/null || true
        fi
        # Capture makepkg.conf for AUR helper settings
        do_sudo cp /etc/makepkg.conf "${STAGING_DIR}/repos/" 2>/dev/null || true
        log "  pacman.conf + mirrorlist captured"
        ;;
    zypper)
        log "Copying /etc/zypp/repos.d/..."
        if [ -d /etc/zypp/repos.d ]; then
            do_sudo cp -a /etc/zypp/repos.d "${STAGING_DIR}/repos/zypp-repos.d" 2>/dev/null || true
            log "  $(ls "${STAGING_DIR}/repos/zypp-repos.d/" 2>/dev/null | wc -l) repo files"
        fi
        do_sudo cp /etc/zypp/zypp.conf "${STAGING_DIR}/repos/" 2>/dev/null || true
        ;;
    apk)
        log "Copying /etc/apk/repositories..."
        do_sudo cp /etc/apk/repositories "${STAGING_DIR}/repos/" 2>/dev/null || true
        [ -f /etc/apk/world ] && cp /etc/apk/world "${STAGING_DIR}/repos/" 2>/dev/null || true
        log "  apk repositories captured"
        ;;
    xbps)
        log "Copying XBPS repo config..."
        if [ -d /etc/xbps.d ]; then
            do_sudo cp -a /etc/xbps.d "${STAGING_DIR}/repos/xbps.d" 2>/dev/null || true
            log "  $(ls "${STAGING_DIR}/repos/xbps.d/" 2>/dev/null | wc -l) repo config files"
        fi
        ;;
    portage)
        log "Copying Portage config..."
        for pdir in /etc/portage/repos.conf /etc/portage/make.conf; do
            if [ -e "$pdir" ]; then
                do_sudo cp -a "$pdir" "${STAGING_DIR}/repos/" 2>/dev/null || true
            fi
        done
        log "  Portage repos.conf + make.conf captured"
        ;;
    nix)
        log "Copying Nix channels..."
        nix-channel --list 2>/dev/null > "${STAGING_DIR}/repos/nix-channels.txt" || true
        [ -f /etc/nix/nix.conf ] && do_sudo cp /etc/nix/nix.conf "${STAGING_DIR}/repos/" 2>/dev/null || true
        log "  Nix channels captured"
        ;;
    *)
        warn "Unknown package manager — skipping repo capture"
        ;;
esac

# Fix permissions so tarball doesn't need root to read
do_sudo chown -R "$(id -u):$(id -g)" "${STAGING_DIR}/repos" "${STAGING_DIR}/keyrings" 2>/dev/null || true

# --- 3. Snap Packages --------------------------------------------------------
hdr "Snap Packages"
if command -v snap &>/dev/null; then
    snap list 2>/dev/null | tail -n +2 | awk '{
        if ($NF == "classic") print $1, "--classic";
        else print $1
    }' > "${STAGING_DIR}/manifests/snap-packages.txt"
    log "  $(wc -l < "${STAGING_DIR}/manifests/snap-packages.txt") snap packages"
else
    warn "snap not installed, skipping"
    touch "${STAGING_DIR}/manifests/snap-packages.txt"
fi

# --- 4. Flatpak Packages -----------------------------------------------------
hdr "Flatpak Packages"
if command -v flatpak &>/dev/null; then
    flatpak list --app --columns=application 2>/dev/null \
        > "${STAGING_DIR}/manifests/flatpak-packages.txt" || true
    log "  $(wc -l < "${STAGING_DIR}/manifests/flatpak-packages.txt") flatpak packages"
else
    warn "flatpak not installed, skipping"
    touch "${STAGING_DIR}/manifests/flatpak-packages.txt"
fi

# --- 5. NPM Global Packages --------------------------------------------------
hdr "NPM Global Packages"
if command -v npm &>/dev/null; then
    npm list -g --depth=0 --json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for pkg, info in data.get('dependencies', {}).items():
    ver = info.get('version', 'latest')
    # Skip npm itself and corepack
    if pkg not in ('npm', 'corepack'):
        print(f'{pkg}@{ver}')
" > "${STAGING_DIR}/manifests/npm-globals.txt" 2>/dev/null || true
    log "  $(wc -l < "${STAGING_DIR}/manifests/npm-globals.txt") npm global packages"
else
    touch "${STAGING_DIR}/manifests/npm-globals.txt"
fi

# --- 6. Pip Packages ---------------------------------------------------------
hdr "Pip Packages"
if command -v pip3 &>/dev/null; then
    # Only capture user-installed, not system packages
    pip3 list --user --format=freeze 2>/dev/null \
        > "${STAGING_DIR}/manifests/pip-user.txt" || true
    pip3 list --format=freeze 2>/dev/null \
        > "${STAGING_DIR}/manifests/pip-all.txt" || true
    log "  $(wc -l < "${STAGING_DIR}/manifests/pip-all.txt") total pip packages"
else
    touch "${STAGING_DIR}/manifests/pip-user.txt"
    touch "${STAGING_DIR}/manifests/pip-all.txt"
fi

# --- 7. NVM (Node Version Manager) -------------------------------------------
hdr "NVM & Node Versions"
if [ -d "$HOME/.nvm" ]; then
    ls "$HOME/.nvm/versions/node/" 2>/dev/null \
        > "${STAGING_DIR}/manifests/nvm-versions.txt"
    # Capture which version is default
    [ -s "$HOME/.nvm/alias/default" ] && \
        cat "$HOME/.nvm/alias/default" > "${STAGING_DIR}/manifests/nvm-default.txt" || \
        echo "v22.22.0" > "${STAGING_DIR}/manifests/nvm-default.txt"
    log "  Node versions: $(cat "${STAGING_DIR}/manifests/nvm-versions.txt" | tr '\n' ' ')"
else
    warn "NVM not found"
    touch "${STAGING_DIR}/manifests/nvm-versions.txt"
fi

# --- 8. Bun -------------------------------------------------------------------
hdr "Bun"
if command -v bun &>/dev/null; then
    bun --version > "${STAGING_DIR}/manifests/bun-version.txt" 2>/dev/null
    log "  Bun $(cat "${STAGING_DIR}/manifests/bun-version.txt")"
else
    touch "${STAGING_DIR}/manifests/bun-version.txt"
fi

# --- 9. Dotfiles & Shell Config -----------------------------------------------
hdr "Dotfiles & Shell Config"
for f in .bashrc .bash_aliases .bash_profile .profile .zshrc .inputrc .npmrc .gitconfig .git-credentials; do
    [ -f "$HOME/$f" ] && cp "$HOME/$f" "${STAGING_DIR}/dotfiles/" && log "  $f"
done

# .bashrc.d directory (critical — has dev-env.sh, openclaw, opencode scripts)
if [ -d "$HOME/.bashrc.d" ]; then
    cp -a "$HOME/.bashrc.d" "${STAGING_DIR}/dotfiles/bashrc.d"
    log "  .bashrc.d/ ($(ls "$HOME/.bashrc.d/" | wc -l) files)"
fi

# --- 10. SSH Keys -------------------------------------------------------------
hdr "SSH Keys"
if [ -d "$HOME/.ssh" ]; then
    cp -a "$HOME/.ssh/"* "${STAGING_DIR}/ssh/" 2>/dev/null || true
    cp -a "$HOME/.ssh/".* "${STAGING_DIR}/ssh/" 2>/dev/null || true
    # Remove socket files
    find "${STAGING_DIR}/ssh/" -type s -delete 2>/dev/null || true
    chmod 700 "${STAGING_DIR}/ssh"
    chmod 600 "${STAGING_DIR}/ssh/"* 2>/dev/null || true
    log "  $(ls "${STAGING_DIR}/ssh/" 2>/dev/null | wc -l) SSH files captured"
fi

# --- 11. Git Config -----------------------------------------------------------
hdr "Git Config"
git config --global --list 2>/dev/null > "${STAGING_DIR}/configs/git-global.txt"
log "  Git global config captured"

# --- 12. Claude Code Config --------------------------------------------------
hdr "Claude Code Config"
if [ -d "$HOME/.claude" ]; then
    # Copy settings, scripts, hooks, plugins — but NOT cache/transcripts/history
    mkdir -p "${STAGING_DIR}/claude"
    # Core config files
    for item in settings.json settings.local.json scripts statusline-command.sh mcp-needs-auth-cache.json policy-limits.json; do
        if [ -e "$HOME/.claude/$item" ]; then
            cp -a "$HOME/.claude/$item" "${STAGING_DIR}/claude/"
            log "  .claude/$item"
        fi
    done
    # Credentials
    [ -f "$HOME/.claude/.credentials.json" ] && \
        cp "$HOME/.claude/.credentials.json" "${STAGING_DIR}/claude/" && \
        log "  .claude/.credentials.json"
    # Auth backups
    if [ -d "$HOME/.claude/backups" ]; then
        mkdir -p "${STAGING_DIR}/claude/backups"
        cp "$HOME/.claude/backups/"* "${STAGING_DIR}/claude/backups/" 2>/dev/null || true
        log "  .claude/backups/ ($(ls "$HOME/.claude/backups/" 2>/dev/null | wc -l) auth backups)"
    fi
    # Agents directory (custom agent definitions)
    if [ -d "$HOME/.claude/agents" ] && [ "$(ls -A "$HOME/.claude/agents" 2>/dev/null)" ]; then
        cp -a "$HOME/.claude/agents" "${STAGING_DIR}/claude/agents"
        log "  .claude/agents/"
    fi
    # Keybindings
    [ -f "$HOME/.claude/keybindings.json" ] && \
        cp "$HOME/.claude/keybindings.json" "${STAGING_DIR}/claude/" && \
        log "  .claude/keybindings.json"
    # Todos and custom commands
    for dir in todos commands; do
        if [ -d "$HOME/.claude/$dir" ] && [ "$(ls -A "$HOME/.claude/$dir" 2>/dev/null)" ]; then
            cp -a "$HOME/.claude/$dir" "${STAGING_DIR}/claude/"
            log "  .claude/$dir/"
        fi
    done
    # Plugins — full plugin cache including skills, hooks, config
    if [ -d "$HOME/.claude/plugins" ]; then
        mkdir -p "${STAGING_DIR}/claude/plugins"
        rsync -a --exclude='node_modules' \
            "$HOME/.claude/plugins/" "${STAGING_DIR}/claude/plugins/"
        log "  .claude/plugins/ ($(find "${STAGING_DIR}/claude/plugins" -type f | wc -l) files)"
    fi
    # Projects directory — memory files, .md, .json (skip transcripts, tool-results, .jsonl)
    if [ -d "$HOME/.claude/projects" ]; then
        rsync -a --include='*/' --include='*.md' --include='*.json' \
            --exclude='*.jsonl' --exclude='tool-results' --exclude='*' \
            "$HOME/.claude/projects/" "${STAGING_DIR}/claude/projects/" 2>/dev/null || \
            cp -a "$HOME/.claude/projects" "${STAGING_DIR}/claude/"
        log "  .claude/projects/ (memory + settings)"
    fi
fi

# CLAUDE.md files — home dir + every dev project
for claude_md in "$HOME/CLAUDE.md" "$HOME/dev/CLAUDE.md"; do
    if [ -f "$claude_md" ]; then
        cp "$claude_md" "${STAGING_DIR}/configs/$(echo "$claude_md" | tr '/' '_').CLAUDE.md"
        log "  $claude_md"
    fi
done
# Per-project CLAUDE.md files in ~/dev/*/
for claude_md in "$HOME/dev"/*/CLAUDE.md; do
    if [ -f "$claude_md" ]; then
        projname="$(basename "$(dirname "$claude_md")")"
        cp "$claude_md" "${STAGING_DIR}/configs/dev_${projname}_CLAUDE.md"
    fi
done
PROJ_CLAUDE_COUNT=$(ls "${STAGING_DIR}/configs/"*CLAUDE.md 2>/dev/null | wc -l)
log "  ${PROJ_CLAUDE_COUNT} CLAUDE.md files captured"

# Keys & MCP reference file
for keyfile in "$HOME/dev/keys_and_mcps.md" "$HOME/keys_and_mcps.md"; do
    if [ -f "$keyfile" ]; then
        cp "$keyfile" "${STAGING_DIR}/configs/keys_and_mcps.md"
        log "  keys_and_mcps.md"
        break
    fi
done

# --- 13. OpenCode Config -----------------------------------------------------
hdr "OpenCode Config"
# ~/.config/opencode — main config directory
if [ -d "$HOME/.config/opencode" ]; then
    mkdir -p "${STAGING_DIR}/configs/opencode"
    # Copy config files and directories, skip node_modules and caches
    rsync -a --exclude='node_modules' --exclude='cache' --exclude='.cache' \
        --exclude='*.db' --exclude='log/' \
        "$HOME/.config/opencode/" "${STAGING_DIR}/configs/opencode/"
    log "  .config/opencode/ ($(find "${STAGING_DIR}/configs/opencode" -type f | wc -l) files)"
fi

# ~/.opencode — plugins, skills, oh-my-opencode
if [ -d "$HOME/.opencode" ]; then
    mkdir -p "${STAGING_DIR}/configs/opencode-home"
    # Copy everything except node_modules, messages (huge), parts (huge)
    rsync -a --exclude='node_modules' --exclude='messages' --exclude='parts' \
        --exclude='.git' --exclude='*.db' \
        "$HOME/.opencode/" "${STAGING_DIR}/configs/opencode-home/"
    log "  .opencode/ ($(find "${STAGING_DIR}/configs/opencode-home" -type f | wc -l) files)"
fi

# ~/.local/share/opencode — auth, snapshots, storage
if [ -d "$HOME/.local/share/opencode" ]; then
    mkdir -p "${STAGING_DIR}/configs/opencode-data"
    # Copy auth.json only — snapshot/ storage/ are 1.5GB, bin/ has 100MB+ node_modules
    [ -f "$HOME/.local/share/opencode/auth.json" ] && \
        cp "$HOME/.local/share/opencode/auth.json" "${STAGING_DIR}/configs/opencode-data/" 2>/dev/null || true
    # Copy just the rg binary (6MB), skip vscode-eslint node_modules (100MB+)
    if [ -d "$HOME/.local/share/opencode/bin" ]; then
        mkdir -p "${STAGING_DIR}/configs/opencode-data/bin"
        rsync -a --exclude='node_modules' \
            "$HOME/.local/share/opencode/bin/" "${STAGING_DIR}/configs/opencode-data/bin/"
    fi
    log "  opencode data (auth + bin, excl node_modules)"
fi

# --- 14. OpenClaw Config -----------------------------------------------------
hdr "OpenClaw Config"
if [ -d "$HOME/.openclaw" ]; then
    rsync -a --exclude='node_modules' --exclude='cache' --exclude='.cache' \
        "$HOME/.openclaw/" "${STAGING_DIR}/configs/openclaw/"
    log "  .openclaw/ (excluding caches)"
fi

# --- 15. Rclone Config -------------------------------------------------------
hdr "Rclone Config"
if [ -f "$HOME/.config/rclone/rclone.conf" ]; then
    mkdir -p "${STAGING_DIR}/configs/rclone"
    cp "$HOME/.config/rclone/rclone.conf" "${STAGING_DIR}/configs/rclone/"
    log "  rclone.conf"
fi

# --- 16. Dev Repo Manifest ---------------------------------------------------
hdr "Dev Repos Manifest"
log "Scanning ~/dev for git repos..."
{
    echo "# Dev repo manifest — directory|remote_url"
    echo "# Generated $(date -Iseconds)"
    for d in "$HOME/dev"/*/; do
        [ ! -d "$d" ] && continue
        dirname="$(basename "$d")"
        if [ -d "$d/.git" ]; then
            remote=$(git -C "$d" remote get-url origin 2>/dev/null || echo "LOCAL_ONLY")
            branch=$(git -C "$d" branch --show-current 2>/dev/null || echo "main")
            echo "${dirname}|${remote}|${branch}"
        else
            echo "${dirname}|NOT_A_REPO|"
        fi
    done
} > "${STAGING_DIR}/manifests/dev-repos.txt"
log "  $(grep -c '|' "${STAGING_DIR}/manifests/dev-repos.txt") repos cataloged"

# --- 16b. Dev Directory Full Backup ------------------------------------------
hdr "Dev Directory Full Backup"
DEV_DATA_TARBALL="${HOME}/.cache/sysconfig-capture/${BACKUP_NAME}-dev-data.tar.zst"
if [ -d "$HOME/dev" ]; then
    log "Creating full ~/dev backup (excluding regeneratable dirs)..."
    log "  This preserves ALL source code, configs, untracked files, and git history."
    log "  Excludes: node_modules, __pycache__, .next, venv, .swarm, .claude-flow, target"
    DEV_RAW_SIZE=$(du -sh "$HOME/dev" \
        --exclude='node_modules' --exclude='__pycache__' --exclude='.next' \
        --exclude='venv' --exclude='.venv' --exclude='.swarm' \
        --exclude='.claude-flow' --exclude='.hive-mind' --exclude='.agent' \
        --exclude='.claude-code-mux' --exclude='target' 2>/dev/null | cut -f1)
    log "  Estimated size before compression: ${DEV_RAW_SIZE}"
    tar -C "$HOME" \
        --exclude='node_modules' \
        --exclude='__pycache__' \
        --exclude='.next' \
        --exclude='venv' \
        --exclude='.venv' \
        --exclude='.swarm' \
        --exclude='.claude-flow' \
        --exclude='.hive-mind' \
        --exclude='.agent' \
        --exclude='.claude-code-mux' \
        --exclude='target' \
        --exclude='*.pyc' \
        -cf - dev/ 2>/dev/null \
        | zstd -3 -T0 -o "$DEV_DATA_TARBALL"
    DEV_DATA_SIZE=$(du -h "$DEV_DATA_TARBALL" | cut -f1)
    log "  Dev data archive: ${DEV_DATA_TARBALL} (${DEV_DATA_SIZE})"
else
    warn "No ~/dev directory found — skipping dev data backup"
fi

# --- 17. Systemd User Services -----------------------------------------------
hdr "Systemd User Services"
systemctl --user list-unit-files --state=enabled --no-pager --no-legend 2>/dev/null \
    | awk '{print $1}' > "${STAGING_DIR}/manifests/systemd-user-enabled.txt" || true
log "  $(wc -l < "${STAGING_DIR}/manifests/systemd-user-enabled.txt") enabled user services"

# --- 18. Crontab -------------------------------------------------------------
hdr "Crontab"
crontab -l 2>/dev/null > "${STAGING_DIR}/configs/crontab.txt" || true
log "  User crontab captured"

# --- 19. Misc Configs --------------------------------------------------------
hdr "Additional Configs"
# Chrome / Chrome Canary bookmarks and preferences
for browser_dir in "$HOME/.config/google-chrome" "$HOME/.config/google-chrome-canary"; do
    bname=$(basename "$browser_dir")
    if [ -d "$browser_dir/Default" ]; then
        mkdir -p "${STAGING_DIR}/configs/${bname}"
        for f in Bookmarks Preferences "Local State"; do
            [ -f "$browser_dir/$f" ] && cp "$browser_dir/$f" "${STAGING_DIR}/configs/${bname}/" 2>/dev/null
            [ -f "$browser_dir/Default/$f" ] && cp "$browser_dir/Default/$f" "${STAGING_DIR}/configs/${bname}/" 2>/dev/null
        done
        log "  $bname bookmarks & prefs"
    fi
done

# Fish shell config
[ -d "$HOME/.config/fish" ] && cp -a "$HOME/.config/fish" "${STAGING_DIR}/configs/fish" && log "  fish config"

# GitHub CLI config
[ -d "$HOME/.config/gh" ] && cp -a "$HOME/.config/gh" "${STAGING_DIR}/configs/gh" && log "  gh CLI config"

# Antigravity config
[ -d "$HOME/.config/Antigravity" ] && cp -a "$HOME/.config/Antigravity" "${STAGING_DIR}/configs/Antigravity" && log "  Antigravity config"

# Tailscale — skip state dir (huge, just run `tailscale up` on new machine)
command -v tailscale &>/dev/null && log "  Tailscale installed (will reinstall, just run 'tailscale up')"

# Supermemory script
[ -f "$HOME/.claude/scripts/supermemory.sh" ] && log "  (supermemory script already in claude/scripts)"

# --- 20. Desktop Environment (KDE/GNOME/XFCE) --------------------------------
hdr "Desktop Environment Config"
DE="${XDG_CURRENT_DESKTOP:-unknown}"
log "  Detected DE: ${DE}"
mkdir -p "${STAGING_DIR}/configs/desktop"

# KDE Plasma
if echo "$DE" | grep -qi "kde\|plasma"; then
    log "  Capturing KDE Plasma configs..."
    mkdir -p "${STAGING_DIR}/configs/desktop/kde-config"
    mkdir -p "${STAGING_DIR}/configs/desktop/kde-local-share"

    # KDE rc files (themes, shortcuts, window rules, panels, etc.)
    KDE_COUNT=0
    for f in "$HOME"/.config/k*rc "$HOME/.config/kdeglobals" \
             "$HOME/.config/Trolltech.conf" \
             "$HOME/.config/plasma"* \
             "$HOME/.config/kdedefaults" \
             "$HOME/.config/kwinoutputconfig.json"; do
        if [ -e "$f" ]; then
            cp -a "$f" "${STAGING_DIR}/configs/desktop/kde-config/" 2>/dev/null && \
                KDE_COUNT=$((KDE_COUNT + 1))
        fi
    done

    # KDE application configs (dolphin, konsole, kate, yakuake)
    for app in dolphinrc konsolerc katerc katevirc yakuakerc; do
        [ -f "$HOME/.config/$app" ] && \
            cp "$HOME/.config/$app" "${STAGING_DIR}/configs/desktop/kde-config/" 2>/dev/null
    done

    # Konsole profiles
    [ -d "$HOME/.local/share/konsole" ] && \
        cp -a "$HOME/.local/share/konsole" "${STAGING_DIR}/configs/desktop/kde-local-share/" 2>/dev/null

    # Plasma look-and-feel / themes
    for d in plasma-org.kde.plasma.desktop-appletsrc plasma-workspace; do
        [ -e "$HOME/.config/$d" ] && \
            cp -a "$HOME/.config/$d" "${STAGING_DIR}/configs/desktop/kde-config/" 2>/dev/null
    done

    # KDE Connect
    [ -d "$HOME/.config/kdeconnect" ] && \
        cp -a "$HOME/.config/kdeconnect" "${STAGING_DIR}/configs/desktop/kde-config/" 2>/dev/null

    # Local share: color-schemes, aurorae (window decorations), plasma themes
    for d in color-schemes aurorae plasma kwin; do
        [ -d "$HOME/.local/share/$d" ] && \
            cp -a "$HOME/.local/share/$d" "${STAGING_DIR}/configs/desktop/kde-local-share/" 2>/dev/null
    done

    # kscreen output/display mapping (ties panels to monitor IDs)
    if [ -d "$HOME/.local/share/kscreen" ]; then
        cp -a "$HOME/.local/share/kscreen" "${STAGING_DIR}/configs/desktop/kde-local-share/" 2>/dev/null
        log "  kscreen display mapping captured"
    fi

    # Plasma layout templates (custom panel layouts)
    if [ -d "$HOME/.local/share/plasma/layout-templates" ]; then
        mkdir -p "${STAGING_DIR}/configs/desktop/kde-local-share/plasma"
        cp -a "$HOME/.local/share/plasma/layout-templates" \
            "${STAGING_DIR}/configs/desktop/kde-local-share/plasma/" 2>/dev/null
        log "  Plasma layout templates captured"
    fi

    log "  ${KDE_COUNT} KDE config files captured"
fi

# GTK themes (works for all DEs)
for gtkdir in gtk-3.0 gtk-4.0; do
    if [ -d "$HOME/.config/$gtkdir" ]; then
        cp -a "$HOME/.config/$gtkdir" "${STAGING_DIR}/configs/desktop/" 2>/dev/null
        log "  $gtkdir settings"
    fi
done

# Fontconfig
[ -d "$HOME/.config/fontconfig" ] && \
    cp -a "$HOME/.config/fontconfig" "${STAGING_DIR}/configs/desktop/" 2>/dev/null && \
    log "  fontconfig"

# Custom fonts
[ -d "$HOME/.local/share/fonts" ] && \
    cp -a "$HOME/.local/share/fonts" "${STAGING_DIR}/configs/desktop/" 2>/dev/null && \
    log "  custom fonts ($(find "$HOME/.local/share/fonts" -type f | wc -l) files)"

# GNOME (dconf dump)
if echo "$DE" | grep -qi "gnome\|unity\|cinnamon"; then
    if command -v dconf &>/dev/null; then
        dconf dump / > "${STAGING_DIR}/configs/desktop/dconf-dump.ini" 2>/dev/null
        log "  GNOME dconf dump"
    fi
fi

# XFCE
if echo "$DE" | grep -qi "xfce"; then
    [ -d "$HOME/.config/xfce4" ] && \
        cp -a "$HOME/.config/xfce4" "${STAGING_DIR}/configs/desktop/" 2>/dev/null && \
        log "  XFCE4 config"
fi

# SDDM / Display Manager config (system-level)
if [ -f "/etc/sddm.conf" ] || [ -d "/etc/sddm.conf.d" ]; then
    mkdir -p "${STAGING_DIR}/configs/desktop/sddm"
    [ -f "/etc/sddm.conf" ] && cp "/etc/sddm.conf" "${STAGING_DIR}/configs/desktop/sddm/" 2>/dev/null
    [ -d "/etc/sddm.conf.d" ] && cp -a "/etc/sddm.conf.d" "${STAGING_DIR}/configs/desktop/sddm/" 2>/dev/null
    log "  SDDM display manager config"
fi

# Session type
echo "session_type=${XDG_SESSION_TYPE:-unknown}" > "${STAGING_DIR}/configs/desktop/session-info.txt"
echo "desktop=${DE}" >> "${STAGING_DIR}/configs/desktop/session-info.txt"
echo "display_manager=$(cat /etc/X11/default-display-manager 2>/dev/null || echo 'unknown')" >> "${STAGING_DIR}/configs/desktop/session-info.txt"
echo "wayland=$([ "${XDG_SESSION_TYPE:-}" = "wayland" ] && echo "yes" || echo "no")" >> "${STAGING_DIR}/configs/desktop/session-info.txt"

# --- 21. System Info Snapshot -------------------------------------------------
hdr "System Info"
{
    echo "hostname=$(hostname)"
    echo "user=$(whoami)"
    echo "uid=$(id -u)"
    echo "gid=$(id -g)"
    echo "shell=$SHELL"
    echo "kernel=$(uname -r)"
    echo "arch=$(uname -m)"
    echo "distro=$(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"')"
    echo "pkg_manager=${PKG_MANAGER}"
    echo "desktop=${XDG_CURRENT_DESKTOP:-unknown}"
    echo "date=$(date -Iseconds)"
    echo "home=${HOME}"
} > "${STAGING_DIR}/manifests/system-info.txt"
log "  System snapshot written"

# --- Create Tarball -----------------------------------------------------------
hdr "Creating Compressed Archive"
log "Compressing with zstd (level 9)..."
tar -C "$(dirname "$STAGING_DIR")" -cf - "$BACKUP_NAME" | zstd -9 -T0 -o "$TARBALL"
SIZE=$(du -h "$TARBALL" | cut -f1)
log "Archive: ${TARBALL} (${SIZE})"

# --- Encrypt Backup (optional) ------------------------------------------------
if $ENCRYPT; then
    hdr "Encrypting Backup"
    ENCRYPTED_TARBALL="${TARBALL}.age"

    if command -v age &>/dev/null; then
        # Use age (preferred - modern, simple)
        # age -p requires a TTY; use script(1) to emulate one when piping passphrase
        if [ -n "${BACKUP_PASSPHRASE:-}" ]; then
            printf '%s\n%s\n' "$BACKUP_PASSPHRASE" "$BACKUP_PASSPHRASE" | \
                script -q /dev/null -c "age -p -o '$ENCRYPTED_TARBALL' '$TARBALL'" >/dev/null 2>&1
        else
            age -p -o "$ENCRYPTED_TARBALL" "$TARBALL"
        fi
    elif command -v gpg &>/dev/null; then
        # Fallback to GPG symmetric
        if [ -n "${BACKUP_PASSPHRASE:-}" ]; then
            echo "$BACKUP_PASSPHRASE" | gpg --batch --yes --passphrase-fd 0 \
                --symmetric --cipher-algo AES256 -o "$ENCRYPTED_TARBALL" "$TARBALL"
        else
            gpg --symmetric --cipher-algo AES256 -o "$ENCRYPTED_TARBALL" "$TARBALL"
        fi
    else
        warn "Neither age nor gpg found. Install age: https://github.com/FiloSottile/age"
        warn "Backup saved UNENCRYPTED."
        ENCRYPT=false
    fi

    if $ENCRYPT; then
        rm -f "$TARBALL"
        TARBALL="$ENCRYPTED_TARBALL"
        log "Encrypted backup: ${TARBALL}"
    fi
fi

# --- Upload to Google Drive ---------------------------------------------------
hdr "Uploading to Google Drive"
if command -v rclone &>/dev/null; then
    if rclone listremotes 2>/dev/null | grep -q "gdrive:"; then
        # Test connectivity
        if ! rclone lsd gdrive: &>/dev/null 2>&1; then
            warn "Google Drive auth expired or not configured"
            warn "Run manually after capture: rclone config reconnect gdrive:"
            warn "Then upload: rclone copy '${TARBALL}' '${GDRIVE_DEST}' --progress"
        fi

        if rclone lsd gdrive: &>/dev/null 2>&1; then
            log "Uploading to ${GDRIVE_DEST}..."
            rclone mkdir "$GDRIVE_DEST" 2>/dev/null || true
            rclone copy "$TARBALL" "$GDRIVE_DEST" --progress --transfers=4 && \
                log "Upload complete!" || warn "Upload failed — archive saved locally"

            # Upload dev-data tarball (full ~/dev backup)
            if [ -f "${DEV_DATA_TARBALL:-}" ]; then
                log "Uploading dev-data archive (full ~/dev backup)..."
                rclone copy "$DEV_DATA_TARBALL" "$GDRIVE_DEST" --progress --transfers=4 && \
                    log "Dev data upload complete!" || warn "Dev data upload failed — saved locally"
            fi

            # Also upload the bootstrap and restore scripts
            SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
            for script in bootstrap.sh restore.sh verify.sh; do
                [ -f "${SCRIPT_DIR}/${script}" ] && \
                    rclone copy "${SCRIPT_DIR}/${script}" "$GDRIVE_DEST" --progress 2>/dev/null && \
                    log "${script} uploaded to Drive"
            done
        else
            warn "Google Drive not accessible — archive saved locally"
            warn "To upload later: rclone copy '${TARBALL}' '${GDRIVE_DEST}'"
        fi
    else
        warn "rclone 'gdrive' remote not configured"
        warn "Archive saved locally at: ${TARBALL}"
    fi
else
    warn "rclone not installed — archive saved locally at: ${TARBALL}"
fi

# --- Cleanup ------------------------------------------------------------------
rm -rf "${STAGING_DIR}"

echo ""
echo -e "${CYAN}${BOLD}"
cat <<'BANNER'
  ╔══════════════════════════════════════════════════════════════╗
  ║                   CAPTURE COMPLETE                          ║
  ╚══════════════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"
log "Backup:     ${BOLD}${TARBALL}${NC}"
if [ -f "${DEV_DATA_TARBALL:-}" ]; then
    log "Dev Data:   ${BOLD}${DEV_DATA_TARBALL}${NC} ($(du -h "$DEV_DATA_TARBALL" | cut -f1))"
fi
if $ENCRYPT; then
    log "Encryption: ${GREEN}${BOLD}ENABLED${NC} (age/gpg)"
else
    log "Encryption: ${YELLOW}none${NC} (use --encrypt to enable)"
fi
log "GDrive:     ${BOLD}${GDRIVE_DEST}/$(basename "$TARBALL")${NC}"
echo ""
echo -e "  ${CYAN}─────────────────────────────────────────────────────${NC}"
echo -e "  ${BOLD}On the new machine, run:${NC}"
echo ""
echo -e "    ${GREEN}curl -fsSL https://raw.githubusercontent.com/jdgafx/linux-sysconfig/main/bootstrap.sh | bash${NC}"
echo ""
echo -e "  Or manually:"
echo -e "    ${CYAN}bash restore.sh /path/to/$(basename "${TARBALL%.age}")${NC}"
echo -e "  ${CYAN}─────────────────────────────────────────────────────${NC}"
echo ""
