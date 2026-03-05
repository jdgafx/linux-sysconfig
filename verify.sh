#!/usr/bin/env bash
###############################################################################
# verify.sh — Validate and inspect backup tarballs
#
# Checks integrity, displays backup contents summary, and optionally diffs
# the backup against the current system. Read-only — extracts to /tmp and
# cleans up after itself. Does NOT require root.
#
# Usage:  bash verify.sh /path/to/backup.tar.zst          # inspect
#         bash verify.sh /path/to/backup.tar.zst --diff    # compare with system
#         bash verify.sh                                    # auto-find latest
###############################################################################
set -uo pipefail
IFS=$'\n\t'

# --- Colors & Logging --------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*"; }
hdr()  { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}"; }

die() { err "$*"; exit 1; }

# --- Parse Arguments ----------------------------------------------------------
TARBALL=""
DIFF_MODE=0

for arg in "$@"; do
    case "$arg" in
        --diff) DIFF_MODE=1 ;;
        -*)     die "Unknown flag: $arg" ;;
        *)      TARBALL="$arg" ;;
    esac
done

# --- Locate Backup ------------------------------------------------------------
if [ -z "$TARBALL" ]; then
    TARBALL=$(find . /tmp "$HOME" "$HOME/.cache/sysconfig-capture" \
        -maxdepth 2 -name "linux-sysconfig-*.tar.zst" -type f 2>/dev/null \
        | sort -r | head -1)
fi

[ -z "$TARBALL" ] && die "No backup archive found. Usage: bash verify.sh /path/to/backup.tar.zst"
[ ! -f "$TARBALL" ] && die "File not found: ${TARBALL}"

TARBALL="$(realpath "$TARBALL")"

echo ""
echo -e "${CYAN}${BOLD}"
cat <<'BANNER'
  ╔══════════════════════════════════════════════════════════════╗
  ║            Linux Sysconfig Verify v2.0                      ║
  ║            Integrity • Inspection • Diff                    ║
  ╚══════════════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"
log "Archive: ${TARBALL}"
log "Size:    $(du -h "$TARBALL" | cut -f1)"

# --- Pre-flight ---------------------------------------------------------------
command -v tar  >/dev/null || die "tar is required"
command -v zstd >/dev/null || die "zstd is required (install: sudo apt install zstd)"

# --- 1. Integrity Check ------------------------------------------------------
hdr "Integrity Check"
log "Testing zstd decompression..."
if zstd -t "$TARBALL" 2>/dev/null; then
    log "Zstd frame: ${GREEN}OK${NC}"
else
    die "Zstd integrity check FAILED — archive is corrupt"
fi

log "Testing tar listing..."
if tar -I zstd -tf "$TARBALL" >/dev/null 2>&1; then
    log "Tar contents: ${GREEN}OK${NC}"
else
    die "Tar listing FAILED — archive may be truncated or corrupt"
fi

FILE_COUNT=$(tar -I zstd -tf "$TARBALL" 2>/dev/null | wc -l)
log "Total entries: ${FILE_COUNT}"

# --- 2. Extract to Temp ------------------------------------------------------
EXTRACT_DIR="/tmp/sysconfig-verify-$$"
mkdir -p "$EXTRACT_DIR"

cleanup() { rm -rf "$EXTRACT_DIR"; }
trap cleanup EXIT

log "Extracting to ${EXTRACT_DIR}..."
tar -I zstd -xf "$TARBALL" -C "$EXTRACT_DIR" 2>/dev/null

BACKUP_DIR=$(find "$EXTRACT_DIR" -maxdepth 1 -type d -name "linux-sysconfig-*" | head -1)
[ -z "$BACKUP_DIR" ] && BACKUP_DIR="$EXTRACT_DIR"

# --- Helper: count lines in file, 0 if missing -------------------------------
fcount() { [ -f "$1" ] && wc -l < "$1" || echo 0; }

# --- 3. System Info -----------------------------------------------------------
hdr "System Info (from backup)"
if [ -f "$BACKUP_DIR/manifests/system-info.txt" ]; then
    while IFS='=' read -r key value; do
        [ -z "$key" ] && continue
        printf "  ${BOLD}%-10s${NC} %s\n" "$key" "$value"
    done < "$BACKUP_DIR/manifests/system-info.txt"
else
    warn "No system-info.txt found in backup"
fi

# --- 4. Package Manager Detection ---------------------------------------------
hdr "Package Manager"
if [ -f "$BACKUP_DIR/manifests/pkg-manager.txt" ]; then
    PKG_MGR=$(cat "$BACKUP_DIR/manifests/pkg-manager.txt")
    log "Backup uses: ${BOLD}${PKG_MGR}${NC}"
elif [ -d "$BACKUP_DIR/repos/apt-sources.d" ] || [ -d "$BACKUP_DIR/apt-sources" ]; then
    log "Backup uses: ${BOLD}apt${NC} (Debian/Ubuntu)"
else
    log "Backup uses: ${BOLD}unknown${NC}"
fi

# --- 5. Package Counts -------------------------------------------------------
hdr "Package Counts"
# Support both new names (system-packages/manual-packages) and legacy (apt-packages/apt-manual)
SYS_PKG_FILE="$BACKUP_DIR/manifests/system-packages.txt"
[ ! -f "$SYS_PKG_FILE" ] && SYS_PKG_FILE="$BACKUP_DIR/manifests/apt-packages.txt"
MAN_PKG_FILE="$BACKUP_DIR/manifests/manual-packages.txt"
[ ! -f "$MAN_PKG_FILE" ] && MAN_PKG_FILE="$BACKUP_DIR/manifests/apt-manual.txt"
printf "  ${BOLD}%-25s${NC} %s\n" "System packages (all)"  "$(fcount "$SYS_PKG_FILE")"
printf "  ${BOLD}%-25s${NC} %s\n" "Manual packages"        "$(fcount "$MAN_PKG_FILE")"
printf "  ${BOLD}%-25s${NC} %s\n" "Snap packages"          "$(fcount "$BACKUP_DIR/manifests/snap-packages.txt")"
printf "  ${BOLD}%-25s${NC} %s\n" "Flatpak packages"       "$(fcount "$BACKUP_DIR/manifests/flatpak-packages.txt")"
printf "  ${BOLD}%-25s${NC} %s\n" "NPM globals"            "$(fcount "$BACKUP_DIR/manifests/npm-globals.txt")"
printf "  ${BOLD}%-25s${NC} %s\n" "Pip packages (user)"    "$(fcount "$BACKUP_DIR/manifests/pip-user.txt")"
printf "  ${BOLD}%-25s${NC} %s\n" "Pip packages (all)"     "$(fcount "$BACKUP_DIR/manifests/pip-all.txt")"

# NVM versions
if [ -f "$BACKUP_DIR/manifests/nvm-versions.txt" ] && [ -s "$BACKUP_DIR/manifests/nvm-versions.txt" ]; then
    NVM_VERS=$(tr '\n' ', ' < "$BACKUP_DIR/manifests/nvm-versions.txt" | sed 's/, $//')
    printf "  ${BOLD}%-25s${NC} %s\n" "Node versions (NVM)" "$NVM_VERS"
fi

# Bun
if [ -f "$BACKUP_DIR/manifests/bun-version.txt" ] && [ -s "$BACKUP_DIR/manifests/bun-version.txt" ]; then
    printf "  ${BOLD}%-25s${NC} %s\n" "Bun version" "$(cat "$BACKUP_DIR/manifests/bun-version.txt")"
fi

# --- 6. Dotfiles Captured -----------------------------------------------------
hdr "Dotfiles"
if [ -d "$BACKUP_DIR/dotfiles" ]; then
    find "$BACKUP_DIR/dotfiles" -maxdepth 1 -mindepth 1 | sort | while read -r f; do
        fname=$(basename "$f")
        if [ -d "$f" ]; then log "  ${fname}/ ($(find "$f" -type f | wc -l) files)"
        else log "  ${fname}"; fi
    done
else
    warn "No dotfiles directory in backup"
fi

# --- 7. SSH Keys --------------------------------------------------------------
hdr "SSH Keys"
if [ -d "$BACKUP_DIR/ssh" ]; then
    SSH_ALL=$(find "$BACKUP_DIR/ssh" -type f | wc -l)
    SSH_PUB=$(find "$BACKUP_DIR/ssh" -name "*.pub" -type f | wc -l)
    log "${SSH_ALL} files (${SSH_PUB} public, $((SSH_ALL - SSH_PUB)) private/config)"
    find "$BACKUP_DIR/ssh" -type f -printf "  %f\n" | sort
else
    warn "No SSH keys in backup"
fi

# --- 8. Claude / OpenCode Configs --------------------------------------------
hdr "Claude Code Config"
if [ -d "$BACKUP_DIR/claude" ]; then
    for item in settings.json settings.local.json .credentials.json statusline-command.sh; do
        [ -f "$BACKUP_DIR/claude/$item" ] && log "  $item"
    done
    [ -d "$BACKUP_DIR/claude/scripts" ] && log "  scripts/ ($(find "$BACKUP_DIR/claude/scripts" -type f | wc -l) files)"
    [ -d "$BACKUP_DIR/claude/plugins" ] && log "  plugins/"
    [ -d "$BACKUP_DIR/claude/projects" ] && log "  projects/"
    [ -d "$BACKUP_DIR/claude/projects-memory" ] && log "  projects-memory/"
else
    warn "No Claude config in backup"
fi

hdr "OpenCode Config"
if [ -d "$BACKUP_DIR/configs/opencode" ]; then
    log "  .config/opencode/ ($(find "$BACKUP_DIR/configs/opencode" -type f | wc -l) files)"
else
    warn "No OpenCode config in backup"
fi
[ -d "$BACKUP_DIR/configs/opencode-data" ] && log "  opencode auth data present"
[ -d "$BACKUP_DIR/configs/openclaw" ] && log "  OpenClaw config present"

# --- 9. Dev Repos Manifest ---------------------------------------------------
hdr "Dev Repos"
if [ -f "$BACKUP_DIR/manifests/dev-repos.txt" ]; then
    REPO_COUNT=$(grep -c '|' "$BACKUP_DIR/manifests/dev-repos.txt" 2>/dev/null || echo 0)
    GIT_REPOS=$(grep -v 'NOT_A_REPO\|LOCAL_ONLY\|^#' "$BACKUP_DIR/manifests/dev-repos.txt" 2>/dev/null | wc -l)
    log "${REPO_COUNT} entries total, ${GIT_REPOS} with git remotes"
else
    warn "No dev-repos.txt manifest"
fi

# --- 10. Keyrings ------------------------------------------------------------
hdr "APT Keyrings"
if [ -d "$BACKUP_DIR/keyrings" ]; then
    KEYRING_COUNT=$(find "$BACKUP_DIR/keyrings" -type f | wc -l)
    log "${KEYRING_COUNT} keyring files"
else
    warn "No keyrings in backup"
fi

# --- 11. Size Breakdown -------------------------------------------------------
hdr "Size Breakdown"
for d in manifests configs dotfiles claude opencode ssh keyrings repos apt-sources scripts; do
    if [ -d "$BACKUP_DIR/$d" ]; then
        SIZE=$(du -sh "$BACKUP_DIR/$d" 2>/dev/null | cut -f1)
        printf "  ${BOLD}%-20s${NC} %s\n" "$d/" "$SIZE"
    fi
done
TOTAL=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
echo ""
printf "  ${BOLD}%-20s${NC} %s (uncompressed)\n" "TOTAL" "$TOTAL"

# =============================================================================
#  DIFF MODE
# =============================================================================
if [ "$DIFF_MODE" -eq 1 ]; then
    hdr "DIFF: Backup vs Current System"

    # Helper: diff two sorted lists, show +/- with capped output
    diff_lists() {
        local backup_sorted="$1" current_sorted="$2" label="$3" cap=20
        local only_backup only_local
        only_backup=$(comm -23 "$backup_sorted" "$current_sorted" | wc -l)
        only_local=$(comm -13 "$backup_sorted" "$current_sorted" | wc -l)
        if [ "$only_backup" -gt 0 ]; then
            warn "In backup but NOT installed locally (${only_backup}):"
            comm -23 "$backup_sorted" "$current_sorted" | head -$cap | while read -r p; do echo -e "    ${RED}-${NC} $p"; done
            [ "$only_backup" -gt $cap ] && echo "    ... and $((only_backup - cap)) more"
        else
            log "All backup ${label} are installed locally"
        fi
        if [ "$only_local" -gt 0 ]; then
            warn "Installed locally but NOT in backup (${only_local}):"
            comm -13 "$backup_sorted" "$current_sorted" | head -$cap | while read -r p; do echo -e "    ${GREEN}+${NC} $p"; done
            [ "$only_local" -gt $cap ] && echo "    ... and $((only_local - cap)) more"
        else
            log "No extra local ${label} beyond backup"
        fi
    }

    # --- Diff: manual packages ---------------------------------------------------
    hdr "Package Diff (manual packages)"
    DIFF_MAN_FILE="$BACKUP_DIR/manifests/manual-packages.txt"
    [ ! -f "$DIFF_MAN_FILE" ] && DIFF_MAN_FILE="$BACKUP_DIR/manifests/apt-manual.txt"
    if [ -f "$DIFF_MAN_FILE" ]; then
        TMP_CUR="/tmp/sv-cur-$$"; TMP_BAK="/tmp/sv-bak-$$"
        # Get current package list based on available package manager
        if command -v apt-mark &>/dev/null; then
            apt-mark showmanual 2>/dev/null | sort > "$TMP_CUR"
        elif command -v dnf &>/dev/null; then
            dnf repoquery --userinstalled --qf '%{name}' 2>/dev/null | sort > "$TMP_CUR"
        elif command -v pacman &>/dev/null; then
            pacman -Qqe 2>/dev/null | sort > "$TMP_CUR"
        elif command -v apk &>/dev/null; then
            sort /etc/apk/world 2>/dev/null > "$TMP_CUR"
        else
            warn "No supported package manager for diff"
            touch "$TMP_CUR"
        fi
        sort "$DIFF_MAN_FILE" > "$TMP_BAK"
        diff_lists "$TMP_BAK" "$TMP_CUR" "packages"
        rm -f "$TMP_CUR" "$TMP_BAK"
    else
        warn "No manual package manifest found in backup"
    fi

    # --- Diff: NPM globals ----------------------------------------------------
    hdr "NPM Globals Diff"
    if [ -f "$BACKUP_DIR/manifests/npm-globals.txt" ] && command -v npm &>/dev/null; then
        TMP_CUR="/tmp/sv-npm-cur-$$"; TMP_BAK="/tmp/sv-npm-bak-$$"
        npm list -g --depth=0 --parseable 2>/dev/null | tail -n +2 | sed 's|.*/node_modules/||' | sort > "$TMP_CUR"
        # Strip trailing @version but preserve scoped @scope/name prefixes
        sed 's/@[0-9][^/]*$//' "$BACKUP_DIR/manifests/npm-globals.txt" | sort > "$TMP_BAK"
        diff_lists "$TMP_BAK" "$TMP_CUR" "npm globals"
        rm -f "$TMP_CUR" "$TMP_BAK"
    else
        warn "Cannot diff npm globals (npm not available or no manifest)"
    fi

    # --- Diff: Dotfiles -------------------------------------------------------
    hdr "Dotfiles Diff"
    if [ -d "$BACKUP_DIR/dotfiles" ]; then
        CHANGED=0
        for f in "$BACKUP_DIR/dotfiles/".*; do
            [ ! -f "$f" ] && continue
            fname=$(basename "$f")
            [[ "$fname" == "." || "$fname" == ".." ]] && continue
            if [ ! -f "$HOME/$fname" ]; then
                warn "  ${fname} — in backup, missing locally"; CHANGED=$((CHANGED + 1))
            elif ! diff -q "$f" "$HOME/$fname" >/dev/null 2>&1; then
                warn "  ${fname} — differs"; CHANGED=$((CHANGED + 1))
            fi
        done
        [ "$CHANGED" -eq 0 ] && log "All dotfiles match current system"
    fi

    # --- Diff: Dev repos ------------------------------------------------------
    hdr "Dev Repos Diff"
    if [ -f "$BACKUP_DIR/manifests/dev-repos.txt" ]; then
        MISSING_REPOS=0; PRESENT_REPOS=0
        while IFS='|' read -r dirname remote branch; do
            [[ "$dirname" =~ ^# ]] && continue
            [[ "$remote" == "NOT_A_REPO" || -z "$dirname" ]] && continue
            if [ -d "$HOME/dev/$dirname" ]; then PRESENT_REPOS=$((PRESENT_REPOS + 1))
            else warn "  ${dirname} — in backup, missing locally"; MISSING_REPOS=$((MISSING_REPOS + 1)); fi
        done < "$BACKUP_DIR/manifests/dev-repos.txt"
        log "${PRESENT_REPOS} repos present, ${MISSING_REPOS} missing"
    fi
fi

# --- Summary ------------------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}"
cat <<'BANNER'
  ╔══════════════════════════════════════════════════════════════╗
  ║            VERIFICATION COMPLETE                            ║
  ╚══════════════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"
log "Archive: $(basename "$TARBALL") ($(du -h "$TARBALL" | cut -f1) compressed)"
log "Status:  ${GREEN}${BOLD}VALID${NC}"
[ "$DIFF_MODE" -eq 1 ] && log "Diff mode: enabled"
echo ""
