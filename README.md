# Linux Sysconfig Package & Transfer

One-command dev environment capture, backup, and restore across any Linux distro.

## Quick Start

### Capture your current environment

```bash
bash capture.sh              # basic capture + upload to Google Drive
bash capture.sh --encrypt    # encrypted capture (age/gpg)
bash capture.sh --yes        # non-interactive (skip confirmations)
```

### Restore on a new machine

```bash
# One-liner (downloads from Google Drive automatically)
curl -fsSL https://raw.githubusercontent.com/jdgafx/linux-sysconfig/main/bootstrap.sh | bash

# With a local backup file
sudo bash restore.sh /path/to/backup.tar.zst

# Preview what will be restored (no changes made)
sudo bash restore.sh --dry-run /path/to/backup.tar.zst

# Encrypted backup (auto-detected)
BACKUP_PASSPHRASE='yourpass' sudo bash restore.sh /path/to/backup.tar.zst.age
```

### Verify a backup

```bash
bash verify.sh /path/to/backup.tar.zst          # inspect contents
bash verify.sh /path/to/backup.tar.zst --diff    # compare with current system
```

## What Gets Captured

| Component | Details |
|-----------|---------|
| **System Packages** | APT, DNF/YUM, Pacman, Zypper, APK, XBPS, Portage, Nix |
| **Snap & Flatpak** | All installed packages with flags |
| **NPM Globals** | All global npm packages with versions |
| **Pip Packages** | User and system pip packages |
| **NVM & Node** | All installed Node versions + default |
| **Bun** | Version for reinstall |
| **Dotfiles** | .bashrc, .zshrc, .profile, .gitconfig, .bashrc.d/ |
| **SSH Keys** | Full ~/.ssh directory (permissions preserved) |
| **Git Config** | Global config + credentials |
| **Claude Code** | Settings, scripts, hooks, plugins, project memory |
| **OpenCode** | Config, plugins, oh-my-opencode, auth, snapshots |
| **OpenClaw** | Full config (excluding caches) |
| **Rclone** | rclone.conf for cloud storage |
| **Dev Repos** | Manifest of all ~/dev repos with remotes + branches |
| **Browser** | Chrome/Canary bookmarks & preferences |
| **Services** | Systemd user services, crontab |
| **Package Repos** | APT sources, YUM repos, pacman mirrors, keyrings |

## Scripts

| Script | Purpose |
|--------|---------|
| `capture.sh` | Snapshot entire dev environment into compressed tarball |
| `restore.sh` | Fully automated restoration from backup |
| `bootstrap.sh` | One-command new machine setup (downloads + restores) |
| `verify.sh` | Backup validation, inspection, and diff |

## Features

- **Universal**: Works on Debian/Ubuntu, Fedora/RHEL, Arch, openSUSE, Alpine, Void, Gentoo, NixOS
- **Encrypted**: Optional age/gpg encryption for sensitive data
- **Resilient**: Failed packages don't block the restore -- retries individually
- **Idempotent**: Safe to run multiple times
- **Dry Run**: Preview changes before applying
- **Portable**: Package names auto-translated between distros
- **Cloud Sync**: Auto-uploads to Google Drive via rclone

## Environment Variables

| Variable | Description |
|----------|-------------|
| `SUDO_PASSWORD` | Auto-supply sudo password (capture only) |
| `BACKUP_PASSPHRASE` | Passphrase for age/gpg encryption/decryption |

## Architecture

```
capture.sh  ──→  .tar.zst  ──→  Google Drive
                     │
                     ▼
bootstrap.sh ──→ downloads ──→ restore.sh ──→ fully configured machine
                                    │
                                    ▼
                              verify.sh (inspect/diff)
```

## License

MIT
